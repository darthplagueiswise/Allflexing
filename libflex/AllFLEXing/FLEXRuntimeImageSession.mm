#import "FLEXRuntimeImageSession.h"

#import "FLEXHooking.h"
#import "FLEXSymbolRebind.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/vm_prot.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

const char *FLEXRuntimeImageSessionABIVersion =
    "AllFLEXing complete selected-image runtime session ABI 2";
const char *FLEXRuntimeObjectiveCEnumerationABIVersion =
    "AllFLEXing image-scoped nonretaining Objective-C class enumeration ABI 1";
const char *FLEXRuntimeHostIsolationABIVersion =
    "AllFLEXing current-process Mach-O host isolation ABI 2";
const char *FLEXRuntimeBoundedMachOScannerABIVersion =
    "AllFLEXing bounded LINKEDIT scanner and compact function-start ABI 1";

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

static NSString *FLEXRuntimeCanonicalPath(NSString *path) {
    if (!path.length) return @"";
    NSString *resolved = path.stringByResolvingSymlinksInPath;
    NSString *standardized = resolved.stringByStandardizingPath;
    return standardized.length ? standardized : path;
}

static NSString *FLEXImageUUID(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) return @"";
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid =
                (const struct uuid_command *)command;
            NSUUID *value = [[NSUUID alloc] initWithUUIDBytes:uuid->uuid];
            return value.UUIDString ?: @"";
        }
        cursor += command->cmdsize;
    }
    return @"";
}

static const struct mach_header_64 *FLEXRuntimeMainExecutableHeader(void) {
    const struct mach_header_64 *fallback = NULL;
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const struct mach_header *generic = _dyld_get_image_header(index);
        if (!generic || generic->magic != MH_MAGIC_64) continue;
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)generic;
        if (!fallback) fallback = header;
        if (header->filetype == MH_EXECUTE) return header;
    }
    return fallback;
}

static NSString *FLEXRuntimeHostExecutableUUID(void) {
    static NSString *uuid;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uuid = FLEXImageUUID(FLEXRuntimeMainExecutableHeader());
        if (!uuid.length) uuid = @"unknown-host-uuid";
    });
    return uuid;
}

static NSString *FLEXRuntimeHostIdentifier(void) {
    return NSBundle.mainBundle.bundleIdentifier.length
        ? NSBundle.mainBundle.bundleIdentifier
        : (NSProcessInfo.processInfo.processName ?: @"host");
}

static BOOL FLEXRuntimePathIsFrameworkExecutable(NSString *path) {
    NSString *candidate = FLEXRuntimeCanonicalPath(path);
    NSString *bundle = FLEXRuntimeCanonicalPath(NSBundle.mainBundle.bundlePath);
    if (!candidate.length || !bundle.length) return NO;

    NSString *frameworksRoot = [bundle stringByAppendingPathComponent:@"Frameworks"];
    NSString *frameworksPrefix = [frameworksRoot stringByAppendingString:@"/"];
    if (![candidate hasPrefix:frameworksPrefix]) return NO;
    if ([candidate.pathExtension caseInsensitiveCompare:@"dylib"] == NSOrderedSame) {
        return NO;
    }

    NSArray<NSString *> *components = candidate.pathComponents;
    for (NSInteger index = (NSInteger)components.count - 2; index >= 0; index--) {
        NSString *component = components[(NSUInteger)index];
        if ([component.pathExtension caseInsensitiveCompare:@"framework"] !=
            NSOrderedSame) {
            continue;
        }
        NSString *frameworkName = component.stringByDeletingPathExtension;
        if (![candidate.lastPathComponent isEqualToString:frameworkName]) {
            return NO;
        }
        NSString *frameworkPath = [NSString pathWithComponents:
            [components subarrayWithRange:NSMakeRange(0, (NSUInteger)index + 1)]];
        return [candidate hasPrefix:[frameworkPath stringByAppendingString:@"/"]];
    }
    return NO;
}

