#import "FLEXHookRegistry.h"

#import "FLEXCHookEngine.h"
#import "FLEXHookPersistence.h"
#import "FLEXHooking.h"
#import "FLEXRuntimeImageSession.h"
#import "FLEXRuntimeScanner.h"

#import <stdatomic.h>

NSNotificationName const FLEXHookRegistryDidChangeNotification =
    @"FLEXHookRegistryDidChangeNotification";

const char *FLEXRuntimeSnapshotRegistryBridgeABIVersion =
    "AllFLEXing host/image-scoped transient runtime bridge ABI 5";

static NSString *const kFLEXHookRegistryStorageKey = @"com.allflexing.registry.v1";
static NSString *const kFLEXHookRegistryInFlightKey = @"com.allflexing.registry.applyInFlight";
static NSInteger const kFLEXHookRegistrySchema = 1;

static NSMapTable<NSString *, FLEXHookEntry *> *FLEXTransientRuntimeEntries(void) {
    static NSMapTable<NSString *, FLEXHookEntry *> *entries;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        entries = [NSMapTable strongToWeakObjectsMapTable];
    });
    return entries;
}

static NSString *FLEXRegistryCanonicalPath(NSString *path) {
    if (!path.length) return @"";
    NSString *resolved = path.stringByResolvingSymlinksInPath;
    NSString *standardized = resolved.stringByStandardizingPath;
    return standardized.length ? standardized : path;
}

static NSString *FLEXRegistryCurrentHostBundleID(void) {
    return NSBundle.mainBundle.bundleIdentifier.length
        ? NSBundle.mainBundle.bundleIdentifier
        : (NSProcessInfo.processInfo.processName ?: @"host");
}

static FLEXRuntimeImageDescriptor *FLEXRegistryMainExecutable(void) {
    NSArray<FLEXRuntimeImageDescriptor *> *images =
        FLEXRuntimeImageSession.loadedAppImages;
    for (FLEXRuntimeImageDescriptor *descriptor in images) {
        if (descriptor.mainExecutable) return descriptor;
    }
    return images.firstObject;
}

static NSString *FLEXRegistryCurrentHostUUID(void) {
    NSString *uuid = FLEXRegistryMainExecutable().uuid;
    return uuid.length ? uuid : @"unknown-host-uuid";
}

static FLEXRuntimeImageDescriptor *FLEXRegistryLoadedImage(NSString *path) {
    NSString *canonical = FLEXRegistryCanonicalPath(path);
    if (!canonical.length) return nil;
    for (FLEXRuntimeImageDescriptor *descriptor in
         FLEXRuntimeImageSession.loadedAppImages) {
        if ([FLEXRegistryCanonicalPath(descriptor.path)
                isEqualToString:canonical]) {
            return descriptor;
        }
    }
    return nil;
}

static BOOL FLEXRegistryRuntimeSurface(FLEXHookEntry *entry) {
    return entry && (
        entry.surface == FLEXHookSurfaceObjectiveC ||
        entry.surface == FLEXHookSurfaceCImport ||
        entry.surface == FLEXHookSurfaceCInline
    );
}

static BOOL FLEXRegistryObjectiveCClassMatchesImage(FLEXHookEntry *entry,
                                                     NSString *imagePath) {
    if (entry.surface != FLEXHookSurfaceObjectiveC) return YES;
    NSDictionary *locator = [entry.locator isKindOfClass:NSDictionary.class]
        ? entry.locator : @{};
    NSString *className = [locator[@"class"] isKindOfClass:NSString.class]
        ? locator[@"class"] : nil;
    Class targetClass = className.length ? NSClassFromString(className) : Nil;
    const char *rawImage = targetClass ? class_getImageName(targetClass) : NULL;
    if (!rawImage) return NO;
    NSString *classImage = FLEXRegistryCanonicalPath(
        [NSString stringWithUTF8String:rawImage]
    );
    return classImage.length && [classImage isEqualToString:imagePath];
}

