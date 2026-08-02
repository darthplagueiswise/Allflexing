#import "FLEXRuntimeImageSession.h"

#import "FLEXHooking.h"
#import "FLEXSymbolRebind.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/vm_prot.h>
#import <objc/runtime.h>
#import <stdatomic.h>

const char *FLEXRuntimeImageSessionABIVersion =
    "AllFLEXing complete selected-image runtime session ABI 1";

static NSString *const FLEXRuntimeImageSessionErrorDomain =
    @"FLEXRuntimeImageSession";

static dispatch_queue_t FLEXRuntimeImageSessionQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.allflexing.runtime-image-session",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_USER_INITIATED,
                0
            )
        );
    });
    return queue;
}

static NSString *FLEXImageUUID(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) return @"";
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid = (const struct uuid_command *)command;
            NSUUID *value = [[NSUUID alloc] initWithUUIDBytes:uuid->uuid];
            return value.UUIDString ?: @"";
        }
        cursor += command->cmdsize;
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
    const char *returnCode = FLEXSkipObjCQualifiers(returnType);
    if (*returnCode != 'B') return FLEXHookABIUnknown;

    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount == 2) return FLEXHookABIObjCBoolNoArguments;
    if (argumentCount != 3) return FLEXHookABIUnknown;

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

static NSString *FLEXNormalizedSymbol(NSString *symbol) {
    return [symbol hasPrefix:@"_"] ? [symbol substringFromIndex:1] : symbol;
}

static NSString *FLEXObjectiveCIdentifier(NSString *image,
                                          NSString *className,
                                          NSString *selector,
                                          BOOL classMethod) {
    return [NSString stringWithFormat:@"objc|%@|%@|%@|%@",
        image.lastPathComponent ?: @"image",
        className ?: @"",
        classMethod ? @"+" : @"-",
        selector ?: @""];
}

static NSString *FLEXCIdentifier(NSString *kind,
                                 NSString *image,
                                 NSString *identity) {
    return [NSString stringWithFormat:@"%@|%@|%@",
        kind,
        image.lastPathComponent ?: @"image",
        identity ?: @""];
}

static void FLEXReportProgress(FLEXRuntimeImageProgress progress,
                               NSString *phase,
                               NSUInteger completed,
                               NSUInteger total) {
    if (!progress) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        progress(phase, completed, total);
    });
}

static BOOL FLEXPathBelongsToHost(NSString *path) {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    return path.length && bundlePath.length && [path hasPrefix:bundlePath];
}

@implementation FLEXRuntimeImageDescriptor

- (id)copyWithZone:(NSZone *)zone {
    FLEXRuntimeImageDescriptor *copy = [[[self class] allocWithZone:zone] init];
    copy.path = self.path;
    copy.displayName = self.displayName;
    copy.uuid = self.uuid;
    copy.headerAddress = self.headerAddress;
    copy.slide = self.slide;
    copy.mainExecutable = self.mainExecutable;
    return copy;
}

@end

@implementation FLEXRuntimeImageSnapshot
@end

@interface FLEXRuntimeImageSession () {
    atomic_bool _cancelled;
}
@property (nonatomic, readwrite) FLEXRuntimeImageDescriptor *image;
@end

@implementation FLEXRuntimeImageSession

+ (NSArray<FLEXRuntimeImageDescriptor *> *)loadedAppImages {
    NSMutableArray<FLEXRuntimeImageDescriptor *> *images = [NSMutableArray array];
    NSString *mainPath = NSBundle.mainBundle.executablePath;
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *genericHeader = _dyld_get_image_header(index);
        if (!rawPath || !genericHeader || genericHeader->magic != MH_MAGIC_64) continue;
        NSString *path = [NSString stringWithUTF8String:rawPath];
        if (!FLEXPathBelongsToHost(path)) continue;

        const struct mach_header_64 *header =
            (const struct mach_header_64 *)genericHeader;
        FLEXRuntimeImageDescriptor *descriptor = [FLEXRuntimeImageDescriptor new];
        descriptor.path = path;
        descriptor.displayName = [path isEqualToString:mainPath]
            ? (NSBundle.mainBundle.bundleIdentifier ?: path.lastPathComponent)
            : path.lastPathComponent;
        descriptor.uuid = FLEXImageUUID(header);
        descriptor.headerAddress = (uintptr_t)header;
        descriptor.slide = _dyld_get_image_vmaddr_slide(index);
        descriptor.mainExecutable = [path isEqualToString:mainPath];
        [images addObject:descriptor];
    }
    [images sortUsingComparator:^NSComparisonResult(
        FLEXRuntimeImageDescriptor *left,
        FLEXRuntimeImageDescriptor *right
    ) {
        if (left.mainExecutable != right.mainExecutable) {
            return left.mainExecutable ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.displayName localizedCaseInsensitiveCompare:right.displayName];
    }];
    return images.copy;
}

