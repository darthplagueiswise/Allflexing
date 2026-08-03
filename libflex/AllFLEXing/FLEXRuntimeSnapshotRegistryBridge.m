#import "FLEXHookRegistry.h"
#import "FLEXRuntimeImageSession.h"

#import <objc/runtime.h>

const char *FLEXRuntimeSnapshotRegistryBridgeABIVersion =
    "AllFLEXing host/image-scoped transient runtime bridge ABI 4";

static NSMapTable<NSString *, FLEXHookEntry *> *FLEXTransientRuntimeEntries(void) {
    static NSMapTable<NSString *, FLEXHookEntry *> *entries;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        entries = [NSMapTable strongToWeakObjectsMapTable];
    });
    return entries;
}

static NSString *FLEXBridgeCanonicalPath(NSString *path) {
    if (!path.length) return @"";
    NSString *resolved = path.stringByResolvingSymlinksInPath;
    NSString *standardized = resolved.stringByStandardizingPath;
    return standardized.length ? standardized : path;
}

static NSString *FLEXBridgeCurrentHostBundleID(void) {
    return NSBundle.mainBundle.bundleIdentifier.length
        ? NSBundle.mainBundle.bundleIdentifier
        : (NSProcessInfo.processInfo.processName ?: @"host");
}

static FLEXRuntimeImageDescriptor *FLEXBridgeMainExecutable(void) {
    for (FLEXRuntimeImageDescriptor *descriptor in
         FLEXRuntimeImageSession.loadedAppImages) {
        if (descriptor.mainExecutable) return descriptor;
    }
    return FLEXRuntimeImageSession.loadedAppImages.firstObject;
}

static NSString *FLEXBridgeCurrentHostUUID(void) {
    NSString *uuid = FLEXBridgeMainExecutable().uuid;
    return uuid.length ? uuid : @"unknown-host-uuid";
}

static FLEXRuntimeImageDescriptor *FLEXBridgeLoadedImage(NSString *path) {
    NSString *canonical = FLEXBridgeCanonicalPath(path);
    if (!canonical.length) return nil;

    for (FLEXRuntimeImageDescriptor *descriptor in
         FLEXRuntimeImageSession.loadedAppImages) {
        if ([FLEXBridgeCanonicalPath(descriptor.path) isEqualToString:canonical]) {
            return descriptor;
        }
    }
    return nil;
}

static BOOL FLEXBridgeRuntimeSurface(FLEXHookEntry *entry) {
    return entry && (
        entry.surface == FLEXHookSurfaceObjectiveC ||
        entry.surface == FLEXHookSurfaceCImport ||
        entry.surface == FLEXHookSurfaceCInline
    );
}

static BOOL FLEXBridgeObjectiveCClassMatchesImage(FLEXHookEntry *entry,
                                                   NSString *imagePath) {
    if (entry.surface != FLEXHookSurfaceObjectiveC) return YES;

    NSDictionary *locator = [entry.locator isKindOfClass:NSDictionary.class]
        ? entry.locator : @{};
    NSString *className = [locator[@"class"] isKindOfClass:NSString.class]
        ? locator[@"class"] : nil;
    Class targetClass = className.length ? NSClassFromString(className) : Nil;
    const char *rawImage = targetClass ? class_getImageName(targetClass) : NULL;
    if (!rawImage) return NO;

    NSString *classImage = FLEXBridgeCanonicalPath(
        [NSString stringWithUTF8String:rawImage]
    );
    return classImage.length && [classImage isEqualToString:imagePath];
}

static BOOL FLEXBridgePrepareRuntimeEntry(FLEXHookEntry *entry) {
    if (!FLEXBridgeRuntimeSurface(entry)) return entry != nil;

    NSMutableDictionary *locator = [entry.locator mutableCopy]
        ?: [NSMutableDictionary dictionary];
    NSString *requestedPath = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : @"";
    FLEXRuntimeImageDescriptor *live = FLEXBridgeLoadedImage(requestedPath);
    if (!live) {
        entry.available = NO;
        entry.hookable = NO;
        entry.stale = YES;
        entry.lastError = @"Rejected: target image is not loaded by the current host";
        return NO;
    }

    NSString *storedUUID = [locator[@"imageUUID"] isKindOfClass:NSString.class]
        ? locator[@"imageUUID"] : @"";
    if (storedUUID.length && live.uuid.length &&
        [storedUUID caseInsensitiveCompare:live.uuid] != NSOrderedSame) {
        entry.available = NO;
        entry.hookable = NO;
        entry.stale = YES;
        entry.lastError = @"Rejected: Mach-O UUID belongs to a different image build";
        return NO;
    }

    NSString *canonicalPath = FLEXBridgeCanonicalPath(live.path);
    if (!FLEXBridgeObjectiveCClassMatchesImage(entry, canonicalPath)) {
        entry.available = NO;
        entry.hookable = NO;
        entry.stale = YES;
        entry.lastError = @"Rejected: Objective-C class belongs to another Mach-O image";
        return NO;
    }

    NSString *hostUUID = FLEXBridgeCurrentHostUUID();
    NSString *imageUUID = live.uuid.length ? live.uuid : @"unknown-image-uuid";
    locator[@"hostBundleIdentifier"] = FLEXBridgeCurrentHostBundleID();
    locator[@"hostExecutableUUID"] = hostUUID;
    locator[@"image"] = canonicalPath;
    locator[@"imageUUID"] = live.uuid ?: @"";
    locator[@"runtimeSessionImagePath"] = canonicalPath;
    locator[@"runtimeSessionImageUUID"] = live.uuid ?: @"";
    locator[@"runtimeHostIsolated"] = @YES;
    entry.locator = locator.copy;
    entry.imageName = live.displayName ?: canonicalPath.lastPathComponent;

    NSString *prefix = [NSString stringWithFormat:@"runtime|%@|%@|",
        hostUUID, imageUUID];
    NSString *base = entry.identifier.length ? entry.identifier : @"runtime-entry";
    if (![base hasPrefix:prefix]) {
        entry.identifier = [prefix stringByAppendingString:base];
    }
    return YES;
}