static BOOL FLEXRegistryPrepareRuntimeEntry(FLEXHookEntry *entry) {
    if (!FLEXRegistryRuntimeSurface(entry)) return entry != nil;

    NSMutableDictionary *locator = [entry.locator mutableCopy]
        ?: [NSMutableDictionary dictionary];
    NSString *requestedPath = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : @"";
    FLEXRuntimeImageDescriptor *live = FLEXRegistryLoadedImage(requestedPath);
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

    NSString *canonicalPath = FLEXRegistryCanonicalPath(live.path);
    if (!FLEXRegistryObjectiveCClassMatchesImage(entry, canonicalPath)) {
        entry.available = NO;
        entry.hookable = NO;
        entry.stale = YES;
        entry.lastError = @"Rejected: Objective-C class belongs to another Mach-O image";
        return NO;
    }

    NSString *hostUUID = FLEXRegistryCurrentHostUUID();
    NSString *imageUUID = live.uuid.length ? live.uuid : @"unknown-image-uuid";
    locator[@"hostBundleIdentifier"] = FLEXRegistryCurrentHostBundleID();
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

static BOOL FLEXRegistryEntryMatchesCurrentHost(FLEXHookEntry *entry) {
    if (!FLEXRegistryRuntimeSurface(entry)) return entry != nil;
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
    FLEXRuntimeImageDescriptor *live = FLEXRegistryLoadedImage(path);

    if (!live || !hostBundle.length || !hostUUID.length ||
        ![hostBundle isEqualToString:FLEXRegistryCurrentHostBundleID()] ||
        [hostUUID caseInsensitiveCompare:FLEXRegistryCurrentHostUUID()] != NSOrderedSame) {
        return NO;
    }
    if (imageUUID.length && live.uuid.length &&
        [imageUUID caseInsensitiveCompare:live.uuid] != NSOrderedSame) {
        return NO;
    }
    return FLEXRegistryObjectiveCClassMatchesImage(
        entry,
        FLEXRegistryCanonicalPath(live.path)
    );
}

static BOOL FLEXRegistrySameRuntimeIdentity(FLEXHookEntry *left,
                                            FLEXHookEntry *right) {
    if (!left || !right) return NO;
    NSDictionary *a = [left.locator isKindOfClass:NSDictionary.class]
        ? left.locator : @{};
    NSDictionary *b = [right.locator isKindOfClass:NSDictionary.class]
        ? right.locator : @{};
    NSArray<NSString *> *keys = @[
        @"hostBundleIdentifier", @"hostExecutableUUID", @"image",
        @"imageUUID", @"source", @"class", @"selector",
        @"classMethod", @"symbol", @"offset"
    ];
    for (NSString *key in keys) {
        id av = a[key];
        id bv = b[key];
        if ((av || bv) && ![av isEqual:bv]) return NO;
    }
    return YES;
}

NSString *FLEXHookSurfaceName(FLEXHookSurface surface) {
    switch (surface) {
        case FLEXHookSurfaceFeature: return @"AllFLEXing";
        case FLEXHookSurfaceObjectiveC: return @"Objective-C";
        case FLEXHookSurfaceCImport: return @"C import";
        case FLEXHookSurfaceCInline: return @"C inline";
        case FLEXHookSurfaceInspection: return @"Inspection";
    }
    return @"Unknown";
}

NSString *FLEXHookBackendName(FLEXHookBackend backend) {
    switch (backend) {
        case FLEXHookBackendNone: return @"Inspection only";
        case FLEXHookBackendAuto: return @"Auto";
        case FLEXHookBackendObjectiveCElleKit: return @"MSHookMessageEx / ElleKit";
        case FLEXHookBackendFishhook: return @"fishhook";
        case FLEXHookBackendInlineElleKit: return @"MSHookFunction / ElleKit";
        case FLEXHookBackendDobby: return @"Dobby (experimental)";
    }
    return @"Unknown";
}

NSString *FLEXHookABIName(FLEXHookABI abi) {
    switch (abi) {
        case FLEXHookABIUnknown: return @"Unknown ABI";
        case FLEXHookABIObjCBoolNoArguments: return @"BOOL(id, SEL)";
        case FLEXHookABIObjCBoolObjectArgument: return @"BOOL(id, SEL, id)";
        case FLEXHookABIObjCBoolIntegerArgument: return @"BOOL(id, SEL, integer)";
        case FLEXHookABICBoolNoArguments: return @"bool(void)";
        case FLEXHookABICBoolPointerArgument: return @"bool(void *)";
        case FLEXHookABICInt64NoArguments: return @"int64_t(void)";
        case FLEXHookABICPointerNoArguments: return @"void *(void)";
    }
    return @"Unknown ABI";
}

@implementation FLEXHookEntry {
    atomic_bool _runtimeEnabled;
    atomic_ullong _runtimeHits;
    atomic_ullong _runtimeOverrideHits;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = @"";
        _title = @"";
        _detail = @"";
        _imageName = @"";
        _locator = @{};
        _backend = FLEXHookBackendNone;
        _abi = FLEXHookABIUnknown;
        _runtimeSlot = NSNotFound;
        _forceValue = YES;
        atomic_init(&_runtimeEnabled, false);
        atomic_init(&_runtimeHits, 0);
        atomic_init(&_runtimeOverrideHits, 0);
    }
    return self;
}

- (BOOL)effectiveEnabled {
    return atomic_load_explicit(&_runtimeEnabled, memory_order_relaxed);
}

- (void)setEffectiveEnabled:(BOOL)value {
    atomic_store_explicit(&_runtimeEnabled, value, memory_order_release);
}

- (NSUInteger)hitCount {
    if (self.runtimeSlot != NSNotFound &&
        (self.surface == FLEXHookSurfaceCImport ||
         self.surface == FLEXHookSurfaceCInline)) {
        return [FLEXCHookEngine hitCountForEntry:self];
    }
    return (NSUInteger)atomic_load_explicit(&_runtimeHits, memory_order_relaxed);
}

- (NSUInteger)overrideHitCount {
    if (self.runtimeSlot != NSNotFound &&
        (self.surface == FLEXHookSurfaceCImport ||
         self.surface == FLEXHookSurfaceCInline)) {
        return [FLEXCHookEngine overrideHitCountForEntry:self];
    }
    return (NSUInteger)atomic_load_explicit(
        &_runtimeOverrideHits,
        memory_order_relaxed
    );
}

- (void)recordHit {
    atomic_fetch_add_explicit(&_runtimeHits, 1, memory_order_relaxed);
}

