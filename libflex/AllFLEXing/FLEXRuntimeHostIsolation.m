#import "FLEXRuntimeImageSession.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>

const char *FLEXRuntimeHostIsolationABIVersion =
    "AllFLEXing current-process Mach-O host isolation ABI 1";

static NSString *const FLEXRuntimeHostIsolationErrorDomain =
    @"FLEXRuntimeHostIsolation";

static NSString *FLEXHostCanonicalPath(NSString *path) {
    if (!path.length) {
        return @"";
    }
    NSString *resolved = [path stringByResolvingSymlinksInPath];
    NSString *standardized = [resolved stringByStandardizingPath];
    return standardized.length ? standardized : path;
}

static NSString *FLEXHostImageUUID(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) {
        return @"";
    }

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) {
            break;
        }
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuidCommand =
                (const struct uuid_command *)command;
            NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:uuidCommand->uuid];
            return uuid.UUIDString ?: @"";
        }
        cursor += command->cmdsize;
    }
    return @"";
}

static const struct mach_header_64 *FLEXHostMainExecutableHeader(void) {
    const struct mach_header_64 *fallback = NULL;
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const struct mach_header *generic = _dyld_get_image_header(index);
        if (!generic || generic->magic != MH_MAGIC_64) {
            continue;
        }
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)generic;
        if (!fallback) {
            fallback = header;
        }
        if (header->filetype == MH_EXECUTE) {
            return header;
        }
    }
    return fallback;
}

static NSString *FLEXHostExecutableUUID(void) {
    static NSString *uuid;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uuid = FLEXHostImageUUID(FLEXHostMainExecutableHeader());
        if (!uuid.length) {
            uuid = @"unknown-host-uuid";
        }
    });
    return uuid;
}

static BOOL FLEXHostPathBelongsToCurrentBundle(NSString *path) {
    NSString *candidate = FLEXHostCanonicalPath(path);
    NSString *bundle = FLEXHostCanonicalPath(NSBundle.mainBundle.bundlePath);
    NSString *executable = FLEXHostCanonicalPath(NSBundle.mainBundle.executablePath);
    if (!candidate.length || !bundle.length) {
        return NO;
    }
    if (executable.length && [candidate isEqualToString:executable]) {
        return YES;
    }
    NSString *bundlePrefix = [bundle stringByAppendingString:@"/"];
    return [candidate isEqualToString:bundle] ||
           [candidate hasPrefix:bundlePrefix];
}

static FLEXRuntimeImageDescriptor *FLEXHostDescriptorForLoadedIndex(
    uint32_t index,
    const struct mach_header_64 *mainHeader
) {
    const char *rawPath = _dyld_get_image_name(index);
    const struct mach_header *genericHeader = _dyld_get_image_header(index);
    if (!rawPath || !genericHeader || genericHeader->magic != MH_MAGIC_64) {
        return nil;
    }

    const struct mach_header_64 *header =
        (const struct mach_header_64 *)genericHeader;
    NSString *raw = [NSString stringWithUTF8String:rawPath];
    NSString *path = FLEXHostCanonicalPath(raw);
    BOOL mainExecutable = header == mainHeader || header->filetype == MH_EXECUTE;
    if (!mainExecutable && !FLEXHostPathBelongsToCurrentBundle(path)) {
        return nil;
    }

    FLEXRuntimeImageDescriptor *descriptor = [FLEXRuntimeImageDescriptor new];
    descriptor.path = path;
    descriptor.displayName = mainExecutable
        ? (NSBundle.mainBundle.bundleIdentifier ?: path.lastPathComponent)
        : path.lastPathComponent;
    descriptor.uuid = FLEXHostImageUUID(header);
    descriptor.headerAddress = (uintptr_t)header;
    descriptor.slide = _dyld_get_image_vmaddr_slide(index);
    descriptor.mainExecutable = mainExecutable;
    return descriptor;
}