static BOOL FLEXBridgeEntryMatchesCurrentHost(FLEXHookEntry *entry) {
    if (!FLEXBridgeRuntimeSurface(entry)) return entry != nil;

    NSDictionary *locator = [entry.locator isKindOfClass:NSDictionary.class]
        ? entry.locator : @{};
    NSString *hostBundle = [locator[@"hostBundleIdentifier"]
        isKindOfClass:NSString.class] ? locator[@"hostBundleIdentifier"] : @"";
    NSString *hostUUID = [locator[@"hostExecutableUUID"]
        isKindOfClass:NSString.class] ? locator[@"hostExecutableUUID"] : @"";
    NSString *path = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : @"";
    NSString *imageUUID = [locator[@"imageUUID"] isKindOfClass:NSString.class]
        ? locator[@"imageUUID"] : @"";
    FLEXRuntimeImageDescriptor *live = FLEXBridgeLoadedImage(path);

    if (!live || !hostBundle.length || !hostUUID.length ||
        ![hostBundle isEqualToString:FLEXBridgeCurrentHostBundleID()] ||
        [hostUUID caseInsensitiveCompare:FLEXBridgeCurrentHostUUID()] != NSOrderedSame) {
        return NO;
    }
    if (imageUUID.length && live.uuid.length &&
        [imageUUID caseInsensitiveCompare:live.uuid] != NSOrderedSame) {
        return NO;
    }
    return FLEXBridgeObjectiveCClassMatchesImage(
        entry,
        FLEXBridgeCanonicalPath(live.path)
    );
}

static BOOL FLEXBridgeSameRuntimeIdentity(FLEXHookEntry *left,
                                          FLEXHookEntry *right) {
    if (!left || !right) return NO;
    NSDictionary *a = [left.locator isKindOfClass:NSDictionary.class]
        ? left.locator : @{};
    NSDictionary *b = [right.locator isKindOfClass:NSDictionary.class]
        ? right.locator : @{};
    NSArray<NSString *> *keys = @[
        @"hostBundleIdentifier", @"hostExecutableUUID",
        @"image", @"imageUUID", @"source", @"class", @"selector",
        @"classMethod", @"symbol", @"offset"
    ];
    for (NSString *key in keys) {
        id av = a[key];
        id bv = b[key];
        if ((av || bv) && ![av isEqual:bv]) return NO;
    }
    return YES;
}

static FLEXHookEntry *FLEXBridgePromotableEntryCopy(FLEXHookEntry *entry) {
    FLEXHookEntry *copy = entry.copy;
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
    if (!FLEXBridgeRuntimeSurface(entry)) {
        return [self af_host_upsertDiscoveredEntry:entry];
    }
    if (!FLEXBridgePrepareRuntimeEntry(entry)) return entry;

    FLEXHookEntry *existing = [self af_host_entryForIdentifier:entry.identifier];
    if (existing && FLEXBridgeSameRuntimeIdentity(existing, entry) &&
        (existing.userConfigured || entry.userConfigured)) {
        return [self af_host_upsertDiscoveredEntry:entry];
    }

    @synchronized (FLEXTransientRuntimeEntries()) {
        [FLEXTransientRuntimeEntries() setObject:entry forKey:entry.identifier];
    }

    // A scan is process-local and selected-image scoped. It cannot seed the
    // persistent registry until that exact row is configured by the user.
    if (!entry.userConfigured) return entry;
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
        if (entry.surface == surface) [filtered addObject:entry];
    }
    return filtered.copy;
}

- (void)af_host_reapplyPersistedEntries {
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
            entry.lastError = @"Discarded: persisted target belongs to another host/image";
        }
    }
    [self af_host_reapplyPersistedEntries];
}

@end