- (void)recordOverrideHit {
    atomic_fetch_add_explicit(&_runtimeHits, 1, memory_order_relaxed);
    unsigned long long previous = atomic_fetch_add_explicit(
        &_runtimeOverrideHits,
        1,
        memory_order_relaxed
    );
    if (previous == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:FLEXHookRegistryDidChangeNotification
                              object:self
                            userInfo:@{ @"reason": @"first-observed-call" }];
        });
    }
}

- (id)copyWithZone:(NSZone *)zone {
    FLEXHookEntry *entry = [[[self class] allocWithZone:zone] init];
    entry.identifier = self.identifier;
    entry.title = self.title;
    entry.detail = self.detail;
    entry.imageName = self.imageName;
    entry.surface = self.surface;
    entry.backend = self.backend;
    entry.abi = self.abi;
    entry.locator = self.locator;
    entry.available = self.available;
    entry.hookable = self.hookable;
    entry.userConfigured = self.userConfigured;
    entry.desiredEnabled = self.desiredEnabled;
    entry.pendingEnabled = self.pendingEnabled;
    entry.installed = self.installed;
    entry.effectiveEnabled = self.effectiveEnabled;
    entry.forceValue = self.forceValue;
    entry.requiresRestart = self.requiresRestart;
    entry.stale = self.stale;
    entry.lastError = self.lastError;
    entry.original = self.original;
    entry.replacementIMP = self.replacementIMP;
    entry.runtimeSlot = self.runtimeSlot;
    return entry;
}

- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
    return @{
        @"identifier": self.identifier ?: @"",
        @"title": self.title ?: @"",
        @"detail": self.detail ?: @"",
        @"imageName": self.imageName ?: @"",
        @"surface": @(self.surface),
        @"backend": @(self.backend),
        @"abi": @(self.abi),
        @"locator": self.locator ?: @{},
        @"desiredEnabled": @(self.desiredEnabled),
        @"forceValue": @(self.forceValue),
        @"userConfigured": @(self.userConfigured),
    };
}

+ (instancetype)entryWithDictionary:(NSDictionary<NSString *, id> *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) return nil;
    NSString *identifier = [dictionary[@"identifier"] isKindOfClass:NSString.class]
        ? dictionary[@"identifier"] : nil;
    NSDictionary *locator = [dictionary[@"locator"] isKindOfClass:NSDictionary.class]
        ? dictionary[@"locator"] : nil;
    if (!identifier.length || !locator) return nil;

    FLEXHookEntry *entry = [self new];
    entry.identifier = identifier;
    entry.title = [dictionary[@"title"] isKindOfClass:NSString.class]
        ? dictionary[@"title"] : identifier;
    entry.detail = [dictionary[@"detail"] isKindOfClass:NSString.class]
        ? dictionary[@"detail"] : @"Persisted runtime target";
    entry.imageName = [dictionary[@"imageName"] isKindOfClass:NSString.class]
        ? dictionary[@"imageName"] : @"";
    entry.surface = [dictionary[@"surface"] integerValue];
    entry.backend = [dictionary[@"backend"] integerValue];
    entry.abi = [dictionary[@"abi"] integerValue];
    entry.locator = locator;
    entry.desiredEnabled = [dictionary[@"desiredEnabled"] boolValue];
    entry.pendingEnabled = entry.desiredEnabled;
    entry.forceValue = dictionary[@"forceValue"]
        ? [dictionary[@"forceValue"] boolValue] : YES;
    entry.userConfigured = [dictionary[@"userConfigured"] boolValue];
    entry.available = NO;
    entry.hookable = NO;
    entry.stale = YES;
    entry.lastError = @"Waiting for current-host target validation";
    return entry;
}

- (NSString *)statusSummary {
    if (self.lastError.length) return self.lastError;
    if (!self.available) return @"Target unavailable in the current process";
    if (!self.hookable) {
        return self.abi == FLEXHookABIUnknown
            ? @"Choose and validate an ABI before enabling"
            : @"No compatible hook provider";
    }
    if (self.pendingEnabled != self.desiredEnabled) {
        return self.pendingEnabled ? @"Pending enable" : @"Pending disable";
    }
    if (self.installed) {
        if (!self.effectiveEnabled) {
            return [NSString stringWithFormat:
                @"Installed · forwarding original · %lu calls",
                (unsigned long)self.hitCount];
        }
        NSString *forced = self.abi == FLEXHookABICPointerNoArguments
            ? @"Force NULL"
            : (self.abi == FLEXHookABICInt64NoArguments
                ? (self.forceValue ? @"Force 1" : @"Force 0")
                : (self.forceValue ? @"Force TRUE" : @"Force FALSE"));
        if (self.overrideHitCount == 0) {
            return [NSString stringWithFormat:
                @"Armed · %@ · waiting for first call", forced];
        }
        return [NSString stringWithFormat:
            @"Observed · %@ · %lu overridden calls",
            forced,
            (unsigned long)self.overrideHitCount];
    }
    return self.desiredEnabled ? @"Enabled but not installed" : @"Ready";
}

@end

