#import "FLEXRuntimeScanner.h"

#import "FLEXHookRegistry.h"
#import "FLEXHookPersistence.h"
#import "FLEXHooking.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

NSNotificationName const FLEXRuntimeImagesDidChangeNotification =
    @"FLEXRuntimeImagesDidChangeNotification";

static dispatch_queue_t FLEXRuntimeScannerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.allflexing.runtime-scanner",
                                      DISPATCH_QUEUE_SERIAL);
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

    // dyld invokes this callback while its loader machinery is active. Defer all
    // Objective-C work, debounce image bursts, and never scan from the callback.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   FLEXRuntimeScannerQueue(), ^{
        atomic_store_explicit(&gFLEXRuntimeImageNotificationScheduled,
                              false,
                              memory_order_release);
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:FLEXRuntimeImagesDidChangeNotification
                              object:FLEXRuntimeScanner.class];
        });
    });
}

static BOOL FLEXImageIsInsideHostApp(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    if (bundlePath.length && [path hasPrefix:bundlePath]) {
        return YES;
    }
    NSString *executablePath = NSBundle.mainBundle.executablePath;
    return executablePath.length && [path isEqualToString:executablePath];
}

static const char *FLEXSkipObjCQualifiers(const char *type) {
    if (!type) {
        return "";
    }
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static FLEXHookABI FLEXABIForObjectiveCMethod(Method method) {
    if (!method) {
        return FLEXHookABIUnknown;
    }
    char returnType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *returnCode = FLEXSkipObjCQualifiers(returnType);
    if (*returnCode != 'B' && *returnCode != 'c' && *returnCode != 'C') {
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
    if (strchr("BcCsSiIlLqQ^*", *argumentCode)) {
        return FLEXHookABIObjCBoolIntegerArgument;
    }
    return FLEXHookABIUnknown;
}

static BOOL FLEXSelectorIsSafeCandidate(const char *selectorName) {
    if (!selectorName || !*selectorName) {
        return NO;
    }
    if (strncmp(selectorName, "set", 3) == 0 ||
        strncmp(selectorName, "init", 4) == 0 ||
        strcmp(selectorName, "dealloc") == 0 ||
        strcmp(selectorName, "isEqual:") == 0 ||
        strcmp(selectorName, "respondsToSelector:") == 0) {
        return NO;
    }
    return YES;
}

static NSString *FLEXStableObjectiveCIdentifier(NSString *image,
                                                 NSString *className,
                                                 NSString *selector,
                                                 BOOL classMethod) {
    return [NSString stringWithFormat:@"objc|%@|%@|%@|%@",
        image.lastPathComponent ?: @"unknown",
        className ?: @"",
        classMethod ? @"+" : @"-",
        selector ?: @""];
}

static NSString *FLEXStableCIdentifier(NSString *image, NSString *symbol) {
    return [NSString stringWithFormat:@"c-import|%@|%@",
        image.lastPathComponent ?: @"any-image",
        symbol ?: @""];
}

static NSString *FLEXUUIDForHeader(const struct mach_header_64 *header) {
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuidCommand = (const struct uuid_command *)command;
            NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:uuidCommand->uuid];
            return uuid.UUIDString ?: @"";
        }
        if (command->cmdsize == 0) {
            break;
        }
        cursor += command->cmdsize;
    }
    return @"";
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
        !FLEXSelectorIsSafeCandidate(sel_getName(selector))) {
        return nil;
    }

    Method method = classMethod
        ? class_getClassMethod(targetClass, selector)
        : class_getInstanceMethod(targetClass, selector);
    FLEXHookABI abi = FLEXABIForObjectiveCMethod(method);
    if (!method || abi == FLEXHookABIUnknown) {
        return nil;
    }

    NSString *className = NSStringFromClass(targetClass);
    NSString *selectorName = NSStringFromSelector(selector);
    const char *rawImage = class_getImageName(targetClass);
    NSString *image = rawImage
        ? [NSString stringWithUTF8String:rawImage]
        : @"Created at Runtime";
    NSString *encoding = [NSString stringWithUTF8String:
        method_getTypeEncoding(method) ?: ""];
    if (className.length == 0 || selectorName.length == 0) {
        return nil;
    }

    BOOL providerAvailable = FLEXMSHookProviderAvailable();
    BOOL engineEnabled = FLEXFlag(@"engine.objc_ellekit");
    FLEXHookEntry *entry = [FLEXHookEntry new];
    entry.identifier = FLEXStableObjectiveCIdentifier(
        image, className, selectorName, classMethod
    );
    entry.title = [NSString stringWithFormat:@"%@[%@ %@]",
        classMethod ? @"+" : @"-", className, selectorName];
    entry.detail = [NSString stringWithFormat:@"%@ · %@",
        FLEXHookABIName(abi), encoding];
    entry.imageName = image.lastPathComponent ?: image;
    entry.surface = FLEXHookSurfaceObjectiveC;
    entry.backend = FLEXHookBackendObjectiveCElleKit;
    entry.abi = abi;
    entry.locator = @{
        @"class": className,
        @"selector": selectorName,
        @"classMethod": @(classMethod),
        @"encoding": encoding,
        @"image": image,
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
    dispatch_async(FLEXRuntimeScannerQueue(), ^{
        NSMutableArray<FLEXHookEntry *> *result = [NSMutableArray array];
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        for (unsigned int classIndex = 0; classIndex < classCount; classIndex++) {
            @autoreleasepool {
                Class targetClass = classes[classIndex];
                const char *rawImage = class_getImageName(targetClass);
                if (!rawImage) {
                    continue;
                }
                NSString *image = [NSString stringWithUTF8String:rawImage];
                if (!includeSystemImages && !FLEXImageIsInsideHostApp(image)) {
                    continue;
                }

                NSString *className = NSStringFromClass(targetClass);
                if (className.length == 0) {
                    continue;
                }

                for (NSUInteger pass = 0; pass < 2; pass++) {
                    BOOL classMethod = pass == 1;
                    Class owner = classMethod ? object_getClass(targetClass) : targetClass;
                    if (!owner) {
                        continue;
                    }
                    unsigned int methodCount = 0;
                    Method *methods = class_copyMethodList(owner, &methodCount);
                    for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
                        Method method = methods[methodIndex];
                        SEL selector = method_getName(method);
                        const char *rawSelector = sel_getName(selector);
                        if (!FLEXSelectorIsSafeCandidate(rawSelector)) {
                            continue;
                        }
                        FLEXHookEntry *entry = [self
                            objectiveCEntryForClass:targetClass
                                          selector:selector
                                       classMethod:classMethod];
                        if (!entry) {
                            continue;
                        }
                        [result addObject:entry];
                    }
                    if (methods) {
                        free(methods);
                    }
                }
            }
        }
        if (classes) {
            free(classes);
        }

        [result sortUsingComparator:^NSComparisonResult(FLEXHookEntry *left,
                                                         FLEXHookEntry *right) {
            return [left.title localizedCaseInsensitiveCompare:right.title];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(result.copy);
            }
        });
    });
}