static NSArray<FLEXRuntimeImageDescriptor *> *FLEXHostLoadedImages(void) {
    const struct mach_header_64 *mainHeader = FLEXHostMainExecutableHeader();
    NSMutableArray<FLEXRuntimeImageDescriptor *> *images = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seenHeaders = [NSMutableSet set];

    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        FLEXRuntimeImageDescriptor *descriptor =
            FLEXHostDescriptorForLoadedIndex(index, mainHeader);
        if (!descriptor) {
            continue;
        }
        NSNumber *headerKey = @(descriptor.headerAddress);
        if ([seenHeaders containsObject:headerKey]) {
            continue;
        }
        [seenHeaders addObject:headerKey];
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

static FLEXRuntimeImageDescriptor *FLEXHostCurrentDescriptor(
    FLEXRuntimeImageDescriptor *requested
) {
    if (!requested) {
        return nil;
    }
    NSString *requestedPath = FLEXHostCanonicalPath(requested.path);
    for (FLEXRuntimeImageDescriptor *candidate in FLEXHostLoadedImages()) {
        BOOL sameHeader = requested.headerAddress != 0 &&
                          candidate.headerAddress == requested.headerAddress;
        BOOL samePath = requestedPath.length &&
                        [candidate.path isEqualToString:requestedPath];
        BOOL sameUUID = !requested.uuid.length || !candidate.uuid.length ||
                        [candidate.uuid caseInsensitiveCompare:requested.uuid] ==
                            NSOrderedSame;
        if ((sameHeader || samePath) && sameUUID) {
            return candidate;
        }
    }
    return nil;
}

static BOOL FLEXHostEntryMatchesSelectedImage(
    FLEXHookEntry *entry,
    FLEXRuntimeImageDescriptor *image
) {
    if (!entry || !image) {
        return NO;
    }

    NSDictionary *locator = [entry.locator isKindOfClass:NSDictionary.class]
        ? entry.locator : @{};
    NSString *entryPath = [locator[@"image"] isKindOfClass:NSString.class]
        ? FLEXHostCanonicalPath(locator[@"image"]) : @"";
    NSString *entryUUID = [locator[@"imageUUID"] isKindOfClass:NSString.class]
        ? locator[@"imageUUID"] : @"";

    if (!entryPath.length || ![entryPath isEqualToString:image.path]) {
        return NO;
    }
    if (image.uuid.length && entryUUID.length &&
        [entryUUID caseInsensitiveCompare:image.uuid] != NSOrderedSame) {
        return NO;
    }

    if (entry.surface == FLEXHookSurfaceObjectiveC) {
        NSString *className = [locator[@"class"] isKindOfClass:NSString.class]
            ? locator[@"class"] : nil;
        Class targetClass = className.length ? NSClassFromString(className) : Nil;
        const char *rawClassImage = targetClass ? class_getImageName(targetClass) : NULL;
        NSString *classImage = rawClassImage
            ? FLEXHostCanonicalPath([NSString stringWithUTF8String:rawClassImage])
            : @"";
        if (!classImage.length || ![classImage isEqualToString:image.path]) {
            return NO;
        }
    }
    return YES;
}

static NSString *FLEXHostScopedIdentifier(FLEXHookEntry *entry,
                                          FLEXRuntimeImageDescriptor *image) {
    NSString *hostUUID = FLEXHostExecutableUUID();
    NSString *imageUUID = image.uuid.length ? image.uuid : @"unknown-image-uuid";
    NSString *base = entry.identifier.length ? entry.identifier : @"runtime-entry";
    NSString *prefix = [NSString stringWithFormat:@"runtime|%@|%@|",
        hostUUID, imageUUID];
    return [base hasPrefix:prefix] ? base : [prefix stringByAppendingString:base];
}

static FLEXRuntimeImageSnapshot *FLEXHostFilteredSnapshot(
    FLEXRuntimeImageSnapshot *snapshot,
    FLEXRuntimeImageDescriptor *selectedImage
) {
    FLEXRuntimeImageDescriptor *liveImage = FLEXHostCurrentDescriptor(selectedImage);
    if (!snapshot || !liveImage) {
        return nil;
    }

    NSMutableArray<FLEXHookEntry *> *entries = [NSMutableArray array];
    NSUInteger imported = 0;
    NSUInteger named = 0;
    NSUInteger anonymous = 0;
    NSString *hostUUID = FLEXHostExecutableUUID();

    for (FLEXHookEntry *entry in snapshot.entries ?: @[]) {
        if (!FLEXHostEntryMatchesSelectedImage(entry, liveImage)) {
            continue;
        }

        NSMutableDictionary *locator = [entry.locator mutableCopy]
            ?: [NSMutableDictionary dictionary];
        locator[@"image"] = liveImage.path;
        locator[@"imageUUID"] = liveImage.uuid ?: @"";
        locator[@"hostExecutableUUID"] = hostUUID;
        locator[@"hostBundleIdentifier"] =
            NSBundle.mainBundle.bundleIdentifier ?: @"";
        locator[@"runtimeSessionImageUUID"] = liveImage.uuid ?: @"";
        locator[@"runtimeSessionImagePath"] = liveImage.path;
        entry.locator = locator.copy;
        entry.identifier = FLEXHostScopedIdentifier(entry, liveImage);
        entry.imageName = liveImage.displayName;
        [entries addObject:entry];

        if (entry.surface == FLEXHookSurfaceCImport) {
            imported++;
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

    snapshot.image = liveImage;
    snapshot.entries = entries.copy;
    if (snapshot.kind == FLEXRuntimeBrowserKindObjectiveC) {
        snapshot.objectiveCMethodCount = entries.count;
    } else {
        snapshot.importedSymbolCount = imported;
        snapshot.definedFunctionCount = named;
        snapshot.anonymousFunctionCount = anonymous;
    }
    return snapshot;
}

static void FLEXHostExchangeClassMethods(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getClassMethod(cls, original);
    Method replacementMethod = class_getClassMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

static void FLEXHostExchangeInstanceMethods(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

@interface FLEXRuntimeImageSession (AllFLEXingHostIsolation)
+ (NSArray<FLEXRuntimeImageDescriptor *> *)af_host_loadedAppImages;
- (void)af_host_scanKind:(FLEXRuntimeBrowserKind)kind
                progress:(nullable FLEXRuntimeImageProgress)progress
              completion:(FLEXRuntimeImageCompletion)completion;
@end

@implementation FLEXRuntimeImageSession (AllFLEXingHostIsolation)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLEXHostExchangeClassMethods(
            self,
            @selector(loadedAppImages),
            @selector(af_host_loadedAppImages)
        );
        FLEXHostExchangeInstanceMethods(
            self,
            @selector(scanKind:progress:completion:),
            @selector(af_host_scanKind:progress:completion:)
        );
    });
}

+ (NSArray<FLEXRuntimeImageDescriptor *> *)af_host_loadedAppImages {
    return FLEXHostLoadedImages();
}

- (void)af_host_scanKind:(FLEXRuntimeBrowserKind)kind
                progress:(FLEXRuntimeImageProgress)progress
              completion:(FLEXRuntimeImageCompletion)completion {
    FLEXRuntimeImageDescriptor *selected = FLEXHostCurrentDescriptor(self.image);
    if (!selected) {
        NSError *error = [NSError errorWithDomain:FLEXRuntimeHostIsolationErrorDomain
                                             code:1
                                         userInfo:@{
            NSLocalizedDescriptionKey:
                @"The selected image does not belong to the current host process"
        }];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
        }
        return;
    }

    [self af_host_scanKind:kind
                  progress:progress
                completion:^(FLEXRuntimeImageSnapshot *snapshot, NSError *error) {
        if (error || !snapshot) {
            if (completion) completion(nil, error);
            return;
        }

        FLEXRuntimeImageSnapshot *filtered =
            FLEXHostFilteredSnapshot(snapshot, selected);
        if (!filtered) {
            NSError *isolationError = [NSError
                errorWithDomain:FLEXRuntimeHostIsolationErrorDomain
                           code:2
                       userInfo:@{
                NSLocalizedDescriptionKey:
                    @"The runtime image changed while its snapshot was being built"
            }];
            if (completion) completion(nil, isolationError);
            return;
        }
        if (completion) completion(filtered, nil);
    }];
}

@end