@interface FLEXHookRegistry ()
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) NSUserDefaults *defaults;
@property (nonatomic) NSMutableArray<FLEXHookEntry *> *mutableEntries;
@property (nonatomic) NSMutableDictionary<NSString *, FLEXHookEntry *> *entriesByIdentifier;
@property (nonatomic, readwrite) BOOL safeMode;
@property (nonatomic, copy, readwrite, nullable) NSString *safeModeEntryIdentifier;
@property (nonatomic, readwrite, getter=isApplying) BOOL applying;
@property (nonatomic) NSUInteger applyOperationCount;
@property (nonatomic) BOOL bootstrapped;
@end

@implementation FLEXHookRegistry

+ (instancetype)sharedRegistry {
    static FLEXHookRegistry *registry;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registry = [FLEXHookRegistry new];
    });
    return registry;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create(
            "com.allflexing.hook-registry",
            DISPATCH_QUEUE_SERIAL
        );
        _defaults = NSUserDefaults.standardUserDefaults;
        _mutableEntries = [NSMutableArray array];
        _entriesByIdentifier = [NSMutableDictionary dictionary];
        [self loadPersistedEntries];
        [self detectInterruptedApply];
    }
    return self;
}

- (NSString *)providerName { return FLEXMSHookProviderName(); }
- (NSString *)providerPath { return FLEXMSHookProviderPath(); }

- (NSArray<FLEXHookEntry *> *)entries {
    @synchronized (self) {
        NSMutableArray<FLEXHookEntry *> *filtered = [NSMutableArray array];
        for (FLEXHookEntry *entry in self.mutableEntries) {
            if (!FLEXRegistryRuntimeSurface(entry) ||
                FLEXRegistryEntryMatchesCurrentHost(entry)) {
                [filtered addObject:entry];
            }
        }
        return filtered.copy;
    }
}

- (FLEXHookEntry *)entryForIdentifier:(NSString *)identifier {
    if (!identifier.length) return nil;
    @synchronized (self) {
        FLEXHookEntry *entry = self.entriesByIdentifier[identifier];
        if (FLEXRegistryRuntimeSurface(entry) &&
            !FLEXRegistryEntryMatchesCurrentHost(entry)) {
            return nil;
        }
        return entry;
    }
}

- (NSArray<FLEXHookEntry *> *)entriesForSurface:(FLEXHookSurface)surface {
    NSMutableArray<FLEXHookEntry *> *filtered = [NSMutableArray array];
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.surface == surface) [filtered addObject:entry];
    }
    return filtered.copy;
}

- (void)bootstrap {
    @synchronized (self) {
        if (self.bootstrapped) return;
        self.bootstrapped = YES;
    }
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(runtimeImagesChanged:)
               name:FLEXRuntimeImagesDidChangeNotification
             object:nil];
    [FLEXRuntimeScanner startMonitoringImages];
    [self refreshCapabilities];
}

- (void)runtimeImagesChanged:(NSNotification *)notification {
    (void)notification;
    dispatch_async(self.queue, ^{
        [self refreshCapabilities];
    });
}

- (void)loadPersistedEntries {
    NSDictionary *payload = [self.defaults objectForKey:kFLEXHookRegistryStorageKey];
    if (![payload isKindOfClass:NSDictionary.class] ||
        [payload[@"schema"] integerValue] != kFLEXHookRegistrySchema) {
        return;
    }
    NSArray *records = [payload[@"entries"] isKindOfClass:NSArray.class]
        ? payload[@"entries"] : @[];
    for (NSDictionary *record in records) {
        FLEXHookEntry *entry = [FLEXHookEntry entryWithDictionary:record];
        if (!entry || self.entriesByIdentifier[entry.identifier]) continue;
        if (FLEXRegistryRuntimeSurface(entry) &&
            !FLEXRegistryPrepareRuntimeEntry(entry)) {
            continue;
        }
        self.entriesByIdentifier[entry.identifier] = entry;
        [self.mutableEntries addObject:entry];
    }
}

- (void)persistEntries {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    @synchronized (self) {
        for (FLEXHookEntry *entry in self.mutableEntries) {
            if ((entry.desiredEnabled || entry.userConfigured) &&
                (!FLEXRegistryRuntimeSurface(entry) ||
                 FLEXRegistryEntryMatchesCurrentHost(entry))) {
                [records addObject:entry.dictionaryRepresentation];
            }
        }
    }
    [self.defaults setObject:@{
        @"schema": @(kFLEXHookRegistrySchema),
        @"entries": records.copy,
    } forKey:kFLEXHookRegistryStorageKey];
}

- (void)detectInterruptedApply {
    NSDictionary *inFlight = [self.defaults objectForKey:kFLEXHookRegistryInFlightKey];
    NSString *identifier = [inFlight[@"identifier"] isKindOfClass:NSString.class]
        ? inFlight[@"identifier"] : nil;
    if (!identifier.length) return;

    self.safeMode = YES;
    self.safeModeEntryIdentifier = identifier;
    FLEXHookEntry *entry = self.entriesByIdentifier[identifier];
    if (entry) {
        entry.desiredEnabled = NO;
        entry.pendingEnabled = NO;
        entry.effectiveEnabled = NO;
        entry.lastError = @"Disabled by safe mode after an interrupted apply";
    }
    [self.defaults removeObjectForKey:kFLEXHookRegistryInFlightKey];
    [self persistEntries];
}

- (void)markApplyInFlight:(FLEXHookEntry *)entry {
    [self.defaults setObject:@{
        @"identifier": entry.identifier ?: @"",
        @"date": @(NSDate.date.timeIntervalSince1970),
    } forKey:kFLEXHookRegistryInFlightKey];
    [self.defaults synchronize];
}