+ (void)scanCImportsIncludingSystemImages:(BOOL)includeSystemImages
                                completion:(FLEXRuntimeScanCompletion)completion {
    dispatch_async(FLEXRuntimeScannerQueue(), ^{
        NSMutableDictionary<NSString *, FLEXHookEntry *> *entriesByID =
            [NSMutableDictionary dictionary];

        for (uint32_t imageIndex = 0; imageIndex < _dyld_image_count(); imageIndex++) {
            @autoreleasepool {
                const char *rawPath = _dyld_get_image_name(imageIndex);
                const struct mach_header *genericHeader = _dyld_get_image_header(imageIndex);
                if (!rawPath || !genericHeader || genericHeader->magic != MH_MAGIC_64) {
                    continue;
                }
                NSString *imagePath = [NSString stringWithUTF8String:rawPath];
                if (!includeSystemImages && !FLEXImageIsInsideHostApp(imagePath)) {
                    continue;
                }

                const struct mach_header_64 *header =
                    (const struct mach_header_64 *)genericHeader;
                intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
                const struct segment_command_64 *linkedit = NULL;
                const struct symtab_command *symtabCommand = NULL;
                const struct dysymtab_command *dysymtabCommand = NULL;
                NSMutableArray<NSValue *> *pointerSections = [NSMutableArray array];

                const uint8_t *cursor = (const uint8_t *)(header + 1);
                for (uint32_t commandIndex = 0;
                     commandIndex < header->ncmds;
                     commandIndex++) {
                    const struct load_command *command =
                        (const struct load_command *)cursor;
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
                            uint32_t type = sections[sectionIndex].flags & SECTION_TYPE;
                            if (type == S_LAZY_SYMBOL_POINTERS ||
                                type == S_NON_LAZY_SYMBOL_POINTERS) {
                                [pointerSections addObject:[NSValue valueWithBytes:&sections[sectionIndex]
                                                                              objCType:@encode(struct section_64)]];
                            }
                        }
                    } else if (command->cmd == LC_SYMTAB) {
                        symtabCommand = (const struct symtab_command *)command;
                    } else if (command->cmd == LC_DYSYMTAB) {
                        dysymtabCommand = (const struct dysymtab_command *)command;
                    }
                    if (command->cmdsize == 0) {
                        break;
                    }
                    cursor += command->cmdsize;
                }

                if (!linkedit || !symtabCommand || !dysymtabCommand ||
                    pointerSections.count == 0) {
                    continue;
                }

                uintptr_t linkeditBase = (uintptr_t)slide +
                    (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
                const struct nlist_64 *symbols = (const struct nlist_64 *)(
                    linkeditBase + symtabCommand->symoff
                );
                const char *strings = (const char *)(linkeditBase + symtabCommand->stroff);
                const uint32_t *indirect = (const uint32_t *)(
                    linkeditBase + dysymtabCommand->indirectsymoff
                );
                NSString *uuid = FLEXUUIDForHeader(header);

                for (NSValue *sectionValue in pointerSections) {
                    struct section_64 section;
                    [sectionValue getValue:&section];
                    NSUInteger pointerCount = (NSUInteger)(section.size / sizeof(uintptr_t));
                    for (NSUInteger pointerIndex = 0;
                         pointerIndex < pointerCount;
                         pointerIndex++) {
                        uint64_t indirectIndex = (uint64_t)section.reserved1 + pointerIndex;
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
                        uint32_t stringIndex = symbols[symbolIndex].n_un.n_strx;
                        if (stringIndex == 0 || stringIndex >= symtabCommand->strsize) {
                            continue;
                        }
                        const char *rawSymbol = strings + stringIndex;
                        if (!rawSymbol || !*rawSymbol) {
                            continue;
                        }
                        NSString *symbol = [NSString stringWithUTF8String:rawSymbol];
                        if ([symbol hasPrefix:@"_"]) {
                            symbol = [symbol substringFromIndex:1];
                        }
                        if (symbol.length == 0) {
                            continue;
                        }

                        NSString *identifier = FLEXStableCIdentifier(imagePath, symbol);
                        FLEXHookEntry *entry = entriesByID[identifier];
                        NSUInteger bindSlots = [entry.locator[@"bindSlots"] unsignedIntegerValue];
                        if (!entry) {
                            entry = [FLEXHookEntry new];
                            entry.identifier = identifier;
                            entry.title = symbol;
                            entry.imageName = imagePath.lastPathComponent ?: imagePath;
                            entry.surface = FLEXHookSurfaceCImport;
                            entry.backend = FLEXHookBackendAuto;
                            entry.abi = FLEXHookABIUnknown;
                            entry.available = YES;
                            entry.hookable = NO;
                            entry.stale = NO;
                            entry.lastError = nil;
                            entriesByID[identifier] = entry;
                        }
                        bindSlots++;
                        entry.locator = @{
                            @"symbol": symbol,
                            @"image": imagePath,
                            @"imageUUID": uuid ?: @"",
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
            sortedArrayUsingComparator:^NSComparisonResult(FLEXHookEntry *left,
                                                            FLEXHookEntry *right) {
                NSComparisonResult imageResult =
                    [left.imageName localizedCaseInsensitiveCompare:right.imageName];
                return imageResult == NSOrderedSame
                    ? [left.title localizedCaseInsensitiveCompare:right.title]
                    : imageResult;
            }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(result);
            }
        });
    });
}

+ (FLEXHookEntry *)manualCEntryForSymbol:(NSString *)symbol
                               imageName:(NSString *)imageName {
    NSString *normalized = [symbol hasPrefix:@"_"]
        ? [symbol substringFromIndex:1] : symbol;
    FLEXHookEntry *entry = [FLEXHookEntry new];
    entry.identifier = [NSString stringWithFormat:@"c-inline|%@|%@",
        imageName.lastPathComponent ?: @"global", normalized ?: @""];
    entry.title = normalized ?: @"";
    entry.detail = @"Manual inline target · explicit ABI required";
    entry.imageName = imageName.lastPathComponent ?: @"Global namespace";
    entry.surface = FLEXHookSurfaceCInline;
    entry.backend = FLEXHookBackendInlineElleKit;
    entry.abi = FLEXHookABIUnknown;
    entry.locator = @{
        @"symbol": normalized ?: @"",
        @"image": imageName ?: @"",
        @"bindSlots": @0,
    };
    entry.available = normalized.length > 0 && FLEXMSHookProviderAvailable();
    entry.hookable = NO;
    entry.userConfigured = YES;
    entry.lastError = entry.available ? nil : @"Symbol/provider unavailable";
    return entry;
}

@end