- (instancetype)initWithImage:(FLEXRuntimeImageDescriptor *)image {
    self = [super init];
    if (self) {
        _image = [image copy];
        atomic_init(&_cancelled, false);
    }
    return self;
}

- (BOOL)isCancelled {
    return atomic_load_explicit(&_cancelled, memory_order_acquire);
}

- (void)cancel {
    atomic_store_explicit(&_cancelled, true, memory_order_release);
}

- (void)scanKind:(FLEXRuntimeBrowserKind)kind
        progress:(FLEXRuntimeImageProgress)progress
      completion:(FLEXRuntimeImageCompletion)completion {
    atomic_store_explicit(&_cancelled, false, memory_order_release);
    FLEXRuntimeImageDescriptor *image = [self.image copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(FLEXRuntimeImageSessionQueue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled) return;

        NSError *error = nil;
        NSArray<FLEXHookEntry *> *entries = nil;
        NSUInteger objcCount = 0;
        NSUInteger importCount = 0;
        NSUInteger definedCount = 0;
        NSUInteger anonymousCount = 0;

        if (kind == FLEXRuntimeBrowserKindObjectiveC) {
            entries = [self scanObjectiveCImage:image
                                      progress:progress
                                         count:&objcCount
                                         error:&error];
        } else {
            entries = [self scanCImage:image
                              progress:progress
                           importCount:&importCount
                          definedCount:&definedCount
                        anonymousCount:&anonymousCount
                                 error:&error];
        }

        if (self.cancelled) return;
        FLEXRuntimeImageSnapshot *snapshot = nil;
        if (entries) {
            snapshot = [FLEXRuntimeImageSnapshot new];
            snapshot.image = image;
            snapshot.kind = kind;
            snapshot.entries = entries;
            snapshot.objectiveCMethodCount = objcCount;
            snapshot.importedSymbolCount = importCount;
            snapshot.definedFunctionCount = definedCount;
            snapshot.anonymousFunctionCount = anonymousCount;
            snapshot.completedAt = NSDate.date;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(snapshot, error);
        });
    });
}

