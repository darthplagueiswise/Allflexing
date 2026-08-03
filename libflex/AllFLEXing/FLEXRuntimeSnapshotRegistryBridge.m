#import "FLEXHookRegistry.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>

const char *FLEXRuntimeSnapshotRegistryBridgeABIVersion =
    "AllFLEXing host/image-scoped transient runtime bridge ABI 3";

static NSMapTable<NSString *, FLEXHookEntry *> *FLEXTransientRuntimeEntries(void) {
    static NSMapTable<NSString *, FLEXHookEntry *> *entries;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        entries = [NSMapTable strongToWeakObjectsMapTable];
    });
    return entries;
}

static NSString *FLEXBridgeCanonicalPath(NSString *path) {
    if (!path.length) {
        return @"";
    }
    NSString *resolved = [path stringByResolvingSymlinksInPath];
    NSString *standardized = [resolved stringByStandardizingPath];
    return standardized.length ? standardized : path;
}

static NSString *FLEXBridgeImageUUID(const struct mach_header_64 *header) {
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

static const struct mach_header_64 *FLEXBridgeMainExecutableHeader(void) {
    const struct mach_header_64 *fallback = NULL;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
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

static NSString *FLEXBridgeCurrentHostUUID(void) {
    static NSString *uuid;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uuid = FLEXBridgeImageUUID(FLEXBridgeMainExecutableHeader());
        if (!uuid.length) {
            uuid = @"unknown-host-uuid";
        }
    });
    return uuid;
}

static BOOL FLEXBridgePathBelongsToCurrentBundle(NSString *path) {
    NSString *candidate = FLEXBridgeCanonicalPath(path);
    NSString *bundle = FLEXBridgeCanonicalPath(NSBundle.mainBundle.bundlePath);
    NSString *executable = FLEXBridgeCanonicalPath(NSBundle.mainBundle.executablePath);
    if (!candidate.length || !bundle.length) {
        return NO;
    }
    if (executable.length && [candidate isEqualToString:executable]) {
        return YES;
    }
    return [candidate hasPrefix:[bundle stringByAppendingString:@"/"]];
}

static NSDictionary<NSString *, NSString *> *FLEXBridgeLiveImageIdentity(
    NSString *requestedPath
) {
    NSString *canonical = FLEXBridgeCanonicalPath(requestedPath);
    if (!canonical.length || !FLEXBridgePathBelongsToCurrentBundle(canonical)) {
        return nil;
    }

    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *generic = _dyld_get_image_header(index);
        if (!rawPath || !generic || generic->magic != MH_MAGIC_64) {
            continue;
        }
        NSString *loaded = FLEXBridgeCanonicalPath(
            [NSString stringWithUTF8String:rawPath]
        );
        if (![loaded isEqualToString:canonical]) {
            continue;
        }
        NSString *uuid = FLEXBridgeImageUUID(
            (const struct mach_header_64 *)generic
        );
        return @{
            @"path": loaded,
            @"uuid": uuid ?: @"",
        };
    }
    return nil;
}

static BOOL FLEXBridgeRuntimeSurface(FLEXHookEntry *entry) {
    return entry.surface == FLEXHookSurfaceObjectiveC ||
           entry.surface == FLEXHookSurfaceCImport ||
           entry.surface == FLEXHookSurfaceCInline;
}

static BOOL FLEXBridgeEntryMatchesCurrentHost(FLEXHookEntry *entry) {
    if (!entry || !FLEXBridgeRuntimeSurface(entry)) {
        return entry != nil;
    }

    NSDictionary *locator = [entry.locator isKindOfClass:NSDictionary.class]
        ? entry.locator : @{};
    NSString *hostUUID = [locator[@"hostExecutableUUID"]
        isKindOfClass:NSString.class] ? locator[@"hostExecutableUUID"] : @"";
    NSString *imagePath = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : @"";
    NSString *imageUUID = [locator[@"imageUUID"] isKindOfClass:NSString.class]
        ? locator[@"imageUUID"] : @"";
    NSDictionary *live = FLEXBridgeLiveImageIdentity(imagePath);

    if (!hostUUID.length ||
        [hostUUID caseInsensitiveCompare:FLEXBridgeCurrentHostUUID()] !=
            NSOrderedSame ||
        !live) {
        return NO;
    }
    NSString *liveUUID = live[@"uuid"] ?: @"";
    if (imageUUID.length && liveUUID.length &&
        [imageUUID caseInsensitiveCompare:liveUUID] != NSOrderedSame) {
        return NO;
    }

    if (entry.surface == FLEXHookSurfaceObjectiveC) {
        NSString *className = [locator[@"class"] isKindOfClass:NSString.class]
            ? locator[@"class"] : nil;
        Class targetClass = className.length ? NSClassFromString(className) : Nil;
        const char *rawImage = targetClass ? class_getImageName(targetClass) : NULL;
        NSString *classImage = rawImage
            ? FLEXBridgeCanonicalPath([NSString stringWithUTF8String:rawImage])
            : @"";
        if (!classImage.length || ![classImage isEqualToString:live[@"path"]]) {
            return NO;
        }
    }
    return YES;
}

