#import "FLEXRuntimeScanner.h"

#import "FLEXHookPersistence.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

NSNotificationName const FLEXRuntimeImagesDidChangeNotification =
    @"FLEXRuntimeImagesDidChangeNotification";

const char *FLEXRuntimeScannerHostIsolationABIVersion =
    "AllFLEXing current-host whole-runtime scanner ABI 2";

static dispatch_queue_t FLEXRuntimeScannerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.allflexing.runtime-scanner",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_UTILITY,
                0
            )
        );
    });
    return queue;
}

static atomic_bool gFLEXRuntimeImageNotificationScheduled = false;

static void FLEXRuntimeImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;

    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &gFLEXRuntimeImageNotificationScheduled,
            &expected,
            true,
            memory_order_acq_rel,
            memory_order_relaxed)) {
        return;
    }

    // dyld invokes this callback while loader state is active. Never inspect
    // Objective-C metadata or Mach-O tables from the callback itself.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
        FLEXRuntimeScannerQueue(),
        ^{
            atomic_store_explicit(
                &gFLEXRuntimeImageNotificationScheduled,
                false,
                memory_order_release
            );
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter
                    postNotificationName:FLEXRuntimeImagesDidChangeNotification
                                  object:FLEXRuntimeScanner.class];
            });
        }
    );
}

static NSString *FLEXCurrentHostIdentity(void) {
    return NSBundle.mainBundle.bundleIdentifier.length
        ? NSBundle.mainBundle.bundleIdentifier
        : (NSProcessInfo.processInfo.processName ?: @"host");
}

static BOOL FLEXPathBelongsToCurrentHost(NSString *path) {
    if (!path.length) return NO;

    NSString *executablePath = NSBundle.mainBundle.executablePath;
    if (executablePath.length && [path isEqualToString:executablePath]) {
        return YES;
    }

    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    if (!bundlePath.length) return NO;
    NSString *prefix = [bundlePath stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

static NSString *FLEXUUIDForHeader(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) return @"";

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuidCommand =
                (const struct uuid_command *)command;
            NSUUID *uuid = [[NSUUID alloc]
                initWithUUIDBytes:uuidCommand->uuid];
            return uuid.UUIDString ?: @"";
        }
        cursor += command->cmdsize;
    }
    return @"";
}

static NSString *FLEXUUIDForLoadedImagePath(NSString *path) {
    if (!path.length || !FLEXPathBelongsToCurrentHost(path)) return @"";

    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *genericHeader = _dyld_get_image_header(index);
        if (!rawPath || !genericHeader || genericHeader->magic != MH_MAGIC_64) {
            continue;
        }
        NSString *loadedPath = [NSString stringWithUTF8String:rawPath];
        if (![loadedPath isEqualToString:path]) continue;
        return FLEXUUIDForHeader((const struct mach_header_64 *)genericHeader);
    }
    return @"";
}

static const char *FLEXSkipObjCQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static FLEXHookABI FLEXExactObjectiveCABI(Method method) {
    if (!method) return FLEXHookABIUnknown;

    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (*FLEXSkipObjCQualifiers(returnType) != 'B') {
        return FLEXHookABIUnknown;
    }

    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount == 2) {
        return FLEXHookABIObjCBoolNoArguments;
    }
    if (argumentCount != 3) {
        return FLEXHookABIUnknown;
    }

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *argumentCode = FLEXSkipObjCQualifiers(argumentType);
    if (*argumentCode == '@' || *argumentCode == '#' || *argumentCode == ':') {
        return FLEXHookABIObjCBoolObjectArgument;
    }
    if (strchr("BcCsSiIlLqQ", *argumentCode)) {
        return FLEXHookABIObjCBoolIntegerArgument;
    }
    return FLEXHookABIUnknown;
}

static BOOL FLEXSelectorIsOperationalCandidate(const char *selectorName) {
    if (!selectorName || !selectorName[0]) return NO;
    if (strncmp(selectorName, "set", 3) == 0 ||
        strncmp(selectorName, "init", 4) == 0 ||
        strcmp(selectorName, "dealloc") == 0 ||
        strcmp(selectorName, "isEqual:") == 0 ||
        strcmp(selectorName, "respondsToSelector:") == 0) {
        return NO;
    }
    return YES;
}

static NSString *FLEXCurrentHostCIdentifier(NSString *imageUUID,
                                            NSString *symbol) {
    return [NSString stringWithFormat:@"c-import|%@|%@|%@",
        FLEXCurrentHostIdentity(),
        imageUUID.length ? imageUUID : @"unknown-image",
        symbol ?: @""];
}

@implementation FLEXRuntimeScanner