- (NSArray<FLEXHookEntry *> *)scanObjectiveCImage:(FLEXRuntimeImageDescriptor *)image
                                        progress:(FLEXRuntimeImageProgress)progress
                                           count:(NSUInteger *)count
                                           error:(NSError **)error {
    FLEXReportProgress(progress, @"Reading Objective-C metadata", 0, 0);
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    NSMutableArray<Class> *imageClasses = [NSMutableArray array];
    for (unsigned int index = 0; index < classCount; index++) {
        const char *rawImage = class_getImageName(classes[index]);
        if (!rawImage) continue;
        NSString *classImage = [NSString stringWithUTF8String:rawImage];
        if ([classImage isEqualToString:image.path]) {
            [imageClasses addObject:classes[index]];
        }
    }
    if (classes) free(classes);

    NSMutableArray<FLEXHookEntry *> *result = [NSMutableArray array];
    NSUInteger completed = 0;
    for (Class targetClass in imageClasses) {
        if (self.cancelled) return nil;
        @autoreleasepool {
            NSString *className = NSStringFromClass(targetClass);
            for (NSUInteger pass = 0; pass < 2; pass++) {
                BOOL classMethod = pass == 1;
                Class owner = classMethod ? object_getClass(targetClass) : targetClass;
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(owner, &methodCount);
                for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
                    Method method = methods[methodIndex];
                    SEL selector = method_getName(method);
                    NSString *selectorName = NSStringFromSelector(selector);
                    NSString *encoding = [NSString stringWithUTF8String:
                        method_getTypeEncoding(method) ?: ""];
                    FLEXHookABI abi = FLEXExactObjectiveCABI(method);
                    BOOL provider = FLEXMSHookMessageProviderAvailable();

                    FLEXHookEntry *entry = [FLEXHookEntry new];
                    entry.identifier = FLEXObjectiveCIdentifier(
                        image.path, className, selectorName, classMethod);
                    entry.title = [NSString stringWithFormat:@"%@[%@ %@]",
                        classMethod ? @"+" : @"-", className, selectorName];
                    entry.imageName = image.displayName;
                    entry.surface = FLEXHookSurfaceObjectiveC;
                    entry.backend = FLEXHookBackendObjectiveCElleKit;
                    entry.abi = abi;
                    entry.available = method != NULL && provider;
                    entry.hookable = entry.available && abi != FLEXHookABIUnknown;
                    entry.stale = NO;
                    entry.detail = abi == FLEXHookABIUnknown
                        ? [NSString stringWithFormat:@"ABI unresolved · %@", encoding]
                        : [NSString stringWithFormat:@"%@ · %@",
                            FLEXHookABIName(abi), encoding];
                    entry.locator = @{
                        @"source": @"objc-runtime-metadata",
                        @"class": className ?: @"",
                        @"selector": selectorName ?: @"",
                        @"classMethod": @(classMethod),
                        @"encoding": encoding ?: @"",
                        @"image": image.path,
                        @"imageUUID": image.uuid ?: @"",
                        @"methodAddress": @((uintptr_t)method_getImplementation(method)),
                        @"backendEvidence": @"MSHookMessageEx",
                        @"abiEvidence": abi == FLEXHookABIUnknown
                            ? @"unresolved" : @"objc-type-encoding",
                    };
                    if (!provider) {
                        entry.lastError = @"MSHookMessageEx provider unavailable";
                    } else if (abi == FLEXHookABIUnknown) {
                        entry.lastError = nil;
                    }
                    [result addObject:entry];
                }
                if (methods) free(methods);
            }
        }
        completed++;
        if ((completed & 31) == 0 || completed == imageClasses.count) {
            FLEXReportProgress(progress,
                               @"Resolving Objective-C methods",
                               completed,
                               imageClasses.count);
        }
    }
    if (count) *count = result.count;
    [result sortUsingComparator:^NSComparisonResult(
        FLEXHookEntry *left, FLEXHookEntry *right
    ) {
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];
    return result.copy;
}

struct FLEXIndirectSectionRecord {
    struct section_64 section;
    uint32_t type;
};

static BOOL FLEXReadULEB128(const uint8_t **cursor,
                            const uint8_t *end,
                            uint64_t *value) {
    uint64_t result = 0;
    unsigned shift = 0;
    while (*cursor < end && shift < 64) {
        uint8_t byte = *(*cursor)++;
        result |= ((uint64_t)(byte & 0x7f)) << shift;
        if ((byte & 0x80) == 0) {
            *value = result;
            return YES;
        }
        shift += 7;
    }
    return NO;
}