static BOOL FLEXBridgePrepareRuntimeEntry(FLEXHookEntry *entry) {
    if (!FLEXBridgeRuntimeSurface(entry)) {
        return YES;
    }

    NSMutableDictionary *locator = [entry.locator mutableCopy]
        ?: [NSMutableDictionary dictionary];
    NSString *imagePath = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : @"";
    NSDictionary *live = FLEXBridgeLiveImageIdentity(imagePath);
    if (!live) {
        entry.available = NO;
        entry.hookable = NO;
        entry.stale = YES;
        entry.lastError = @"Runtime target does not belong to the current host process";
        return NO;
    }

    if (entry.surface == FLEXHookSurfaceObjectiveC) {
        NSString *className = [locator[@"class"] isKindOfClass:NSString.class]
            ? locator[@"class"] : nil;
        Class targetClass = className.length ? NSClassFromString(className) : Nil;
        const char *rawImage = targetClass ? class_getImageName(targetClass) : NULL;
        NSString *classImage = rawImage
            ? FLEXBridgeCanonicalPath([NSString stringWithUTF8String:rawImage])
            : @"";
        if (!classImage.length || ![classImage isEqualToString:live[@"path"]]) {
            entry.available = NO;
            entry.hookable = NO;
            entry.stale = YES;
            entry.lastError = @"Objective-C class belongs to a different Mach-O image";
            return NO;
        }
    }

    NSString *hostUUID = FLEXBridgeCurrentHostUUID();
    NSString *imageUUID = live[@"uuid"].length
        ? live[@"uuid"] : @"unknown-image-uuid";
    locator[@"image"] = live[@"path"];
    locator[@"imageUUID"] = live[@"uuid"] ?: @"";
    locator[@"hostExecutableUUID"] = hostUUID;
    locator[@"hostBundleIdentifier"] =
        NSBundle.mainBundle.bundleIdentifier ?: @"";
    locator[@"runtimeSessionImageUUID"] = live[@"uuid"] ?: @"";
    locator[@"runtimeSessionImagePath"] = live[@"path"];
    entry.locator = locator.copy;

    NSString *prefix = [NSString stringWithFormat:@"runtime|%@|%@|",
        hostUUID, imageUUID];
    NSString *base = entry.identifier.length ? entry.identifier : @"runtime-entry";
    if (![base hasPrefix:prefix]) {
        entry.identifier = [prefix stringByAppendingString:base];
    }
    return YES;
}

static BOOL FLEXBridgeSameRuntimeIdentity(FLEXHookEntry *left,
                                          FLEXHookEntry *right) {
    if (!left || !right) {
        return NO;
    }
    NSDictionary *a = [left.locator isKindOfClass:NSDictionary.class]
        ? left.locator : @{};
    NSDictionary *b = [right.locator isKindOfClass:NSDictionary.class]
        ? right.locator : @{};
    NSString *aHost = [a[@"hostExecutableUUID"] isKindOfClass:NSString.class]
        ? a[@"hostExecutableUUID"] : @"";
    NSString *bHost = [b[@"hostExecutableUUID"] isKindOfClass:NSString.class]
        ? b[@"hostExecutableUUID"] : @"";
    NSString *aImage = [a[@"imageUUID"] isKindOfClass:NSString.class]
        ? a[@"imageUUID"] : @"";
    NSString *bImage = [b[@"imageUUID"] isKindOfClass:NSString.class]
        ? b[@"imageUUID"] : @"";
    return aHost.length && bHost.length && aImage.length && bImage.length &&
        [aHost caseInsensitiveCompare:bHost] == NSOrderedSame &&
        [aImage caseInsensitiveCompare:bImage] == NSOrderedSame;
}

static FLEXHookEntry *FLEXBridgePromotableEntryCopy(FLEXHookEntry *entry) {
    FLEXHookEntry *copy = [entry copy];
    NSMutableDictionary *locator = [copy.locator mutableCopy]
        ?: [NSMutableDictionary dictionary];
    locator[@"runtimeSnapshotPromoted"] = @YES;
    copy.locator = locator.copy;
    return copy;
}

static void FLEXBridgeExchangeInstanceMethods(Class cls,
                                               SEL original,
                                               SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

@interface FLEXHookRegistry (AllFLEXingRuntimeSnapshotBridgePrivate)
- (FLEXHookEntry *)af_host_upsertDiscoveredEntry:(FLEXHookEntry *)entry;
- (void)af_host_stageEnabled:(BOOL)enabled
          forEntryIdentifier:(NSString *)identifier;
- (nullable FLEXHookEntry *)af_host_entryForIdentifier:(NSString *)identifier;
- (NSArray<FLEXHookEntry *> *)af_host_entries;
- (NSArray<FLEXHookEntry *> *)af_host_entriesForSurface:(FLEXHookSurface)surface;
- (void)af_host_reapplyPersistedEntries;
@end

@implementation FLEXHookRegistry (AllFLEXingRuntimeSnapshotBridge)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FLEXHookRegistry.class;
        FLEXBridgeExchangeInstanceMethods(
            cls,
            @selector(upsertDiscoveredEntry:),
            @selector(af_host_upsertDiscoveredEntry:)
        );
        FLEXBridgeExchangeInstanceMethods(
            cls,
            @selector(stageEnabled:forEntryIdentifier:),
            @selector(af_host_stageEnabled:forEntryIdentifier:)
        );
        FLEXBridgeExchangeInstanceMethods(
            cls,
            @selector(entryForIdentifier:),
            @selector(af_host_entryForIdentifier:)
        );
        FLEXBridgeExchangeInstanceMethods(
            cls,
            @selector(entries),
            @selector(af_host_entries)
        );
        FLEXBridgeExchangeInstanceMethods(
            cls,
            @selector(entriesForSurface:),
            @selector(af_host_entriesForSurface:)
        );
        FLEXBridgeExchangeInstanceMethods(
            cls,
            @selector(reapplyPersistedEntries),
            @selector(af_host_reapplyPersistedEntries)
        );
    });
}