+ (void)startMonitoringImages {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        (void)FLEXRuntimeScannerQueue();
        _dyld_register_func_for_add_image(FLEXRuntimeImageAdded);
    });
}

+ (FLEXHookEntry *)objectiveCEntryForClass:(Class)targetClass
                                  selector:(SEL)selector
                               classMethod:(BOOL)classMethod {
    if (!targetClass || !selector ||
        !FLEXSelectorIsOperationalCandidate(sel_getName(selector))) {
        return nil;
    }

    const char *rawImage = class_getImageName(targetClass);
    if (!rawImage || !rawImage[0]) return nil;
    NSString *imagePath = [NSString stringWithUTF8String:rawImage];
    if (!FLEXPathBelongsToCurrentHost(imagePath)) return nil;

    NSString *imageUUID = FLEXUUIDForLoadedImagePath(imagePath);
    if (!imageUUID.length) return nil;

    Method method = classMethod
        ? class_getClassMethod(targetClass, selector)
        : class_getInstanceMethod(targetClass, selector);
    FLEXHookABI abi = FLEXExactObjectiveCABI(method);
    if (!method || abi == FLEXHookABIUnknown) return nil;

    const char *rawClassName = class_getName(targetClass);
    const char *rawSelectorName = sel_getName(selector);
    if (!rawClassName || !rawSelectorName) return nil;

    NSString *className = [NSString stringWithUTF8String:rawClassName];
    NSString *selectorName = [NSString stringWithUTF8String:rawSelectorName];
    if (!className.length || !selectorName.length) return nil;

    const char *rawEncoding = method_getTypeEncoding(method);
    NSString *encoding = rawEncoding
        ? [NSString stringWithUTF8String:rawEncoding] : @"";
    NSString *host = FLEXCurrentHostIdentity();

    BOOL providerAvailable = FLEXMSHookMessageProviderAvailable();
    BOOL engineEnabled = FLEXFlag(@"engine.objc_ellekit");

    FLEXHookEntry *entry = [FLEXHookEntry new];
    entry.identifier = [NSString stringWithFormat:@"objc|%@|%@|%@|%@|%@",
        host,
        imageUUID,
        className,
        classMethod ? @"+" : @"-",
        selectorName];
    entry.title = [NSString stringWithFormat:@"%@[%@ %@]",
        classMethod ? @"+" : @"-", className, selectorName];
    entry.detail = [NSString stringWithFormat:@"%@ · %@",
        FLEXHookABIName(abi), encoding];
    entry.imageName = imagePath.lastPathComponent ?: imagePath;
    entry.surface = FLEXHookSurfaceObjectiveC;
    entry.backend = FLEXHookBackendObjectiveCElleKit;
    entry.abi = abi;
    entry.locator = @{
        @"source": @"objc-current-host-runtime",
        @"host": host,
        @"class": className,
        @"selector": selectorName,
        @"classMethod": @(classMethod),
        @"encoding": encoding,
        @"image": imagePath,
        @"imageUUID": imageUUID,
        @"methodAddress": @((uintptr_t)method_getImplementation(method)),
    };
    entry.available = providerAvailable;
    entry.hookable = providerAvailable && engineEnabled;
    entry.stale = NO;
    if (!providerAvailable) {
        entry.lastError = @"Substrate-compatible provider unavailable";
    } else if (!engineEnabled) {
        entry.lastError = @"Objective-C/ElleKit engine is disabled";
    }
    return entry;
}

+ (void)scanObjectiveCRuntimeIncludingSystemImages:(BOOL)includeSystemImages
                                         completion:(FLEXRuntimeScanCompletion)completion {
    (void)includeSystemImages;
    dispatch_async(FLEXRuntimeScannerQueue(), ^{
        NSMutableArray<FLEXHookEntry *> *result = [NSMutableArray array];
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);

        for (unsigned int classIndex = 0; classIndex < classCount; classIndex++) {
            @autoreleasepool {
                Class targetClass = classes[classIndex];
                const char *rawImage = class_getImageName(targetClass);
                if (!rawImage || !rawImage[0]) continue;

                NSString *imagePath = [NSString stringWithUTF8String:rawImage];
                if (!FLEXPathBelongsToCurrentHost(imagePath)) continue;

                for (NSUInteger pass = 0; pass < 2; pass++) {
                    BOOL classMethod = pass == 1;
                    Class owner = classMethod ? object_getClass(targetClass) : targetClass;
                    if (!owner) continue;

                    unsigned int methodCount = 0;
                    Method *methods = class_copyMethodList(owner, &methodCount);
                    for (unsigned int methodIndex = 0;
                         methodIndex < methodCount;
                         methodIndex++) {
                        Method method = methods[methodIndex];
                        SEL selector = method_getName(method);
                        FLEXHookEntry *entry = [self
                            objectiveCEntryForClass:targetClass
                                          selector:selector
                                       classMethod:classMethod];
                        if (entry) [result addObject:entry];
                    }
                    if (methods) free(methods);
                }
            }
        }
        if (classes) free(classes);

        [result sortUsingComparator:^NSComparisonResult(
            FLEXHookEntry *left,
            FLEXHookEntry *right
        ) {
            NSComparisonResult imageResult =
                [left.imageName localizedCaseInsensitiveCompare:right.imageName];
            return imageResult == NSOrderedSame
                ? [left.title localizedCaseInsensitiveCompare:right.title]
                : imageResult;
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(result.copy);
        });
    });
}