static BOOL FLEXRuntimePathBelongsToCurrentHost(NSString *path) {
    NSString *candidate = FLEXRuntimeCanonicalPath(path);
    NSString *executable = FLEXRuntimeCanonicalPath(NSBundle.mainBundle.executablePath);
    if (!candidate.length) return NO;
    if (executable.length && [candidate isEqualToString:executable]) return YES;
    return FLEXRuntimePathIsFrameworkExecutable(candidate);
}

static FLEXRuntimeImageDescriptor *FLEXRuntimeDescriptorForLoadedIndex(
    uint32_t index,
    const struct mach_header_64 *mainHeader
) {
    const char *rawPath = _dyld_get_image_name(index);
    const struct mach_header *generic = _dyld_get_image_header(index);
    if (!rawPath || !generic || generic->magic != MH_MAGIC_64) return nil;

    const struct mach_header_64 *header =
        (const struct mach_header_64 *)generic;
    NSString *path = FLEXRuntimeCanonicalPath(
        [NSString stringWithUTF8String:rawPath]
    );
    BOOL mainExecutable = header == mainHeader || header->filetype == MH_EXECUTE;
    if (!mainExecutable && !FLEXRuntimePathBelongsToCurrentHost(path)) return nil;

    FLEXRuntimeImageDescriptor *descriptor = [FLEXRuntimeImageDescriptor new];
    descriptor.path = path;
    descriptor.displayName = mainExecutable
        ? FLEXRuntimeHostIdentifier()
        : path.lastPathComponent;
    descriptor.uuid = FLEXImageUUID(header);
    descriptor.headerAddress = (uintptr_t)header;
    descriptor.slide = _dyld_get_image_vmaddr_slide(index);
    descriptor.mainExecutable = mainExecutable;
    return descriptor;
}