- (NSArray<FLEXHookEntry *> *)scanCImage:(FLEXRuntimeImageDescriptor *)image
                                progress:(FLEXRuntimeImageProgress)progress
                             importCount:(NSUInteger *)importCount
                            definedCount:(NSUInteger *)definedCount
                          anonymousCount:(NSUInteger *)anonymousCount
                                   error:(NSError **)error {
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)image.headerAddress;
    if (!header || header->magic != MH_MAGIC_64) {
        if (error) {
            *error = [NSError errorWithDomain:FLEXRuntimeImageSessionErrorDomain
                                          code:1
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"Selected Mach-O image is no longer loaded"}];
        }
        return nil;
    }

    FLEXReportProgress(progress, @"Reading Mach-O load commands", 0, 0);
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct linkedit_data_command *functionStarts = NULL;
    uint64_t textVMAddress = 0;
    NSMutableArray<NSValue *> *indirectSections = [NSMutableArray array];
    NSMutableIndexSet *executableSectionIndexes = [NSMutableIndexSet indexSet];
    NSMutableArray<NSValue *> *executableRanges = [NSMutableArray array];

    uint32_t globalSectionIndex = 1;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) linkedit = segment;
            if (strcmp(segment->segname, SEG_TEXT) == 0) textVMAddress = segment->vmaddr;
            BOOL executable = (segment->initprot & VM_PROT_EXECUTE) != 0;
            if (executable && segment->vmsize) {
                NSRange range = NSMakeRange(
                    (NSUInteger)(segment->vmaddr + image.slide),
                    (NSUInteger)segment->vmsize);
                [executableRanges addObject:[NSValue valueWithRange:range]];
            }
            const struct section_64 *sections =
                (const struct section_64 *)(segment + 1);
            for (uint32_t sectionIndex = 0;
                 sectionIndex < segment->nsects;
                 sectionIndex++, globalSectionIndex++) {
                uint32_t type = sections[sectionIndex].flags & SECTION_TYPE;
                if (executable) [executableSectionIndexes addIndex:globalSectionIndex];
                if (type == S_LAZY_SYMBOL_POINTERS ||
                    type == S_NON_LAZY_SYMBOL_POINTERS ||
                    type == S_SYMBOL_STUBS) {
                    struct FLEXIndirectSectionRecord record = {
                        sections[sectionIndex], type
                    };
                    [indirectSections addObject:[NSValue valueWithBytes:&record
                                                                 objCType:@encode(struct FLEXIndirectSectionRecord)]];
                }
            }
        } else if (command->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)command;
        } else if (command->cmd == LC_FUNCTION_STARTS) {
            functionStarts = (const struct linkedit_data_command *)command;
        }
        cursor += command->cmdsize;
    }

    if (!linkedit || !symtab || !dysymtab) {
        if (error) {
            *error = [NSError errorWithDomain:FLEXRuntimeImageSessionErrorDomain
                                          code:2
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"Selected image has no readable Mach-O symbol metadata"}];
        }
        return nil;
    }

    uintptr_t linkeditBase = (uintptr_t)image.slide +
        (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(
        linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(
        linkeditBase + dysymtab->indirectsymoff);

    NSMutableDictionary<NSString *, FLEXHookEntry *> *imports =
        [NSMutableDictionary dictionary];
    NSUInteger processedSections = 0;
    for (NSValue *value in indirectSections) {
        if (self.cancelled) return nil;
        struct FLEXIndirectSectionRecord record;
        [value getValue:&record];
        size_t stride = record.type == S_SYMBOL_STUBS
            ? MAX((uint32_t)1, record.section.reserved2)
            : sizeof(uintptr_t);
        NSUInteger itemCount = (NSUInteger)(record.section.size / stride);
        for (NSUInteger item = 0; item < itemCount; item++) {
            uint64_t indirectIndex = (uint64_t)record.section.reserved1 + item;
            if (indirectIndex >= dysymtab->nindirectsyms) break;
            uint32_t symbolIndex = indirect[indirectIndex];
            if (symbolIndex == INDIRECT_SYMBOL_ABS ||
                symbolIndex == INDIRECT_SYMBOL_LOCAL ||
                (symbolIndex & INDIRECT_SYMBOL_ABS) ||
                (symbolIndex & INDIRECT_SYMBOL_LOCAL) ||
                symbolIndex >= symtab->nsyms) continue;
            uint32_t stringIndex = symbols[symbolIndex].n_un.n_strx;
            if (!stringIndex || stringIndex >= symtab->strsize) continue;
            NSString *symbol = FLEXNormalizedSymbol(
                [NSString stringWithUTF8String:strings + stringIndex]);
            if (!symbol.length) continue;

            NSString *identifier = FLEXCIdentifier(@"c-import", image.path, symbol);
            FLEXHookEntry *entry = imports[identifier];
            if (!entry) {
                entry = [FLEXHookEntry new];
                entry.identifier = identifier;
                entry.title = symbol;
                entry.imageName = image.displayName;
                entry.surface = FLEXHookSurfaceCImport;
                entry.backend = FLEXHookBackendFishhook;
                entry.abi = FLEXHookABIUnknown;
                entry.available = FLEXEmbeddedFishhookAvailable();
                entry.hookable = NO;
                entry.stale = NO;
                entry.locator = @{
                    @"source": @"mach-o-indirect-symbols",
                    @"symbol": symbol,
                    @"image": image.path,
                    @"imageUUID": image.uuid ?: @"",
                    @"bindSlots": @0,
                    @"stubAddresses": @[],
                    @"backendEvidence": @"fishhook-bind-slot",
                    @"abiEvidence": @"unresolved",
                };
                imports[identifier] = entry;
            }
            NSMutableDictionary *locator = [entry.locator mutableCopy];
            if (record.type == S_SYMBOL_STUBS) {
                NSMutableArray *stubs = [locator[@"stubAddresses"] mutableCopy] ?: [NSMutableArray array];
                uintptr_t address = (uintptr_t)(record.section.addr + image.slide + item * stride);
                [stubs addObject:@(address)];
                locator[@"stubAddresses"] = stubs.copy;
            } else {
                NSUInteger slots = [locator[@"bindSlots"] unsignedIntegerValue] + 1;
                locator[@"bindSlots"] = @(slots);
            }
            entry.locator = locator.copy;
        }
        processedSections++;
        FLEXReportProgress(progress,
                           @"Resolving imported symbols",
                           processedSections,
                           indirectSections.count);
    }

    NSMutableDictionary<NSNumber *, FLEXHookEntry *> *functionsByAddress =
        [NSMutableDictionary dictionary];
    NSMutableArray<FLEXHookEntry *> *defined = [NSMutableArray array];
    FLEXReportProgress(progress, @"Reading executable symbols", 0, symtab->nsyms);
    for (uint32_t index = 0; index < symtab->nsyms; index++) {
        if (self.cancelled) return nil;
        const struct nlist_64 *symbolRecord = &symbols[index];
        if ((symbolRecord->n_type & N_STAB) ||
            (symbolRecord->n_type & N_TYPE) != N_SECT ||
            ![executableSectionIndexes containsIndex:symbolRecord->n_sect] ||
            symbolRecord->n_value == 0) continue;
        uint32_t stringIndex = symbolRecord->n_un.n_strx;
        if (!stringIndex || stringIndex >= symtab->strsize) continue;
        NSString *symbol = FLEXNormalizedSymbol(
            [NSString stringWithUTF8String:strings + stringIndex]);
        if (!symbol.length) continue;
        uintptr_t address = (uintptr_t)(symbolRecord->n_value + image.slide);
        NSString *identity = [NSString stringWithFormat:@"0x%llx",
            (unsigned long long)(address - image.headerAddress)];

        FLEXHookEntry *entry = [FLEXHookEntry new];
        entry.identifier = FLEXCIdentifier(@"c-inline", image.path, identity);
        entry.title = symbol;
        entry.imageName = image.displayName;
        entry.surface = FLEXHookSurfaceCInline;
        entry.backend = FLEXHookBackendInlineElleKit;
        entry.abi = FLEXHookABIUnknown;
        entry.available = FLEXMSHookFunctionProviderAvailable();
        entry.hookable = NO;
        entry.stale = NO;
        entry.detail = @"Executable symbol · ABI unresolved";
        entry.locator = @{
            @"source": @"mach-o-symbol-table",
            @"symbol": symbol,
            @"image": image.path,
            @"imageUUID": image.uuid ?: @"",
            @"address": @(address),
            @"offset": @(address - image.headerAddress),
            @"backendEvidence": @"MSHookFunction-executable-address",
            @"abiEvidence": @"unresolved",
        };
        functionsByAddress[@(address)] = entry;
        [defined addObject:entry];
        if ((index & 1023) == 0) {
            FLEXReportProgress(progress,
                               @"Reading executable symbols",
                               index,
                               symtab->nsyms);
        }
    }

    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    if (functionStarts && functionStarts->datasize && textVMAddress) {
        const uint8_t *startCursor = (const uint8_t *)(linkeditBase + functionStarts->dataoff);
        const uint8_t *end = startCursor + functionStarts->datasize;
        uint64_t cumulative = 0;
        while (startCursor < end) {
            uint64_t delta = 0;
            if (!FLEXReadULEB128(&startCursor, end, &delta) || delta == 0) break;
            cumulative += delta;
            uintptr_t address = (uintptr_t)(textVMAddress + image.slide + cumulative);
            [starts addObject:@(address)];
        }
    }
    [starts sortUsingSelector:@selector(compare:)];

    NSUInteger anonymous = 0;
    for (NSUInteger index = 0; index < starts.count; index++) {
        if (self.cancelled) return nil;
        uintptr_t address = starts[index].unsignedLongLongValue;
        FLEXHookEntry *entry = functionsByAddress[@(address)];
        uintptr_t next = index + 1 < starts.count
            ? starts[index + 1].unsignedLongLongValue : address;
        NSUInteger size = next > address ? (NSUInteger)(next - address) : 0;
        if (!entry) {
            NSString *identity = [NSString stringWithFormat:@"0x%llx",
                (unsigned long long)(address - image.headerAddress)];
            entry = [FLEXHookEntry new];
            entry.identifier = FLEXCIdentifier(@"c-inline", image.path, identity);
            entry.title = [NSString stringWithFormat:@"sub_%llx",
                (unsigned long long)(address - image.headerAddress)];
            entry.imageName = image.displayName;
            entry.surface = FLEXHookSurfaceCInline;
            entry.backend = FLEXHookBackendInlineElleKit;
            entry.abi = FLEXHookABIUnknown;
            entry.available = FLEXMSHookFunctionProviderAvailable();
            entry.hookable = NO;
            entry.stale = NO;
            entry.detail = @"Function start · ABI unresolved";
            entry.locator = @{
                @"source": @"LC_FUNCTION_STARTS",
                @"symbol": entry.title,
                @"image": image.path,
                @"imageUUID": image.uuid ?: @"",
                @"address": @(address),
                @"offset": @(address - image.headerAddress),
                @"functionSize": @(size),
                @"backendEvidence": @"MSHookFunction-executable-address",
                @"abiEvidence": @"unresolved",
            };
            functionsByAddress[@(address)] = entry;
            [defined addObject:entry];
            anonymous++;
        } else if (size) {
            NSMutableDictionary *locator = [entry.locator mutableCopy];
            locator[@"functionSize"] = @(size);
            entry.locator = locator.copy;
        }
        if ((index & 1023) == 0 || index + 1 == starts.count) {
            FLEXReportProgress(progress,
                               @"Indexing function starts",
                               index + 1,
                               starts.count);
        }
    }

    for (FLEXHookEntry *entry in imports.allValues) {
        NSUInteger slots = [entry.locator[@"bindSlots"] unsignedIntegerValue];
        NSUInteger stubs = [entry.locator[@"stubAddresses"] count];
        entry.detail = [NSString stringWithFormat:
            @"%lu bind slot%@ · %lu stub%@ · ABI unresolved",
            (unsigned long)slots, slots == 1 ? @"" : @"s",
            (unsigned long)stubs, stubs == 1 ? @"" : @"s"];
    }

    NSMutableArray<FLEXHookEntry *> *result = [NSMutableArray array];
    [result addObjectsFromArray:imports.allValues];
    [result addObjectsFromArray:defined];
    [result sortUsingComparator:^NSComparisonResult(
        FLEXHookEntry *left, FLEXHookEntry *right
    ) {
        if (left.surface != right.surface) {
            return left.surface == FLEXHookSurfaceCImport
                ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];

    if (importCount) *importCount = imports.count;
    if (definedCount) *definedCount = defined.count - anonymous;
    if (anonymousCount) *anonymousCount = anonymous;
    return result.copy;
}

@end