+ (void)scanCImportsIncludingSystemImages:(BOOL)includeSystemImages
                                completion:(FLEXRuntimeScanCompletion)completion {
    (void)includeSystemImages;
    dispatch_async(FLEXRuntimeScannerQueue(), ^{
        NSMutableDictionary<NSString *, FLEXHookEntry *> *entriesByID =
            [NSMutableDictionary dictionary];

        uint32_t imageCount = _dyld_image_count();
        for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
            @autoreleasepool {
                const char *rawPath = _dyld_get_image_name(imageIndex);
                const struct mach_header *genericHeader =
                    _dyld_get_image_header(imageIndex);
                if (!rawPath || !genericHeader ||
                    genericHeader->magic != MH_MAGIC_64) {
                    continue;
                }

                NSString *imagePath = [NSString stringWithUTF8String:rawPath];
                if (!FLEXPathBelongsToCurrentHost(imagePath)) continue;

                const struct mach_header_64 *header =
                    (const struct mach_header_64 *)genericHeader;
                intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
                const struct segment_command_64 *linkedit = NULL;
                const struct symtab_command *symtabCommand = NULL;
                const struct dysymtab_command *dysymtabCommand = NULL;
                NSMutableArray<NSValue *> *pointerSections =
                    [NSMutableArray array];

                const uint8_t *cursor = (const uint8_t *)(header + 1);
                for (uint32_t commandIndex = 0;
                     commandIndex < header->ncmds;
                     commandIndex++) {
                    const struct load_command *command =
                        (const struct load_command *)cursor;
                    if (command->cmdsize < sizeof(struct load_command)) break;

                    if (command->cmd == LC_SEGMENT_64) {
                        const struct segment_command_64 *segment =
                            (const struct segment_command_64 *)command;
                        if (strcmp(segment->segname, SEG_LINKEDIT) == 0) {
                            linkedit = segment;
                        }

                        const struct section_64 *sections =
                            (const struct section_64 *)(segment + 1);
                        for (uint32_t sectionIndex = 0;
                             sectionIndex < segment->nsects;
                             sectionIndex++) {
                            uint32_t type =
                                sections[sectionIndex].flags & SECTION_TYPE;
                            if (type == S_LAZY_SYMBOL_POINTERS ||
                                type == S_NON_LAZY_SYMBOL_POINTERS) {
                                [pointerSections addObject:
                                    [NSValue valueWithBytes:&sections[sectionIndex]
                                                   objCType:@encode(struct section_64)]];
                            }
                        }
                    } else if (command->cmd == LC_SYMTAB) {
                        symtabCommand = (const struct symtab_command *)command;
                    } else if (command->cmd == LC_DYSYMTAB) {
                        dysymtabCommand =
                            (const struct dysymtab_command *)command;
                    }
                    cursor += command->cmdsize;
                }

                if (!linkedit || !symtabCommand || !dysymtabCommand ||
                    pointerSections.count == 0) {
                    continue;
                }

                uintptr_t linkeditBase = (uintptr_t)slide +
                    (uintptr_t)linkedit->vmaddr -
                    (uintptr_t)linkedit->fileoff;
                const struct nlist_64 *symbols =
                    (const struct nlist_64 *)(linkeditBase +
                                             symtabCommand->symoff);
                const char *strings =
                    (const char *)(linkeditBase + symtabCommand->stroff);
                const uint32_t *indirect =
                    (const uint32_t *)(linkeditBase +
                                       dysymtabCommand->indirectsymoff);
                NSString *imageUUID = FLEXUUIDForHeader(header);
                if (!imageUUID.length) continue;

                for (NSValue *sectionValue in pointerSections) {
                    struct section_64 section;
                    [sectionValue getValue:&section];
                    NSUInteger pointerCount =
                        (NSUInteger)(section.size / sizeof(uintptr_t));

                    for (NSUInteger pointerIndex = 0;
                         pointerIndex < pointerCount;
                         pointerIndex++) {
                        uint64_t indirectIndex =
                            (uint64_t)section.reserved1 + pointerIndex;
                        if (indirectIndex >= dysymtabCommand->nindirectsyms) {
                            break;
                        }

                        uint32_t symbolIndex = indirect[indirectIndex];
                        if (symbolIndex == INDIRECT_SYMBOL_ABS ||
                            symbolIndex == INDIRECT_SYMBOL_LOCAL ||
                            (symbolIndex & INDIRECT_SYMBOL_ABS) ||
                            (symbolIndex & INDIRECT_SYMBOL_LOCAL) ||
                            symbolIndex >= symtabCommand->nsyms) {
                            continue;
                        }

                        uint32_t stringIndex =
                            symbols[symbolIndex].n_un.n_strx;
                        if (stringIndex == 0 ||
                            stringIndex >= symtabCommand->strsize) {
                            continue;
                        }

                        const char *rawSymbol = strings + stringIndex;
                        if (!rawSymbol || !rawSymbol[0]) continue;
                        NSString *symbol =
                            [NSString stringWithUTF8String:rawSymbol];
                        if ([symbol hasPrefix:@"_"]) {
                            symbol = [symbol substringFromIndex:1];
                        }
                        if (!symbol.length) continue;

                        NSString *identifier =
                            FLEXCurrentHostCIdentifier(imageUUID, symbol);
                        FLEXHookEntry *entry = entriesByID[identifier];
                        NSUInteger bindSlots =
                            [entry.locator[@"bindSlots"] unsignedIntegerValue];

                        if (!entry) {
                            entry = [FLEXHookEntry new];
                            entry.identifier = identifier;
                            entry.title = symbol;
                            entry.imageName =
                                imagePath.lastPathComponent ?: imagePath;
                            entry.surface = FLEXHookSurfaceCImport;
                            entry.backend = FLEXHookBackendFishhook;
                            entry.abi = FLEXHookABIUnknown;
                            entry.available = YES;
                            entry.hookable = NO;
                            entry.stale = NO;
                            entriesByID[identifier] = entry;
                        }

                        bindSlots++;
                        entry.locator = @{
                            @"source": @"mach-o-indirect-symbols-current-host",
                            @"host": FLEXCurrentHostIdentity(),
                            @"symbol": symbol,
                            @"image": imagePath,
                            @"imageUUID": imageUUID,
                            @"bindSlots": @(bindSlots),
                        };
                        entry.detail = [NSString stringWithFormat:
                            @"%lu imported bind slot%@ · ABI required",
                            (unsigned long)bindSlots,
                            bindSlots == 1 ? @"" : @"s"];
                    }
                }
            }
        }

        NSArray<FLEXHookEntry *> *result = [entriesByID.allValues
            sortedArrayUsingComparator:^NSComparisonResult(
                FLEXHookEntry *left,
                FLEXHookEntry *right
            ) {
                NSComparisonResult imageResult =
                    [left.imageName localizedCaseInsensitiveCompare:right.imageName];
                return imageResult == NSOrderedSame
                    ? [left.title localizedCaseInsensitiveCompare:right.title]
                    : imageResult;
            }];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(result);
        });
    });
}