- (void)clearApplyInFlight {
    [self.defaults removeObjectForKey:kFLEXHookRegistryInFlightKey];
    [self.defaults synchronize];
}

- (void)mergeDiscoveredEntries:(NSArray<FLEXHookEntry *> *)entries
                       surface:(FLEXHookSurface)surface {
    for (FLEXHookEntry *entry in entries) {
        if (entry.surface == surface) [self upsertDiscoveredEntry:entry];
    }
    [self postChange:@"scan"];
}

- (FLEXHookEntry *)upsertDiscoveredEntry:(FLEXHookEntry *)entry {
    if (!entry.identifier.length) return entry;
    if (FLEXRegistryRuntimeSurface(entry) &&
        !FLEXRegistryPrepareRuntimeEntry(entry)) {
        return entry;
    }

    @synchronized (self) {
        FLEXHookEntry *existing = self.entriesByIdentifier[entry.identifier];
        if (!existing && FLEXRegistryRuntimeSurface(entry) &&
            !entry.userConfigured) {
            [FLEXTransientRuntimeEntries() setObject:entry forKey:entry.identifier];
            return entry;
        }

        if (!existing) {
            self.entriesByIdentifier[entry.identifier] = entry;
            [self.mutableEntries addObject:entry];
            existing = entry;
        } else {
            if (FLEXRegistryRuntimeSurface(existing) &&
                !FLEXRegistrySameRuntimeIdentity(existing, entry)) {
                existing.available = NO;
                existing.hookable = NO;
                existing.stale = YES;
                existing.desiredEnabled = NO;
                existing.pendingEnabled = NO;
                existing.effectiveEnabled = NO;
                existing.lastError = @"Image identity changed; revalidate this target";
                return existing;
            }
            existing.title = entry.title;
            existing.detail = entry.detail;
            existing.imageName = entry.imageName;
            existing.surface = entry.surface;
            existing.locator = entry.locator;
            existing.available = entry.available;
            existing.stale = entry.stale;
            if (!existing.userConfigured || existing.abi == FLEXHookABIUnknown) {
                existing.abi = entry.abi;
            }
            if (!existing.userConfigured || existing.backend == FLEXHookBackendNone) {
                existing.backend = entry.backend;
            }
            existing.hookable = entry.hookable &&
                existing.abi != FLEXHookABIUnknown &&
                existing.backend != FLEXHookBackendNone;
            if (existing.available && existing.hookable) existing.lastError = nil;
            else if (entry.lastError.length) existing.lastError = entry.lastError;
        }

        [self.mutableEntries sortUsingComparator:^NSComparisonResult(
            FLEXHookEntry *left,
            FLEXHookEntry *right
        ) {
            if (left.surface != right.surface) {
                return left.surface < right.surface
                    ? NSOrderedAscending : NSOrderedDescending;
            }
            return [left.title localizedCaseInsensitiveCompare:right.title];
        }];

        if (existing.userConfigured || existing.desiredEnabled) {
            [self persistEntries];
        }
        [self postChange:@"context-discovery"];
        return existing;
    }
}

- (FLEXHookEntry *)promoteTransientIdentifier:(NSString *)identifier {
    FLEXHookEntry *existing = [self entryForIdentifier:identifier];
    if (existing) return existing;

    FLEXHookEntry *transient = nil;
    @synchronized (FLEXTransientRuntimeEntries()) {
        transient = [FLEXTransientRuntimeEntries() objectForKey:identifier];
    }
    if (!transient || !FLEXRegistryPrepareRuntimeEntry(transient)) return nil;
    FLEXHookEntry *promoted = transient.copy;
    promoted.userConfigured = YES;
    NSMutableDictionary *locator = [promoted.locator mutableCopy]
        ?: [NSMutableDictionary dictionary];
    locator[@"runtimeSnapshotPromoted"] = @YES;
    promoted.locator = locator.copy;
    return [self upsertDiscoveredEntry:promoted];
}

- (void)addOrUpdateManualEntry:(FLEXHookEntry *)entry {
    if (!entry.identifier.length) return;
    entry.userConfigured = YES;
    if (FLEXRegistryRuntimeSurface(entry) &&
        !FLEXRegistryPrepareRuntimeEntry(entry)) return;
    [self upsertDiscoveredEntry:entry];
    [self persistEntries];
    [self postChange:@"manual-entry"];
}

- (void)stageEnabled:(BOOL)enabled forEntryIdentifier:(NSString *)identifier {
    FLEXHookEntry *entry = [self entryForIdentifier:identifier];
    if (!entry && enabled) entry = [self promoteTransientIdentifier:identifier];
    if (!entry || (enabled && (!entry.available || !entry.hookable))) return;
    entry.pendingEnabled = enabled;
    [self postChange:@"stage"];
}

- (void)stageForceValue:(BOOL)value forEntryIdentifier:(NSString *)identifier {
    FLEXHookEntry *entry = [self entryForIdentifier:identifier];
    if (!entry) entry = [self promoteTransientIdentifier:identifier];
    if (!entry) return;
    entry.forceValue = entry.abi == FLEXHookABICPointerNoArguments ? NO : value;
    entry.userConfigured = YES;
    [self persistEntries];
    [self postChange:@"force"];
}