- (FLEXHookEntry *)af_host_upsertDiscoveredEntry:(FLEXHookEntry *)entry {
    if (!entry || !FLEXBridgeRuntimeSurface(entry)) {
        return [self af_host_upsertDiscoveredEntry:entry];
    }

    if (!FLEXBridgePrepareRuntimeEntry(entry)) {
        return entry;
    }

    FLEXHookEntry *existing = [self af_host_entryForIdentifier:entry.identifier];
    if (existing && FLEXBridgeSameRuntimeIdentity(existing, entry) &&
        (existing.userConfigured || entry.userConfigured)) {
        return [self af_host_upsertDiscoveredEntry:entry];
    }

    @synchronized (FLEXTransientRuntimeEntries()) {
        [FLEXTransientRuntimeEntries() setObject:entry forKey:entry.identifier];
    }

    // A scan is a process-local, selected-image snapshot. It must never seed
    // the global registry or persistence until the user explicitly configures
    // that exact host/image-scoped target.
    if (!entry.userConfigured) {
        return entry;
    }
    return [self af_host_upsertDiscoveredEntry:entry];
}

- (void)af_host_stageEnabled:(BOOL)enabled
          forEntryIdentifier:(NSString *)identifier {
    FLEXHookEntry *existing = [self af_host_entryForIdentifier:identifier];
    if (existing && !FLEXBridgeEntryMatchesCurrentHost(existing)) {
        existing = nil;
    }

    if (enabled && !existing) {
        FLEXHookEntry *transient = nil;
        @synchronized (FLEXTransientRuntimeEntries()) {
            transient = [FLEXTransientRuntimeEntries() objectForKey:identifier];
        }
        if (transient && FLEXBridgePrepareRuntimeEntry(transient)) {
            FLEXHookEntry *promoted = FLEXBridgePromotableEntryCopy(transient);
            promoted.userConfigured = YES;
            [self af_host_upsertDiscoveredEntry:promoted];
        }
    }

    [self af_host_stageEnabled:enabled forEntryIdentifier:identifier];
}

- (FLEXHookEntry *)af_host_entryForIdentifier:(NSString *)identifier {
    FLEXHookEntry *entry = [self af_host_entryForIdentifier:identifier];
    if (FLEXBridgeRuntimeSurface(entry) &&
        !FLEXBridgeEntryMatchesCurrentHost(entry)) {
        return nil;
    }
    return entry;
}

- (NSArray<FLEXHookEntry *> *)af_host_entries {
    NSArray<FLEXHookEntry *> *raw = [self af_host_entries];
    NSMutableArray<FLEXHookEntry *> *filtered =
        [NSMutableArray arrayWithCapacity:raw.count];
    for (FLEXHookEntry *entry in raw) {
        if (!FLEXBridgeRuntimeSurface(entry) ||
            FLEXBridgeEntryMatchesCurrentHost(entry)) {
            [filtered addObject:entry];
        }
    }
    return filtered.copy;
}

- (NSArray<FLEXHookEntry *> *)af_host_entriesForSurface:(FLEXHookSurface)surface {
    NSMutableArray<FLEXHookEntry *> *filtered = [NSMutableArray array];
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.surface == surface) {
            [filtered addObject:entry];
        }
    }
    return filtered.copy;
}

- (void)af_host_reapplyPersistedEntries {
    // Legacy or foreign-host runtime entries may still exist in a shared
    // defaults/App Group mirror. Disable them before the registry evaluates
    // desiredEnabled; only entries stamped for this executable and live image
    // are eligible for reconstruction.
    for (FLEXHookEntry *entry in [self af_host_entries]) {
        if (FLEXBridgeRuntimeSurface(entry) &&
            !FLEXBridgeEntryMatchesCurrentHost(entry)) {
            entry.desiredEnabled = NO;
            entry.pendingEnabled = NO;
            entry.effectiveEnabled = NO;
            entry.installed = NO;
            entry.available = NO;
            entry.hookable = NO;
            entry.stale = YES;
            entry.lastError = @"Discarded because the persisted target belongs to another host image";
        }
    }
    [self af_host_reapplyPersistedEntries];
}

@end
