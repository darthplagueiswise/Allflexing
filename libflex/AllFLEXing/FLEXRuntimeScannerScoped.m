#import "FLEXRuntimeScanner.h"

#import "FLEXABIResolver.h"
#import "FLEXHookPersistence.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"
#import "FLEXSymbolRebind.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/vm_prot.h>
#import <objc/runtime.h>
#import <string.h>

const char *FLEXRuntimeImageScopedScannerABIVersion =
    "AllFLEXing selected-image complete verified-target scanner ABI 1";

static dispatch_queue_t FLEXImageScopedScannerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_USER_INITIATED,
            0
        );
        queue = dispatch_queue_create(
            "com.allflexing.runtime-scanner.selected-image",
            attributes
        );
    });
    return queue;
}

static void FLEXReportScanProgress(FLEXRuntimeScanProgress progress,
                                   NSString *stage,
                                   NSString *imagePath,
                                   NSUInteger completed,
                                   NSUInteger total) {
    if (!progress) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        progress(stage ?: @"Scanning", imagePath, completed, total);
    });
}

static BOOL FLEXImagePathIsInsideHostApp(NSString *path) {
    if (!path.length) {
        return NO;
    }
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    return bundlePath.length && [path hasPrefix:bundlePath];
}

static NSString *FLEXNormalizedCSymbol(NSString *symbol) {
    return [symbol hasPrefix:@"_"] ? [symbol substringFromIndex:1] : symbol;
}

static NSString *FLEXStableCIdentifier(NSString *kind,
                                       NSString *imagePath,
                                       NSString *symbol) {
    return [NSString stringWithFormat:@"%@|%@|%@",
        kind ?: @"c",
        imagePath.lastPathComponent ?: @"unknown-image",
        symbol ?: @""];
}

static NSString *FLEXUUIDForHeader(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) {
        return @"";
    }
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuidCommand =
                (const struct uuid_command *)command;
            NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:uuidCommand->uuid];
            return uuid.UUIDString ?: @"";
        }
        if (command->cmdsize < sizeof(struct load_command)) {
            break;
        }
        cursor += command->cmdsize;
    }
    return @"";
}

static BOOL FLEXLoadedImageForPath(NSString *requestedPath,
                                   const struct mach_header_64 **headerOut,
                                   intptr_t *slideOut,
                                   NSString **resolvedPathOut) {
    if (!requestedPath.length) {
        return NO;
    }
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *header = _dyld_get_image_header(index);
        if (!rawPath || !header || header->magic != MH_MAGIC_64) {
            continue;
        }
        NSString *path = [NSString stringWithUTF8String:rawPath];
        BOOL matches = [path isEqualToString:requestedPath] ||
            (![requestedPath containsString:@"/"] &&
             [path.lastPathComponent isEqualToString:requestedPath]);
        if (!matches) {
            continue;
        }
        if (headerOut) {
            *headerOut = (const struct mach_header_64 *)header;
        }
        if (slideOut) {
            *slideOut = _dyld_get_image_vmaddr_slide(index);
        }
        if (resolvedPathOut) {
            *resolvedPathOut = path;
        }
        return YES;
    }
    return NO;
}

static void *FLEXResolveExportedSymbolInImage(NSString *symbol,
                                              NSString *imagePath) {
    NSString *normalized = FLEXNormalizedCSymbol(symbol);
    if (!normalized.length) {
        return NULL;
    }

    void *handle = NULL;
    BOOL shouldClose = NO;
    if ([imagePath isEqualToString:NSBundle.mainBundle.executablePath]) {
        handle = dlopen(NULL, RTLD_LAZY);
        shouldClose = handle != NULL;
    } else {
        handle = dlopen(imagePath.fileSystemRepresentation,
                        RTLD_LAZY | RTLD_NOLOAD);
        shouldClose = handle != NULL;
    }
    if (!handle) {
        return NULL;
    }

    void *address = dlsym(handle, normalized.UTF8String);
    if (!address && ![symbol isEqualToString:normalized]) {
        address = dlsym(handle, symbol.UTF8String);
    }

    BOOL belongsToImage = NO;
    if (address) {
        Dl_info info = {0};
        if (dladdr(address, &info) != 0 && info.dli_fname) {
            NSString *resolvedPath = [NSString stringWithUTF8String:info.dli_fname];
            belongsToImage = [resolvedPath isEqualToString:imagePath] ||
                [resolvedPath.lastPathComponent isEqualToString:imagePath.lastPathComponent];
        }
    }
    if (shouldClose) {
        dlclose(handle);
    }
    return belongsToImage ? address : NULL;
}