- (void)configureEntryIdentifier:(NSString *)identifier
                              abi:(FLEXHookABI)abi
                          backend:(FLEXHookBackend)backend {
    FLEXHookEntry *entry = [self entryForIdentifier:identifier];
    if (!entry) entry = [self promoteTransientIdentifier:identifier];
    if (!entry) return;
    entry.abi = abi;
    entry.backend = backend;
    if (abi == FLEXHookABICPointerNoArguments) entry.forceValue = NO;
    entry.userConfigured = YES;
    entry.hookable = entry.available && abi != FLEXHookABIUnknown &&
        backend != FLEXHookBackendNone && backend != FLEXHookBackendDobby;
    entry.lastError = nil;
    [self persistEntries];
    [self postChange:@"configuration"];
}

- (void)discardPendingChanges {
    for (FLEXHookEntry *entry in self.entries) {
        entry.pendingEnabled = entry.desiredEnabled;
    }
    [self postChange:@"discard"];
}

- (BOOL)hasPendingChanges {
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.pendingEnabled != entry.desiredEnabled ||
            (entry.desiredEnabled && !entry.installed)) return YES;
    }
    return NO;
}

- (NSUInteger)pendingCount {
    NSUInteger count = 0;
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.pendingEnabled != entry.desiredEnabled ||
            (entry.desiredEnabled && !entry.installed)) count++;
    }
    return count;
}

- (NSUInteger)armedCount {
    NSUInteger count = 0;
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.installed && entry.effectiveEnabled) count++;
    }
    return count;
}

- (NSUInteger)observedCount {
    NSUInteger count = 0;
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.installed && entry.effectiveEnabled && entry.overrideHitCount > 0) {
            count++;
        }
    }
    return count;
}

- (NSUInteger)activeCount { return self.armedCount; }

- (NSUInteger)failureCount {
    NSUInteger count = 0;
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.lastError.length) count++;
    }
    return count;
}

- (void)beginApplyOperation {
    @synchronized (self) {
        self.applyOperationCount++;
        self.applying = YES;
    }
    [self postChange:@"apply-start"];
}

- (void)finishApplyOperationWithReason:(NSString *)reason
                               applied:(NSArray<FLEXHookEntry *> *)applied
                                failed:(NSArray<FLEXHookEntry *> *)failed
                            completion:(FLEXHookApplyCompletion)completion {
    @synchronized (self) {
        if (self.applyOperationCount > 0) self.applyOperationCount--;
        self.applying = self.applyOperationCount > 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self postChange:reason ?: @"apply-finish"];
        if (completion) completion(applied, failed);
    });
}

- (void)applyEntries:(NSArray<FLEXHookEntry *> *)entries
                force:(BOOL)force
               reason:(NSString *)reason
           completion:(FLEXHookApplyCompletion)completion {
    [self beginApplyOperation];
    dispatch_async(self.queue, ^{
        NSMutableArray<FLEXHookEntry *> *applied = [NSMutableArray array];
        NSMutableArray<FLEXHookEntry *> *failed = [NSMutableArray array];

        for (FLEXHookEntry *entry in entries) {
            if (FLEXRegistryRuntimeSurface(entry) &&
                !FLEXRegistryEntryMatchesCurrentHost(entry)) {
                entry.lastError = @"Target belongs to another host/image";
                entry.pendingEnabled = entry.desiredEnabled;
                [failed addObject:entry];
                continue;
            }

            BOOL needsStateChange = entry.pendingEnabled != entry.desiredEnabled;
            BOOL needsInstall = entry.pendingEnabled && !entry.installed;
            if (!force && !needsStateChange && !needsInstall) continue;

            if (!entry.pendingEnabled) {
                entry.desiredEnabled = NO;
                entry.effectiveEnabled = NO;
                entry.lastError = nil;
                [FLEXCHookEngine setEnabled:NO forEntry:entry];
                [applied addObject:entry];
                continue;
            }

            if (!entry.available || !entry.hookable) {
                entry.lastError = entry.available
                    ? @"ABI or provider is not valid for this target"
                    : @"Target is unavailable in the current process";
                entry.pendingEnabled = entry.desiredEnabled;
                [failed addObject:entry];
                continue;
            }

            NSError *error = nil;
            BOOL installed = entry.installed;
            if (!installed) {
                [self markApplyInFlight:entry];
                installed = [self installEntry:entry error:&error];
                [self clearApplyInFlight];
            }
            if (!installed) {
                entry.lastError = error.localizedDescription
                    ?: @"Hook provider rejected the target";
                entry.pendingEnabled = entry.desiredEnabled;
                entry.effectiveEnabled = NO;
                [failed addObject:entry];
                continue;
            }

            entry.desiredEnabled = YES;
            entry.pendingEnabled = YES;
            entry.effectiveEnabled = YES;
            entry.lastError = nil;
            [FLEXCHookEngine setEnabled:YES forEntry:entry];
            [applied addObject:entry];
        }

        [self persistEntries];
        [self finishApplyOperationWithReason:reason
                                    applied:applied.copy
                                     failed:failed.copy
                                 completion:completion];
    });
}

- (void)applyPendingWithCompletion:(FLEXHookApplyCompletion)completion {
    [self applyEntries:self.entries
                 force:NO
                reason:@"apply-finish"
            completion:completion];
}