static NSArray<FLEXRuntimeImageDescriptor *> *FLEXRuntimeLoadedHostImages(void) {
    const struct mach_header_64 *mainHeader = FLEXRuntimeMainExecutableHeader();
    NSMutableArray<FLEXRuntimeImageDescriptor *> *images = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seenHeaders = [NSMutableSet set];

    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        FLEXRuntimeImageDescriptor *descriptor =
            FLEXRuntimeDescriptorForLoadedIndex(index, mainHeader);
        if (!descriptor) continue;
        NSNumber *header = @(descriptor.headerAddress);
        if ([seenHeaders containsObject:header]) continue;
        [seenHeaders addObject:header];
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

static FLEXRuntimeImageDescriptor *FLEXRuntimeCurrentDescriptor(
    FLEXRuntimeImageDescriptor *requested
) {
    if (!requested) return nil;
    NSString *requestedPath = FLEXRuntimeCanonicalPath(requested.path);
    for (FLEXRuntimeImageDescriptor *candidate in FLEXRuntimeLoadedHostImages()) {
        BOOL sameHeader = requested.headerAddress != 0 &&
            candidate.headerAddress == requested.headerAddress;
        BOOL samePath = requestedPath.length &&
            [candidate.path isEqualToString:requestedPath];
        BOOL sameUUID = !requested.uuid.length || !candidate.uuid.length ||
            [candidate.uuid caseInsensitiveCompare:requested.uuid] == NSOrderedSame;
        if ((sameHeader || samePath) && sameUUID) return candidate;
    }
    return nil;
}

static BOOL FLEXRuntimeEntryMatchesImage(FLEXHookEntry *entry,
                                         FLEXRuntimeImageDescriptor *image) {
    if (!entry || !image) return NO;
    NSDictionary *locator = [entry.locator isKindOfClass:NSDictionary.class]
        ? entry.locator : @{};
    NSString *entryPath = [locator[@"image"] isKindOfClass:NSString.class]
        ? FLEXRuntimeCanonicalPath(locator[@"image"]) : @"";
    NSString *entryUUID = [locator[@"imageUUID"] isKindOfClass:NSString.class]
        ? locator[@"imageUUID"] : @"";
    if (!entryPath.length || ![entryPath isEqualToString:image.path]) return NO;
    if (entryUUID.length && image.uuid.length &&
        [entryUUID caseInsensitiveCompare:image.uuid] != NSOrderedSame) {
        return NO;
    }

    if (entry.surface == FLEXHookSurfaceObjectiveC) {
        NSString *className = [locator[@"class"] isKindOfClass:NSString.class]
            ? locator[@"class"] : nil;
        Class targetClass = className.length ? NSClassFromString(className) : Nil;
        const char *rawImage = targetClass ? class_getImageName(targetClass) : NULL;
        NSString *classImage = rawImage
            ? FLEXRuntimeCanonicalPath([NSString stringWithUTF8String:rawImage])
            : @"";
        if (!classImage.length || ![classImage isEqualToString:image.path]) return NO;
    }
    return YES;
}

static NSString *FLEXRuntimeScopedIdentifier(FLEXHookEntry *entry,
                                              FLEXRuntimeImageDescriptor *image) {
    NSString *prefix = [NSString stringWithFormat:@"runtime|%@|%@|",
        FLEXRuntimeHostExecutableUUID(),
        image.uuid.length ? image.uuid : @"unknown-image-uuid"];
    NSString *base = entry.identifier.length ? entry.identifier : @"runtime-entry";
    return [base hasPrefix:prefix] ? base : [prefix stringByAppendingString:base];
}

static FLEXRuntimeImageSnapshot *FLEXRuntimeFinalizeSnapshot(
    FLEXRuntimeImageSnapshot *snapshot,
    FLEXRuntimeImageDescriptor *requested
) {
    FLEXRuntimeImageDescriptor *live = FLEXRuntimeCurrentDescriptor(requested);
    if (!snapshot || !live) return nil;

    NSMutableArray<FLEXHookEntry *> *entries = [NSMutableArray array];
    NSUInteger imports = 0;
    NSUInteger named = 0;
    NSUInteger anonymous = 0;
    NSString *hostUUID = FLEXRuntimeHostExecutableUUID();
    NSString *hostID = FLEXRuntimeHostIdentifier();

    for (FLEXHookEntry *entry in snapshot.entries ?: @[]) {
        if (!FLEXRuntimeEntryMatchesImage(entry, live)) continue;
        NSMutableDictionary *locator = [entry.locator mutableCopy]
            ?: [NSMutableDictionary dictionary];
        locator[@"hostBundleIdentifier"] = hostID;
        locator[@"hostExecutableUUID"] = hostUUID;
        locator[@"image"] = live.path;
        locator[@"imageUUID"] = live.uuid ?: @"";
        locator[@"runtimeSessionImagePath"] = live.path;
        locator[@"runtimeSessionImageUUID"] = live.uuid ?: @"";
        locator[@"runtimeHostIsolated"] = @YES;
        entry.locator = locator.copy;
        entry.identifier = FLEXRuntimeScopedIdentifier(entry, live);
        entry.imageName = live.displayName;
        [entries addObject:entry];

        if (entry.surface == FLEXHookSurfaceCImport) {
            imports++;
        } else if (entry.surface == FLEXHookSurfaceCInline) {
            NSString *source = [locator[@"source"] isKindOfClass:NSString.class]
                ? locator[@"source"] : @"";
            if ([source isEqualToString:@"LC_FUNCTION_STARTS"] &&
                [entry.title hasPrefix:@"sub_"]) {
                anonymous++;
            } else {
                named++;
            }
        }
    }

    snapshot.image = live;
    snapshot.entries = entries.copy;
    if (snapshot.kind == FLEXRuntimeBrowserKindObjectiveC) {
        snapshot.objectiveCMethodCount = entries.count;
    } else {
        snapshot.importedSymbolCount = imports;
        snapshot.definedFunctionCount = named;
        snapshot.anonymousFunctionCount = anonymous;
    }
    return snapshot;
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
    if (*FLEXSkipObjCQualifiers(returnType) != 'B') return FLEXHookABIUnknown;

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

static BOOL FLEXRuntimeFileRangeWithinLinkedit(
    const struct segment_command_64 *linkedit,
    uint64_t fileOffset,
    uint64_t length
) {
    if (!linkedit || fileOffset < linkedit->fileoff) return NO;
    uint64_t relative = fileOffset - linkedit->fileoff;
    if (relative > linkedit->filesize) return NO;
    return length <= linkedit->filesize - relative;
}

static NSString *FLEXRuntimeStringFromTable(const char *table,
                                             uint32_t tableSize,
                                             uint32_t index) {
    if (!table || index >= tableSize) return nil;
    size_t maximum = (size_t)tableSize - index;
    size_t length = strnlen(table + index, maximum);
    if (length == maximum) return nil;
    return [[NSString alloc] initWithBytes:table + index
                                   length:length
                                 encoding:NSUTF8StringEncoding];
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
    return FLEXRuntimeLoadedHostImages();
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
    FLEXRuntimeImageDescriptor *image = FLEXRuntimeCurrentDescriptor(self.image);
    if (!image) {
        NSError *error = [NSError errorWithDomain:FLEXRuntimeImageSessionErrorDomain
                                             code:10
                                         userInfo:@{
            NSLocalizedDescriptionKey:
                @"The selected image is not a current executable/framework image of this host"
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil, error);
        });
        return;
    }

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
            snapshot = FLEXRuntimeFinalizeSnapshot(snapshot, image);
            if (!snapshot && !error) {
                error = [NSError errorWithDomain:FLEXRuntimeImageSessionErrorDomain
                                             code:11
                                         userInfo:@{
                    NSLocalizedDescriptionKey:
                        @"The selected Mach-O image changed while its snapshot was built"
                }];
            }
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
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)image.headerAddress;
    if (!header || header->magic != MH_MAGIC_64) {
        if (error) {
            *error = [NSError errorWithDomain:FLEXRuntimeImageSessionErrorDomain
                                          code:3
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"Selected Objective-C image is no longer loaded"}];
        }
        return nil;
    }

    FLEXReportProgress(progress, @"Reading Objective-C metadata", 0, 0);
    BOOL provider = FLEXMSHookMessageProviderAvailable();
    NSMutableArray<FLEXHookEntry *> *result = [NSMutableArray array];
    __block NSUInteger completedClasses = 0;
    __block BOOL cancelled = NO;

    objc_enumerateClasses(
        (const void *)header,
        NULL,
        NULL,
        Nil,
        ^(Class targetClass, BOOL *stop) {
            if (self.cancelled) {
                cancelled = YES;
                *stop = YES;
                return;
            }

            @autoreleasepool {
                const char *rawClassName = class_getName(targetClass);
                if (!rawClassName || rawClassName[0] == '\0') {
                    completedClasses++;
                    return;
                }
                NSString *className = [NSString stringWithUTF8String:rawClassName];
                if (!className.length) {
                    completedClasses++;
                    return;
                }

                for (NSUInteger pass = 0; pass < 2; pass++) {
                    BOOL classMethod = pass == 1;
                    Class owner = classMethod ? object_getClass(targetClass) : targetClass;
                    if (!owner) continue;

                    unsigned int methodCount = 0;
                    Method *methods = class_copyMethodList(owner, &methodCount);
                    for (unsigned int methodIndex = 0;
                         methodIndex < methodCount;
                         methodIndex++) {
                        if (self.cancelled) {
                            cancelled = YES;
                            *stop = YES;
                            break;
                        }

                        Method method = methods[methodIndex];
                        SEL selector = method_getName(method);
                        const char *rawSelectorName = sel_getName(selector);
                        if (!rawSelectorName || rawSelectorName[0] == '\0') continue;
                        NSString *selectorName =
                            [NSString stringWithUTF8String:rawSelectorName];
                        const char *rawEncoding = method_getTypeEncoding(method);
                        NSString *encoding = rawEncoding
                            ? [NSString stringWithUTF8String:rawEncoding] : @"";
                        FLEXHookABI abi = FLEXExactObjectiveCABI(method);
                        if (abi == FLEXHookABIUnknown) continue;

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
                            @"class": className,
                            @"selector": selectorName,
                            @"classMethod": @(classMethod),
                            @"encoding": encoding ?: @"",
                            @"image": image.path,
                            @"imageUUID": image.uuid ?: @"",
                            @"methodAddress":
                                @((uintptr_t)method_getImplementation(method)),
                            @"backendEvidence": @"MSHookMessageEx-live-provider",
                            @"abiEvidence": abi == FLEXHookABIUnknown
                                ? @"unresolved"
                                : @"objc-type-encoding-operational-profile",
                        };
                        if (!provider) {
                            entry.lastError = @"MSHookMessageEx provider unavailable";
                        }
                        [result addObject:entry];
                    }
                    if (methods) free(methods);
                    if (cancelled) break;
                }
            }

            completedClasses++;
            if ((completedClasses & 31) == 0) {
                FLEXReportProgress(progress,
                                   @"Resolving Objective-C methods",
                                   completedClasses,
                                   0);
            }
        }
    );

    if (cancelled || self.cancelled) return nil;
    FLEXReportProgress(progress,
                       @"Resolving Objective-C methods",
                       completedClasses,
                       completedClasses);
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

    uint32_t globalSectionIndex = 1;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    const uint8_t *commandsEnd = cursor + header->sizeofcmds;
    for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex++) {
        if (cursor > commandsEnd ||
            (size_t)(commandsEnd - cursor) < sizeof(struct load_command)) {
            if (error) *error = [NSError errorWithDomain:FLEXRuntimeImageSessionErrorDomain
                                                     code:12
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                                     @"Mach-O load-command table is truncated"}];
            return nil;
        }
        const struct load_command *command = (const struct load_command *)cursor;
        size_t remaining = (size_t)(commandsEnd - cursor);
        if (command->cmdsize < sizeof(struct load_command) ||
            command->cmdsize > remaining) {
            if (error) *error = [NSError errorWithDomain:FLEXRuntimeImageSessionErrorDomain
                                                     code:12
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                                     @"Mach-O load command has an invalid size"}];
            return nil;
        }
        if (command->cmd == LC_SEGMENT_64) {
            if (command->cmdsize < sizeof(struct segment_command_64)) {
                if (error) *error = [NSError errorWithDomain:FLEXRuntimeImageSessionErrorDomain
                                                         code:12
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                                         @"Mach-O segment command is truncated"}];
                return nil;
            }
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            uint64_t sectionBytes = 0;
            if (__builtin_mul_overflow((uint64_t)segment->nsects,
                                       (uint64_t)sizeof(struct section_64),
                                       &sectionBytes) ||
                sectionBytes > command->cmdsize - sizeof(*segment)) {
                if (error) *error = [NSError errorWithDomain:FLEXRuntimeImageSessionErrorDomain
                                                         code:12
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                                         @"Mach-O section table is truncated"}];
                return nil;
            }
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) linkedit = segment;
            if (strcmp(segment->segname, SEG_TEXT) == 0) textVMAddress = segment->vmaddr;
            BOOL executable = (segment->initprot & VM_PROT_EXECUTE) != 0;
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

    uint64_t symbolBytes = 0;
    uint64_t indirectBytes = 0;
    BOOL symbolOverflow = __builtin_mul_overflow(
        (uint64_t)symtab->nsyms,
        (uint64_t)sizeof(struct nlist_64),
        &symbolBytes
    );
    BOOL indirectOverflow = __builtin_mul_overflow(
        (uint64_t)dysymtab->nindirectsyms,
        (uint64_t)sizeof(uint32_t),
        &indirectBytes
    );
    if (symbolOverflow || indirectOverflow ||
        !FLEXRuntimeFileRangeWithinLinkedit(linkedit, symtab->symoff, symbolBytes) ||
        !FLEXRuntimeFileRangeWithinLinkedit(linkedit, symtab->stroff, symtab->strsize) ||
        !FLEXRuntimeFileRangeWithinLinkedit(
            linkedit,
            dysymtab->indirectsymoff,
            indirectBytes
        )) {
        if (error) *error = [NSError errorWithDomain:FLEXRuntimeImageSessionErrorDomain
                                                 code:13
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 @"Mach-O symbol metadata falls outside __LINKEDIT"}];
        return nil;
    }
    if (functionStarts &&
        !FLEXRuntimeFileRangeWithinLinkedit(
            linkedit,
            functionStarts->dataoff,
            functionStarts->datasize
        )) {
        functionStarts = NULL;
    }

    uintptr_t linkeditBase = (uintptr_t)image.slide +
        (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(
        linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);
    const uint32_t *indirect = dysymtab->nindirectsyms
        ? (const uint32_t *)(linkeditBase + dysymtab->indirectsymoff)
        : NULL;

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
        if (!indirect || record.section.reserved1 >= dysymtab->nindirectsyms) {
            continue;
        }
        itemCount = MIN(
            itemCount,
            (NSUInteger)dysymtab->nindirectsyms - record.section.reserved1
        );
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
            FLEXRuntimeStringFromTable(strings, symtab->strsize, stringIndex));
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
                NSMutableArray *stubs = [locator[@"stubAddresses"] mutableCopy]
                    ?: [NSMutableArray array];
                uintptr_t address = (uintptr_t)(record.section.addr +
                    image.slide + item * stride);
                [stubs addObject:@(address)];
                locator[@"stubAddresses"] = stubs.copy;
            } else {
                locator[@"bindSlots"] = @(
                    [locator[@"bindSlots"] unsignedIntegerValue] + 1
                );
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
            FLEXRuntimeStringFromTable(strings, symtab->strsize, stringIndex));
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

    NSUInteger anonymous = 0;
    NSUInteger functionStartCount = 0;
    if (functionStarts && functionStarts->datasize && textVMAddress) {
        const uint8_t *startCursor =
            (const uint8_t *)(linkeditBase + functionStarts->dataoff);
        const uint8_t *end = startCursor + functionStarts->datasize;
        uint64_t cumulative = 0;
        uintptr_t previousAddress = 0;
        while (startCursor < end) {
            uint64_t delta = 0;
            if (!FLEXReadULEB128(&startCursor, end, &delta) || delta == 0) break;
            cumulative += delta;
            uintptr_t address = (uintptr_t)(
                textVMAddress + image.slide + cumulative
            );
            if (previousAddress) {
                FLEXHookEntry *entry = functionsByAddress[@(previousAddress)];
                NSUInteger size = address > previousAddress
                    ? (NSUInteger)(address - previousAddress) : 0;
                if (entry) {
                    if (size) {
                        NSMutableDictionary *locator = [entry.locator mutableCopy];
                        locator[@"functionSize"] = @(size);
                        entry.locator = locator.copy;
                    }
                } else {
                    anonymous++;
                }
            }
            previousAddress = address;
            functionStartCount++;
            if ((functionStartCount & 4095) == 0) {
                FLEXReportProgress(progress,
                                   @"Indexing compact function starts",
                                   functionStartCount,
                                   0);
            }
        }
        if (previousAddress && !functionsByAddress[@(previousAddress)]) {
            anonymous++;
        }
        FLEXReportProgress(progress,
                           @"Indexing compact function starts",
                           functionStartCount,
                           functionStartCount);
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
    if (definedCount) *definedCount = defined.count;
    if (anonymousCount) *anonymousCount = anonymous;
    return result.copy;
}

@end