+ (FLEXHookEntry *)manualCEntryForSymbol:(NSString *)symbol
                               imageName:(NSString *)imageName {
    NSString *normalized = [symbol hasPrefix:@"_"]
        ? [symbol substringFromIndex:1] : symbol;
    NSString *resolvedImage = imageName ?: @"";
    NSString *imageUUID = FLEXUUIDForLoadedImagePath(resolvedImage);
    NSString *host = FLEXCurrentHostIdentity();

    FLEXHookEntry *entry = [FLEXHookEntry new];
    entry.identifier = [NSString stringWithFormat:@"c-inline|%@|%@|%@",
        host,
        imageUUID.length ? imageUUID : @"unresolved-image",
        normalized ?: @""];
    entry.title = normalized ?: @"";
    entry.detail = @"Manual inline target · explicit ABI required";
    entry.imageName = resolvedImage.lastPathComponent ?: @"Unresolved image";
    entry.surface = FLEXHookSurfaceCInline;
    entry.backend = FLEXHookBackendInlineElleKit;
    entry.abi = FLEXHookABIUnknown;
    entry.locator = @{
        @"source": @"manual-current-host",
        @"host": host,
        @"symbol": normalized ?: @"",
        @"image": resolvedImage,
        @"imageUUID": imageUUID,
        @"bindSlots": @0,
    };
    entry.available = normalized.length > 0 && imageUUID.length > 0 &&
        FLEXMSHookFunctionProviderAvailable();
    entry.hookable = NO;
    entry.userConfigured = YES;
    entry.lastError = entry.available
        ? nil : @"Select a currently loaded host image before resolving this symbol";
    return entry;
}

@end