- (void)applyEntryIdentifier:(NSString *)identifier
                  completion:(FLEXHookApplyCompletion)completion {
    FLEXHookEntry *entry = [self entryForIdentifier:identifier];
    if (!entry) entry = [self promoteTransientIdentifier:identifier];
    if (!entry) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(@[], @[]);
        });
        return;
    }
    [self applyEntries:@[entry]
                 force:YES
                reason:@"runtime-toggle-applied"
            completion:completion];
}

- (void)failClosedEntryIdentifier:(NSString *)identifier reason:(NSString *)reason {
    FLEXHookEntry *entry = [self entryForIdentifier:identifier];
    if (!entry) return;
    entry.desiredEnabled = NO;
    entry.pendingEnabled = NO;
    entry.effectiveEnabled = NO;
    entry.lastError = reason.length
        ? reason
        : @"Installed replacement failed runtime dispatch verification";
    [FLEXCHookEngine setEnabled:NO forEntry:entry];
    [self persistEntries];
    [self postChange:@"runtime-verification-failed"];
}

- (BOOL)installEntry:(FLEXHookEntry *)entry error:(NSError **)error {
    switch (entry.surface) {
        case FLEXHookSurfaceObjectiveC:
            return [self installObjectiveCEntry:entry error:error];
        case FLEXHookSurfaceCImport:
        case FLEXHookSurfaceCInline:
            return [FLEXCHookEngine installEntry:entry error:error];
        default:
            if (error) {
                *error = [NSError errorWithDomain:@"FLEXHookRegistry"
                                              code:1
                                          userInfo:@{NSLocalizedDescriptionKey:
                                              @"This entry is inspection-only"}];
            }
            return NO;
    }
}

- (BOOL)installObjectiveCEntry:(FLEXHookEntry *)entry error:(NSError **)error {
    if (!FLEXFlag(@"engine.objc_ellekit")) {
        if (error) {
            *error = [NSError errorWithDomain:@"FLEXHookRegistry"
                                          code:5
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"Objective-C/ElleKit engine is disabled"}];
        }
        return NO;
    }
    NSString *className = [entry.locator[@"class"] isKindOfClass:NSString.class]
        ? entry.locator[@"class"] : nil;
    NSString *selectorName = [entry.locator[@"selector"] isKindOfClass:NSString.class]
        ? entry.locator[@"selector"] : nil;
    BOOL classMethod = [entry.locator[@"classMethod"] boolValue];
    NSString *savedEncoding = [entry.locator[@"encoding"] isKindOfClass:NSString.class]
        ? entry.locator[@"encoding"] : nil;
    Class targetClass = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = classMethod
        ? class_getClassMethod(targetClass, selector)
        : class_getInstanceMethod(targetClass, selector);
    NSString *currentEncoding = method
        ? [NSString stringWithUTF8String:method_getTypeEncoding(method) ?: ""]
        : nil;

    if (!targetClass || !selector || !method ||
        (savedEncoding.length && ![savedEncoding isEqualToString:currentEncoding])) {
        if (error) {
            *error = [NSError errorWithDomain:@"FLEXHookRegistry"
                                          code:2
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"Objective-C target or type encoding changed"}];
        }
        entry.available = NO;
        entry.stale = YES;
        return NO;
    }

    __weak FLEXHookEntry *weakEntry = entry;
    __block IMP original = NULL;
    IMP replacement = NULL;
    SEL capturedSelector = selector;

    switch (entry.abi) {
        case FLEXHookABIObjCBoolNoArguments: {
            replacement = imp_implementationWithBlock(^BOOL(id receiver) {
                FLEXHookEntry *strongEntry = weakEntry;
                if (strongEntry.effectiveEnabled) {
                    [strongEntry recordOverrideHit];
                    return strongEntry.forceValue;
                }
                [strongEntry recordHit];
                return original
                    ? ((BOOL (*)(id, SEL))original)(receiver, capturedSelector)
                    : NO;
            });
            break;
        }
        case FLEXHookABIObjCBoolObjectArgument: {
            replacement = imp_implementationWithBlock(^BOOL(id receiver, id argument) {
                FLEXHookEntry *strongEntry = weakEntry;
                if (strongEntry.effectiveEnabled) {
                    [strongEntry recordOverrideHit];
                    return strongEntry.forceValue;
                }
                [strongEntry recordHit];
                return original
                    ? ((BOOL (*)(id, SEL, id))original)(
                        receiver,
                        capturedSelector,
                        argument
                    )
                    : NO;
            });
            break;
        }
        case FLEXHookABIObjCBoolIntegerArgument: {
            replacement = imp_implementationWithBlock(^BOOL(
                id receiver,
                uintptr_t argument
            ) {
                FLEXHookEntry *strongEntry = weakEntry;
                if (strongEntry.effectiveEnabled) {
                    [strongEntry recordOverrideHit];
                    return strongEntry.forceValue;
                }
                [strongEntry recordHit];
                return original
                    ? ((BOOL (*)(id, SEL, uintptr_t))original)(
                        receiver,
                        capturedSelector,
                        argument
                    )
                    : NO;
            });
            break;
        }
        default:
            break;
    }

    if (!replacement) {
        if (error) {
            *error = [NSError errorWithDomain:@"FLEXHookRegistry"
                                          code:3
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"No ABI-matched Objective-C replacement"}];
        }
        return NO;
    }

    BOOL installed = classMethod
        ? FLEXHookClassMessage(targetClass, selector, replacement, &original)
        : FLEXHookMessage(targetClass, selector, replacement, &original);
    if (!installed || !original) {
        if (error) {
            *error = [NSError errorWithDomain:@"FLEXHookRegistry"
                                          code:4
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"MSHookMessageEx did not return an original IMP"}];
        }
        return NO;
    }

    entry.original = original;
    entry.replacementIMP = replacement;
    entry.installed = YES;
    entry.stale = NO;
    return YES;
}