static FLEXHookEntry *FLEXCreateCEntry(NSString *symbol,
                                       NSString *imagePath,
                                       NSString *imageUUID,
                                       FLEXHookBackend backend,
                                       NSUInteger bindSlots,
                                       void *runtimeAddress) {
    FLEXHookABI abi = [FLEXABIResolver exactKnownABIForSymbol:symbol];
    BOOL backendAvailable = NO;
    NSString *kind = nil;
    NSString *backendEvidence = nil;

    if (backend == FLEXHookBackendFishhook) {
        backendAvailable = bindSlots > 0 && FLEXEmbeddedFishhookAvailable();
        kind = @"c-import";
        backendEvidence = [NSString stringWithFormat:
            @"%lu confirmed Mach-O bind slot%@",
            (unsigned long)bindSlots,
            bindSlots == 1 ? @"" : @"s"];
    } else if (backend == FLEXHookBackendInlineElleKit) {
        backendAvailable = runtimeAddress != NULL &&
            FLEXMSHookFunctionProviderAvailable();
        kind = @"c-inline";
        backendEvidence = @"exported live address confirmed in selected image";
    } else {
        return nil;
    }

    if (!backendAvailable) {
        return nil;
    }

    FLEXHookEntry *entry = [FLEXHookEntry new];
    entry.identifier = FLEXStableCIdentifier(kind, imagePath, symbol);
    entry.title = symbol;
    entry.imageName = imagePath.lastPathComponent ?: imagePath;
    entry.surface = backend == FLEXHookBackendFishhook
        ? FLEXHookSurfaceCImport : FLEXHookSurfaceCInline;
    entry.backend = backend;
    entry.abi = abi;
    entry.available = YES;
    entry.hookable = abi != FLEXHookABIUnknown &&
        ((backend == FLEXHookBackendFishhook && FLEXFlag(@"engine.fishhook")) ||
         (backend == FLEXHookBackendInlineElleKit &&
          FLEXFlag(@"engine.inline_ellekit")));
    entry.stale = NO;
    entry.lastError = nil;

    NSMutableDictionary<NSString *, id> *locator = [NSMutableDictionary dictionary];
    locator[@"symbol"] = symbol;
    locator[@"image"] = imagePath;
    locator[@"imageUUID"] = imageUUID ?: @"";
    locator[@"bindSlots"] = @(bindSlots);
    locator[@"backendEvidence"] = backendEvidence;
    locator[@"abiEvidence"] = abi == FLEXHookABIUnknown
        ? @"unresolved" : @"verified-signature-catalog";
    if (runtimeAddress) {
        locator[@"runtimeAddress"] = [NSString stringWithFormat:@"0x%llx",
            (unsigned long long)(uintptr_t)runtimeAddress];
    }
    entry.locator = locator.copy;

    NSString *abiDescription = abi == FLEXHookABIUnknown
        ? @"ABI unresolved — open target and run Resolve ABI"
        : [@"Exact ABI: " stringByAppendingString:FLEXHookABIName(abi)];
    entry.detail = [NSString stringWithFormat:@"%@ · %@",
        backendEvidence, abiDescription];
    return entry;
}

@implementation FLEXRuntimeScanner (AllFLEXingSelectedImageScanning)

+ (NSArray<NSString *> *)loadedImagePathsIncludingSystemImages:(BOOL)includeSystemImages {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *rawPath = _dyld_get_image_name(index);
        if (!rawPath) {
            continue;
        }
        NSString *path = [NSString stringWithUTF8String:rawPath];
        if (!includeSystemImages && !FLEXImagePathIsInsideHostApp(path)) {
            continue;
        }
        [paths addObject:path];
    }
    NSString *mainExecutable = NSBundle.mainBundle.executablePath;
    return [paths.array sortedArrayUsingComparator:^NSComparisonResult(
        NSString *left,
        NSString *right
    ) {
        if ([left isEqualToString:mainExecutable]) return NSOrderedAscending;
        if ([right isEqualToString:mainExecutable]) return NSOrderedDescending;
        return [left.lastPathComponent localizedCaseInsensitiveCompare:
            right.lastPathComponent];
    }];
}