- (void)reapplyPersistedEntries {
    dispatch_async(self.queue, ^{
        NSMutableArray<FLEXHookEntry *> *eligible = [NSMutableArray array];
        for (FLEXHookEntry *entry in self.entries) {
            if (!entry.desiredEnabled ||
                [entry.identifier isEqualToString:self.safeModeEntryIdentifier]) {
                continue;
            }
            [self refreshPersistedEntryAvailability:entry];
            if (entry.available && entry.hookable) {
                entry.pendingEnabled = YES;
                [eligible addObject:entry];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!eligible.count) {
                [self postChange:@"manual-reapply-empty"];
                return;
            }
            [self applyEntries:eligible
                         force:YES
                        reason:@"manual-reapply"
                    completion:nil];
        });
    });
}

- (void)refreshPersistedEntryAvailability:(FLEXHookEntry *)entry {
    if (FLEXRegistryRuntimeSurface(entry) &&
        !FLEXRegistryEntryMatchesCurrentHost(entry)) {
        entry.available = NO;
        entry.hookable = NO;
        entry.stale = YES;
        entry.lastError = @"Persisted target belongs to another host/image";
        return;
    }

    if (entry.surface == FLEXHookSurfaceObjectiveC) {
        NSString *className = [entry.locator[@"class"] isKindOfClass:NSString.class]
            ? entry.locator[@"class"] : nil;
        NSString *selectorName = [entry.locator[@"selector"] isKindOfClass:NSString.class]
            ? entry.locator[@"selector"] : nil;
        BOOL classMethod = [entry.locator[@"classMethod"] boolValue];
        Class targetClass = NSClassFromString(className);
        SEL selector = NSSelectorFromString(selectorName);
        Method method = classMethod
            ? class_getClassMethod(targetClass, selector)
            : class_getInstanceMethod(targetClass, selector);
        NSString *encoding = method
            ? [NSString stringWithUTF8String:method_getTypeEncoding(method) ?: ""]
            : nil;
        NSString *saved = [entry.locator[@"encoding"] isKindOfClass:NSString.class]
            ? entry.locator[@"encoding"] : nil;
        entry.available = method != NULL &&
            (!saved.length || [saved isEqualToString:encoding]);
        entry.hookable = entry.available &&
            entry.abi != FLEXHookABIUnknown &&
            FLEXMSHookMessageProviderAvailable() &&
            FLEXFlag(@"engine.objc_ellekit");
        entry.stale = !entry.available;
        if (entry.available && entry.hookable) entry.lastError = nil;
        return;
    }

    if (entry.surface == FLEXHookSurfaceCImport ||
        entry.surface == FLEXHookSurfaceCInline) {
        [FLEXCHookEngine refreshAvailabilityForEntry:entry];
    }
}

- (BOOL)engineEnabledForEntry:(FLEXHookEntry *)entry {
    FLEXHookBackend backend = entry.backend;
    if (backend == FLEXHookBackendAuto &&
        (entry.surface == FLEXHookSurfaceCImport ||
         entry.surface == FLEXHookSurfaceCInline)) {
        backend = [entry.locator[@"bindSlots"] unsignedIntegerValue] > 0
            ? FLEXHookBackendFishhook
            : FLEXHookBackendInlineElleKit;
    }
    switch (backend) {
        case FLEXHookBackendObjectiveCElleKit:
            return FLEXFlag(@"engine.objc_ellekit");
        case FLEXHookBackendFishhook:
            return FLEXFlag(@"engine.fishhook");
        case FLEXHookBackendInlineElleKit:
            return FLEXFlag(@"engine.inline_ellekit");
        default:
            return NO;
    }
}

- (void)refreshCapabilities {
    for (FLEXHookEntry *entry in self.entries) {
        [self refreshPersistedEntryAvailability:entry];
        BOOL engineEnabled = [self engineEnabledForEntry:entry];
        if (entry.installed) {
            BOOL effective = entry.desiredEnabled && engineEnabled;
            entry.effectiveEnabled = effective;
            [FLEXCHookEngine setEnabled:effective forEntry:entry];
        }
        if (!engineEnabled && !entry.installed) entry.hookable = NO;
    }
    [self postChange:@"capabilities"];
}

- (void)clearSafeMode {
    self.safeMode = NO;
    self.safeModeEntryIdentifier = nil;
    [self postChange:@"safe-mode-cleared"];
}

- (void)postChange:(NSString *)reason {
    dispatch_block_t block = ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:FLEXHookRegistryDidChangeNotification
                          object:self
                        userInfo:@{ @"reason": reason ?: @"update" }];
    };
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

@end