+ (void)scanObjectiveCRuntimeInImagePaths:(NSArray<NSString *> *)imagePaths
                                progress:(FLEXRuntimeScanProgress)progress
                              completion:(FLEXRuntimeScanCompletion)completion {
    NSArray<NSString *> *paths = [[NSOrderedSet orderedSetWithArray:imagePaths].array copy];
    dispatch_async(FLEXImageScopedScannerQueue(), ^{
        NSMutableArray<FLEXHookEntry *> *result = [NSMutableArray array];
        NSUInteger completed = 0;
        for (NSString *path in paths) {
            @autoreleasepool {
                FLEXReportScanProgress(progress,
                    @"Reading Objective-C runtime metadata", path,
                    completed, paths.count);

                unsigned int classCount = 0;
                const char **classNames = objc_copyClassNamesForImage(
                    path.fileSystemRepresentation,
                    &classCount
                );
                for (unsigned int classIndex = 0;
                     classIndex < classCount;
                     classIndex++) {
                    @autoreleasepool {
                        const char *rawClassName = classNames[classIndex];
                        if (!rawClassName) {
                            continue;
                        }
                        Class targetClass = objc_getClass(rawClassName);
                        if (!targetClass) {
                            continue;
                        }
                        for (NSUInteger pass = 0; pass < 2; pass++) {
                            BOOL classMethod = pass == 1;
                            Class owner = classMethod
                                ? object_getClass(targetClass) : targetClass;
                            unsigned int methodCount = 0;
                            Method *methods = owner
                                ? class_copyMethodList(owner, &methodCount) : NULL;
                            for (unsigned int methodIndex = 0;
                                 methodIndex < methodCount;
                                 methodIndex++) {
                                SEL selector = method_getName(methods[methodIndex]);
                                FLEXHookEntry *entry = [self
                                    objectiveCEntryForClass:targetClass
                                                  selector:selector
                                               classMethod:classMethod];
                                if (!entry || !entry.available ||
                                    entry.abi == FLEXHookABIUnknown ||
                                    entry.backend != FLEXHookBackendObjectiveCElleKit) {
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
                if (classNames) {
                    free(classNames);
                }
            }
            completed++;
            FLEXReportScanProgress(progress,
                @"Validated Objective-C hook targets", path,
                completed, paths.count);
        }

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
            if (completion) {
                completion(result.copy);
            }
        });
    });
}

+ (void)scanCFunctionsInImagePaths:(NSArray<NSString *> *)imagePaths
                          progress:(FLEXRuntimeScanProgress)progress
                        completion:(FLEXRuntimeScanCompletion)completion {
    NSArray<NSString *> *paths = [[NSOrderedSet orderedSetWithArray:imagePaths].array copy];
    dispatch_async(FLEXImageScopedScannerQueue(), ^{
        NSMutableDictionary<NSString *, FLEXHookEntry *> *entriesByID =
            [NSMutableDictionary dictionary];
        NSUInteger completed = 0;

        for (NSString *requestedPath in paths) {
            @autoreleasepool {
                FLEXReportScanProgress(progress,
                    @"Reading Mach-O bind and symbol tables", requestedPath,
                    completed, paths.count);

                const struct mach_header_64 *header = NULL;
                intptr_t slide = 0;
                NSString *imagePath = nil;
                if (!FLEXLoadedImageForPath(requestedPath,
                                            &header,
                                            &slide,
                                            &imagePath)) {
                    completed++;
                    continue;
                }

                const struct segment_command_64 *linkedit = NULL;
                const struct symtab_command *symtabCommand = NULL;
                const struct dysymtab_command *dysymtabCommand = NULL;
                NSMutableArray<NSValue *> *pointerSections = [NSMutableArray array];
                NSMutableArray<NSNumber *> *sectionExecutable =
                    [NSMutableArray arrayWithObject:@NO];

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
                            const struct section_64 *section = &sections[sectionIndex];
                            uint32_t type = section->flags & SECTION_TYPE;
                            if (type == S_LAZY_SYMBOL_POINTERS ||
                                type == S_NON_LAZY_SYMBOL_POINTERS) {
                                [pointerSections addObject:[NSValue
                                    valueWithBytes:section
                                          objCType:@encode(struct section_64)]];
                            }
                            BOOL executable = (segment->initprot & VM_PROT_EXECUTE) != 0 ||
                                (section->flags & S_ATTR_PURE_INSTRUCTIONS) != 0 ||
                                (section->flags & S_ATTR_SOME_INSTRUCTIONS) != 0;
                            [sectionExecutable addObject:@(executable)];
                        }
                    } else if (command->cmd == LC_SYMTAB) {
                        symtabCommand = (const struct symtab_command *)command;
                    } else if (command->cmd == LC_DYSYMTAB) {
                        dysymtabCommand = (const struct dysymtab_command *)command;
                    }
                    if (command->cmdsize < sizeof(struct load_command)) {
                        break;
                    }
                    cursor += command->cmdsize;
                }

                if (!linkedit || !symtabCommand) {
                    completed++;
                    continue;
                }

                uintptr_t linkeditBase = (uintptr_t)slide +
                    (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
                const struct nlist_64 *symbols = (const struct nlist_64 *)(
                    linkeditBase + symtabCommand->symoff
                );
                const char *strings = (const char *)(
                    linkeditBase + symtabCommand->stroff
                );
                NSString *uuid = FLEXUUIDForHeader(header);

                if (dysymtabCommand && pointerSections.count) {
                    const uint32_t *indirect = (const uint32_t *)(
                        linkeditBase + dysymtabCommand->indirectsymoff
                    );
                    NSMutableDictionary<NSString *, NSNumber *> *bindCounts =
                        [NSMutableDictionary dictionary];
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
                            uint32_t stringIndex = symbols[symbolIndex].n_un.n_strx;
                            if (!stringIndex || stringIndex >= symtabCommand->strsize) {
                                continue;
                            }
                            const char *rawSymbol = strings + stringIndex;
                            if (!rawSymbol || !*rawSymbol) {
                                continue;
                            }
                            NSString *symbol = FLEXNormalizedCSymbol(
                                [NSString stringWithUTF8String:rawSymbol]
                            );
                            if (!symbol.length) {
                                continue;
                            }
                            bindCounts[symbol] = @([bindCounts[symbol]
                                unsignedIntegerValue] + 1);
                        }
                    }
                    [bindCounts enumerateKeysAndObjectsUsingBlock:^(
                        NSString *symbol,
                        NSNumber *count,
                        BOOL *stop
                    ) {
                        (void)stop;
                        FLEXHookEntry *entry = FLEXCreateCEntry(
                            symbol,
                            imagePath,
                            uuid,
                            FLEXHookBackendFishhook,
                            count.unsignedIntegerValue,
                            NULL
                        );
                        if (entry) {
                            entriesByID[entry.identifier] = entry;
                        }
                    }];
                }

                FLEXReportScanProgress(progress,
                    @"Validating exported inline addresses", imagePath,
                    completed, paths.count);
                for (uint32_t symbolIndex = 0;
                     symbolIndex < symtabCommand->nsyms;
                     symbolIndex++) {
                    const struct nlist_64 symbolRecord = symbols[symbolIndex];
                    if ((symbolRecord.n_type & N_STAB) != 0 ||
                        (symbolRecord.n_type & N_TYPE) != N_SECT ||
                        (symbolRecord.n_type & N_EXT) == 0 ||
                        symbolRecord.n_sect == NO_SECT ||
                        symbolRecord.n_sect >= sectionExecutable.count ||
                        !sectionExecutable[symbolRecord.n_sect].boolValue) {
                        continue;
                    }
                    uint32_t stringIndex = symbolRecord.n_un.n_strx;
                    if (!stringIndex || stringIndex >= symtabCommand->strsize) {
                        continue;
                    }
                    const char *rawSymbol = strings + stringIndex;
                    if (!rawSymbol || !*rawSymbol) {
                        continue;
                    }
                    NSString *symbol = FLEXNormalizedCSymbol(
                        [NSString stringWithUTF8String:rawSymbol]
                    );
                    if (!symbol.length ||
                        [symbol hasPrefix:@"OBJC_"] ||
                        [symbol hasPrefix:@"___objc_"]) {
                        continue;
                    }
                    void *address = FLEXResolveExportedSymbolInImage(
                        symbol,
                        imagePath
                    );
                    if (!address) {
                        continue;
                    }
                    FLEXHookEntry *entry = FLEXCreateCEntry(
                        symbol,
                        imagePath,
                        uuid,
                        FLEXHookBackendInlineElleKit,
                        0,
                        address
                    );
                    if (entry && !entriesByID[entry.identifier]) {
                        entriesByID[entry.identifier] = entry;
                    }
                }
            }

            completed++;
            FLEXReportScanProgress(progress,
                @"Validated hook backends", requestedPath,
                completed, paths.count);
        }

        NSArray<FLEXHookEntry *> *result = [entriesByID.allValues
            sortedArrayUsingComparator:^NSComparisonResult(
                FLEXHookEntry *left,
                FLEXHookEntry *right
            ) {
                NSComparisonResult imageResult =
                    [left.imageName localizedCaseInsensitiveCompare:right.imageName];
                if (imageResult != NSOrderedSame) {
                    return imageResult;
                }
                if (left.backend != right.backend) {
                    return left.backend < right.backend
                        ? NSOrderedAscending : NSOrderedDescending;
                }
                return [left.title localizedCaseInsensitiveCompare:right.title];
            }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(result);
            }
        });
    });
}

@end
