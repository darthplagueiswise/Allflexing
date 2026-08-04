#import "FLEXHookRegistry.h"

#import "FLEXCHookEngine.h"
#import "FLEXHookPersistence.h"
#import "FLEXHooking.h"
#import "FLEXPersistenceStore.h"
#import "FLEXRuntimeHostIdentity.h"
#import "FLEXRuntimeScanner.h"

#import <stdatomic.h>

NSNotificationName const FLEXHookRegistryDidChangeNotification =
    @"FLEXHookRegistryDidChangeNotification";

static NSString *const kFLEXHookRegistryLegacyStorageKey = @"com.allflexing.registry.v1";
static NSInteger const kFLEXHookRegistrySchema = 2;

static NSString *FLEXHookRegistryStorageKey(void) {
    return [@"com.allflexing.registry.v2." stringByAppendingString:FLEXCurrentHostScope()];
}

static NSString *FLEXHookRegistryInFlightKey(void) {
    return [@"com.allflexing.registry.applyInFlight.v2."
        stringByAppendingString:FLEXCurrentHostScope()];
}

static BOOL FLEXRegistryPayloadMatchesCurrentHost(NSDictionary *payload) {
    if (![payload isKindOfClass:NSDictionary.class] ||
        [payload[@"schema"] integerValue] != kFLEXHookRegistrySchema) {
        return NO;
    }
    NSString *host = [payload[@"hostBundleIdentifier"] isKindOfClass:NSString.class]
        ? payload[@"hostBundleIdentifier"] : @"";
    NSString *hostUUID = [payload[@"hostExecutableUUID"] isKindOfClass:NSString.class]
        ? payload[@"hostExecutableUUID"] : @"";
    return [host isEqualToString:FLEXCurrentHostBundleIdentifier()] &&
        hostUUID.length &&
        [hostUUID caseInsensitiveCompare:FLEXCurrentHostExecutableUUID()] == NSOrderedSame;
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

- (void)setEffectiveEnabled:(BOOL)effectiveEnabled {
    atomic_store_explicit(&_runtimeEnabled, effectiveEnabled, memory_order_release);
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
        &_runtimeOverrideHits, memory_order_relaxed
    );
}

- (void)recordHit {
    atomic_fetch_add_explicit(&_runtimeHits, 1, memory_order_relaxed);
}

- (void)recordOverrideHit {
    atomic_fetch_add_explicit(&_runtimeHits, 1, memory_order_relaxed);
    unsigned long long previous = atomic_fetch_add_explicit(
        &_runtimeOverrideHits, 1, memory_order_relaxed
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
    NSMutableDictionary<NSString *, id> *dictionary = [NSMutableDictionary dictionary];
    dictionary[@"identifier"] = self.identifier ?: @"";
    dictionary[@"title"] = self.title ?: @"";
    dictionary[@"detail"] = self.detail ?: @"";
    dictionary[@"imageName"] = self.imageName ?: @"";
    dictionary[@"surface"] = @(self.surface);
    dictionary[@"backend"] = @(self.backend);
    dictionary[@"abi"] = @(self.abi);
    dictionary[@"locator"] = self.locator ?: @{};
    dictionary[@"desiredEnabled"] = @(self.desiredEnabled);
    dictionary[@"forceValue"] = @(self.forceValue);
    dictionary[@"userConfigured"] = @(self.userConfigured);
    return dictionary.copy;
}

+ (instancetype)entryWithDictionary:(NSDictionary<NSString *, id> *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    NSString *identifier = [dictionary[@"identifier"] isKindOfClass:NSString.class]
        ? dictionary[@"identifier"] : nil;
    NSDictionary *locator = [dictionary[@"locator"] isKindOfClass:NSDictionary.class]
        ? dictionary[@"locator"] : nil;
    if (identifier.length == 0 || !locator) {
        return nil;
    }

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
    entry.hookable = entry.abi != FLEXHookABIUnknown &&
                     entry.backend != FLEXHookBackendNone;
    entry.stale = YES;
    entry.lastError = @"Waiting for runtime target validation";
    return entry;
}

- (NSString *)statusSummary {
    if (self.lastError.length) {
        return self.lastError;
    }
    if (!self.available) {
        return @"Target unavailable in the current process";
    }
    if (!self.hookable) {
        return self.abi == FLEXHookABIUnknown
            ? @"Choose and validate an ABI before enabling"
            : @"No compatible hook provider";
    }
    if (self.pendingEnabled != self.desiredEnabled) {
        return self.pendingEnabled ? @"Pending enable" : @"Pending disable";
    }
    if (self.installed) {
        NSUInteger calls = self.hitCount;
        if (!self.effectiveEnabled) {
            return [NSString stringWithFormat:@"Installed · forwarding original · %lu calls",
                (unsigned long)calls];
        }
        NSString *forced = nil;
        if (self.abi == FLEXHookABICPointerNoArguments) {
            forced = @"Force NULL";
        } else if (self.abi == FLEXHookABICInt64NoArguments) {
            forced = self.forceValue ? @"Force 1" : @"Force 0";
        } else {
            forced = self.forceValue ? @"Force TRUE" : @"Force FALSE";
        }
        NSUInteger overrides = self.overrideHitCount;
        if (overrides == 0) {
            return [NSString stringWithFormat:@"Armed · %@ · waiting for first call", forced];
        }
        return [NSString stringWithFormat:@"Observed · %@ · %lu overridden calls",
            forced, (unsigned long)overrides];
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

+ (BOOL)hasPersistedConfirmedEntries {
    NSDictionary *payload = [NSUserDefaults.standardUserDefaults
        objectForKey:FLEXHookRegistryStorageKey()];
    if (!FLEXRegistryPayloadMatchesCurrentHost(payload)) return NO;
    NSArray *records = [payload[@"entries"] isKindOfClass:NSArray.class]
        ? payload[@"entries"] : @[];
    for (NSDictionary *record in records) {
        NSDictionary *locator = [record[@"locator"] isKindOfClass:NSDictionary.class]
            ? record[@"locator"] : nil;
        if ([record[@"desiredEnabled"] boolValue] &&
            FLEXLocatorMatchesCurrentHost(locator)) {
            return YES;
        }
    }
    return NO;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.allflexing.hook-registry", DISPATCH_QUEUE_SERIAL);
        _defaults = NSUserDefaults.standardUserDefaults;
        _mutableEntries = [NSMutableArray array];
        _entriesByIdentifier = [NSMutableDictionary dictionary];
        [_defaults removeObjectForKey:kFLEXHookRegistryLegacyStorageKey];
        [self loadPersistedEntries];
        [self detectInterruptedApply];
    }
    return self;
}

- (NSString *)providerName {
    return FLEXMSHookProviderName();
}

- (NSString *)providerPath {
    return FLEXMSHookProviderPath();
}

- (NSArray<FLEXHookEntry *> *)entries {
    @synchronized (self) {
        return [self.mutableEntries copy];
    }
}

- (FLEXHookEntry *)entryForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return nil;
    }
    @synchronized (self) {
        return self.entriesByIdentifier[identifier];
    }
}

- (NSArray<FLEXHookEntry *> *)entriesForSurface:(FLEXHookSurface)surface {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(FLEXHookEntry *entry,
                                                                    NSDictionary *bindings) {
        (void)bindings;
        return entry.surface == surface;
    }];
    return [self.entries filteredArrayUsingPredicate:predicate];
}

- (void)bootstrap {
    @synchronized (self) {
        if (self.bootstrapped) {
            return;
        }
        self.bootstrapped = YES;
    }
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(runtimeImagesChanged:)
               name:FLEXRuntimeImagesDidChangeNotification
             object:nil];
    dispatch_sync(self.queue, ^{
        [self reapplyPersistedEntriesWithReason:@"launch-reapply"];
    });
    [FLEXRuntimeScanner startMonitoringImages];
}

- (void)runtimeImagesChanged:(NSNotification *)notification {
    (void)notification;
    dispatch_async(self.queue, ^{
        [self reapplyPersistedEntriesWithReason:@"late-image-reapply"];
    });
}

- (void)reapplyPersistedEntries {
    dispatch_async(self.queue, ^{
        [self reapplyPersistedEntriesWithReason:@"manual-reapply"];
    });
}

- (void)loadPersistedEntries {
    NSDictionary *payload = [self.defaults objectForKey:FLEXHookRegistryStorageKey()];
    if (!FLEXRegistryPayloadMatchesCurrentHost(payload)) {
        [self.defaults removeObjectForKey:FLEXHookRegistryStorageKey()];
        return;
    }

    NSArray *records = [payload[@"entries"] isKindOfClass:NSArray.class]
        ? payload[@"entries"] : @[];
    for (NSDictionary *record in records) {
        if (![record[@"desiredEnabled"] boolValue]) continue;
        FLEXHookEntry *entry = [FLEXHookEntry entryWithDictionary:record];
        if (!entry || self.entriesByIdentifier[entry.identifier] ||
            !FLEXLocatorMatchesCurrentHost(entry.locator)) {
            continue;
        }
        entry.userConfigured = YES;
        self.entriesByIdentifier[entry.identifier] = entry;
        [self.mutableEntries addObject:entry];
    }
}

- (void)persistEntries {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    @synchronized (self) {
        for (FLEXHookEntry *entry in self.mutableEntries) {
            // Runtime discovery is transient. Only an entry confirmed by Apply
            // may survive a process restart or be re-armed at launch.
            if (!entry.desiredEnabled ||
                !FLEXLocatorMatchesCurrentHost(entry.locator)) {
                continue;
            }
            [records addObject:entry.dictionaryRepresentation];
        }
    }
    NSDictionary *payload = @{
        @"schema": @(kFLEXHookRegistrySchema),
        @"hostBundleIdentifier": FLEXCurrentHostBundleIdentifier(),
        @"hostExecutableUUID": FLEXCurrentHostExecutableUUID(),
        @"entries": records.copy,
    };
    [self.defaults setObject:payload forKey:FLEXHookRegistryStorageKey()];
    [self.defaults removeObjectForKey:kFLEXHookRegistryLegacyStorageKey];
    [FLEXPersistenceStore.sharedStore synchronizeSoon];
}

- (void)detectInterruptedApply {
    NSDictionary *inFlight = [self.defaults objectForKey:FLEXHookRegistryInFlightKey()];
    NSString *identifier = [inFlight[@"identifier"] isKindOfClass:NSString.class]
        ? inFlight[@"identifier"] : nil;
    if (identifier.length == 0) {
        return;
    }

    self.safeMode = YES;
    self.safeModeEntryIdentifier = identifier;
    FLEXHookEntry *entry = self.entriesByIdentifier[identifier];
    if (entry) {
        entry.desiredEnabled = NO;
        entry.pendingEnabled = NO;
        entry.effectiveEnabled = NO;
        entry.lastError = @"Disabled by safe mode after an interrupted apply";
    }
    [self.defaults removeObjectForKey:FLEXHookRegistryInFlightKey()];
    [self persistEntries];
}

- (void)markApplyInFlight:(FLEXHookEntry *)entry {
    [self.defaults setObject:@{
        @"identifier": entry.identifier ?: @"",
        @"date": @([NSDate.date timeIntervalSince1970]),
    } forKey:FLEXHookRegistryInFlightKey()];
    [self.defaults synchronize];
}

- (void)clearApplyInFlight {
    [self.defaults removeObjectForKey:FLEXHookRegistryInFlightKey()];
    [self.defaults synchronize];
}

- (void)mergeDiscoveredEntries:(NSArray<FLEXHookEntry *> *)entries
                       surface:(FLEXHookSurface)surface {
    @synchronized (self) {
        for (FLEXHookEntry *existing in self.mutableEntries) {
            if (existing.surface == surface && !existing.userConfigured) {
                existing.available = NO;
                existing.stale = YES;
                if (!existing.lastError.length) {
                    existing.lastError = @"Not found in the latest runtime scan";
                }
            }
        }

        for (FLEXHookEntry *discovered in entries) {
            discovered.locator = FLEXLocatorByAddingCurrentHostIdentity(discovered.locator);
            if (discovered.identifier.length == 0 ||
                !FLEXRuntimeImageIsAllowedHostImage(discovered.locator[@"image"])) {
                continue;
            }
            FLEXHookEntry *existing = self.entriesByIdentifier[discovered.identifier];
            if (!existing) {
                self.entriesByIdentifier[discovered.identifier] = discovered;
                [self.mutableEntries addObject:discovered];
                continue;
            }

            NSString *previousUUID = [existing.locator[@"imageUUID"]
                isKindOfClass:NSString.class] ? existing.locator[@"imageUUID"] : nil;
            NSString *discoveredUUID = [discovered.locator[@"imageUUID"]
                isKindOfClass:NSString.class] ? discovered.locator[@"imageUUID"] : nil;
            BOOL imageIdentityChanged = existing.userConfigured &&
                previousUUID.length && discoveredUUID.length &&
                [previousUUID caseInsensitiveCompare:discoveredUUID] != NSOrderedSame;

            existing.title = discovered.title;
            existing.detail = discovered.detail;
            existing.imageName = discovered.imageName;
            existing.surface = discovered.surface;
            existing.locator = discovered.locator;

            if (imageIdentityChanged) {
                existing.abi = FLEXHookABIUnknown;
                existing.backend = FLEXHookBackendNone;
                existing.desiredEnabled = NO;
                existing.pendingEnabled = NO;
                existing.effectiveEnabled = NO;
                existing.available = YES;
                existing.hookable = NO;
                existing.stale = YES;
                existing.lastError = @"Image UUID changed; revalidate the ABI before enabling";
                [FLEXCHookEngine setEnabled:NO forEntry:existing];
                continue;
            }

            existing.available = discovered.available;
            existing.stale = discovered.stale;
            if (!existing.userConfigured || existing.abi == FLEXHookABIUnknown) {
                existing.abi = discovered.abi;
            }
            if (!existing.userConfigured || existing.backend == FLEXHookBackendNone) {
                existing.backend = discovered.backend;
            }
            existing.hookable = existing.abi != FLEXHookABIUnknown &&
                                existing.backend != FLEXHookBackendNone &&
                                discovered.available;
            existing.lastError = existing.hookable ? nil : discovered.lastError;
        }

        [self.mutableEntries sortUsingComparator:^NSComparisonResult(FLEXHookEntry *left,
                                                                      FLEXHookEntry *right) {
            if (left.surface != right.surface) {
                return left.surface < right.surface ? NSOrderedAscending : NSOrderedDescending;
            }
            return [left.title localizedCaseInsensitiveCompare:right.title];
        }];
    }
    [self persistEntries];
    [self postChange:@"scan"];
}

- (FLEXHookEntry *)upsertDiscoveredEntry:(FLEXHookEntry *)entry {
    entry.locator = FLEXLocatorByAddingCurrentHostIdentity(entry.locator);
    if (entry.identifier.length == 0 ||
        !FLEXRuntimeImageIsAllowedHostImage(entry.locator[@"image"])) {
        return entry;
    }

    __block FLEXHookEntry *resolved = entry;
    __block BOOL changed = NO;
    __block BOOL shouldPersist = NO;
    @synchronized (self) {
        FLEXHookEntry *existing = self.entriesByIdentifier[entry.identifier];
        if (!existing) {
            self.entriesByIdentifier[entry.identifier] = entry;
            [self.mutableEntries addObject:entry];
            changed = YES;
        } else {
            NSString *resolvedError = existing.lastError;
            if (!entry.available || !entry.hookable) {
                resolvedError = entry.lastError;
            } else if (!existing.available || !existing.hookable) {
                // A provider/engine that was unavailable has recovered. Clear
                // only that discovery error; do not erase an apply failure just
                // because its row was rendered again.
                resolvedError = nil;
            }
            changed = ![existing.title isEqualToString:entry.title] ||
                ![existing.detail isEqualToString:entry.detail] ||
                ![existing.imageName isEqualToString:entry.imageName] ||
                ![existing.locator isEqualToDictionary:entry.locator] ||
                existing.surface != entry.surface ||
                existing.backend != entry.backend ||
                existing.abi != entry.abi ||
                existing.available != entry.available ||
                existing.hookable != entry.hookable ||
                existing.stale != entry.stale ||
                !((existing.lastError == resolvedError) ||
                  [existing.lastError isEqualToString:resolvedError]);

            existing.title = entry.title;
            existing.detail = entry.detail;
            existing.imageName = entry.imageName;
            existing.surface = entry.surface;
            existing.backend = entry.backend;
            existing.abi = entry.abi;
            existing.locator = entry.locator;
            existing.available = entry.available;
            existing.hookable = entry.hookable;
            existing.stale = entry.stale;
            existing.lastError = resolvedError;
            resolved = existing;
            shouldPersist = changed &&
                (existing.desiredEnabled || existing.userConfigured);
        }

        if (changed) {
            [self.mutableEntries sortUsingComparator:^NSComparisonResult(
                FLEXHookEntry *left, FLEXHookEntry *right) {
                if (left.surface != right.surface) {
                    return left.surface < right.surface
                        ? NSOrderedAscending : NSOrderedDescending;
                }
                return [left.title localizedCaseInsensitiveCompare:right.title];
            }];
        }
    }

    if (shouldPersist) {
        [self persistEntries];
    }
    if (changed) {
        [self postChange:@"context-discovery"];
    }
    return resolved;
}

- (void)addOrUpdateManualEntry:(FLEXHookEntry *)entry {
    entry.locator = FLEXLocatorByAddingCurrentHostIdentity(entry.locator);
    if (entry.identifier.length == 0) {
        return;
    }
    entry.userConfigured = YES;
    @synchronized (self) {
        FLEXHookEntry *existing = self.entriesByIdentifier[entry.identifier];
        if (existing) {
            existing.title = entry.title;
            existing.detail = entry.detail;
            existing.imageName = entry.imageName;
            existing.surface = entry.surface;
            existing.locator = entry.locator;
            existing.abi = entry.abi;
            existing.backend = entry.backend;
            existing.available = entry.available;
            existing.hookable = entry.hookable;
            existing.userConfigured = YES;
            existing.lastError = entry.lastError;
        } else {
            self.entriesByIdentifier[entry.identifier] = entry;
            [self.mutableEntries addObject:entry];
        }
    }
    [self persistEntries];
    [self postChange:@"manual-entry"];
}

- (void)stageEnabled:(BOOL)enabled forEntryIdentifier:(NSString *)identifier {
    FLEXHookEntry *entry = [self entryForIdentifier:identifier];
    if (!entry || (enabled && (!entry.available || !entry.hookable))) {
        return;
    }
    entry.pendingEnabled = enabled;
    [self postChange:@"stage"];
}

- (void)stageForceValue:(BOOL)forceValue forEntryIdentifier:(NSString *)identifier {
    FLEXHookEntry *entry = [self entryForIdentifier:identifier];
    if (!entry) {
        return;
    }
    // A fabricated non-null pointer cannot be ABI-safe without owning valid
    // storage. Pointer-return hooks therefore expose only the safe NULL value.
    entry.forceValue = entry.abi == FLEXHookABICPointerNoArguments
        ? NO : forceValue;
    entry.userConfigured = YES;
    if (entry.installed) {
        [FLEXCHookEngine setEnabled:entry.effectiveEnabled forEntry:entry];
    }
    [self persistEntries];
    [self postChange:@"force"];
}

- (void)configureEntryIdentifier:(NSString *)identifier
                              abi:(FLEXHookABI)abi
                          backend:(FLEXHookBackend)backend {
    FLEXHookEntry *entry = [self entryForIdentifier:identifier];
    if (!entry) {
        return;
    }
    entry.abi = abi;
    entry.backend = backend;
    if (abi == FLEXHookABICPointerNoArguments) {
        entry.forceValue = NO;
    }
    entry.userConfigured = YES;
    entry.hookable = entry.available && abi != FLEXHookABIUnknown &&
                     backend != FLEXHookBackendNone &&
                     backend != FLEXHookBackendDobby;
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
            (entry.desiredEnabled && !entry.installed)) {
            return YES;
        }
    }
    return NO;
}

- (NSUInteger)pendingCount {
    NSUInteger count = 0;
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.pendingEnabled != entry.desiredEnabled ||
            (entry.desiredEnabled && !entry.installed)) {
            count++;
        }
    }
    return count;
}

- (NSUInteger)armedCount {
    NSUInteger count = 0;
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.installed && entry.effectiveEnabled) {
            count++;
        }
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

- (NSUInteger)activeCount {
    return self.armedCount;
}

- (NSUInteger)failureCount {
    NSUInteger count = 0;
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.lastError.length) {
            count++;
        }
    }
    return count;
}

- (void)beginApplyOperation {
    @synchronized (self) {
        self.applyOperationCount += 1;
        self.applying = YES;
    }
    [self postChange:@"apply-start"];
}

- (void)finishApplyOperationWithReason:(NSString *)reason
                               applied:(NSArray<FLEXHookEntry *> *)applied
                                failed:(NSArray<FLEXHookEntry *> *)failed
                            completion:(FLEXHookApplyCompletion)completion {
    @synchronized (self) {
        if (self.applyOperationCount > 0) {
            self.applyOperationCount -= 1;
        }
        self.applying = self.applyOperationCount > 0;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self postChange:reason ?: @"apply-finish"];
        if (completion) {
            completion(applied, failed);
        }
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
            BOOL needsStateChange = entry.pendingEnabled != entry.desiredEnabled;
            BOOL needsInstall = entry.pendingEnabled && !entry.installed;
            if (!force && !needsStateChange && !needsInstall) {
                continue;
            }

            if (!entry.pendingEnabled) {
                entry.desiredEnabled = NO;
                entry.effectiveEnabled = NO;
                entry.lastError = nil;
                [FLEXCHookEngine setEnabled:NO forEntry:entry];
                [applied addObject:entry];
                continue;
            }

            if (!FLEXLocatorMatchesCurrentHost(entry.locator)) {
                entry.lastError = @"Target belongs to another host or image build";
                entry.pendingEnabled = entry.desiredEnabled;
                entry.available = NO;
                entry.hookable = NO;
                [failed addObject:entry];
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
                entry.lastError = error.localizedDescription ?: @"Hook provider rejected the target";
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
        [FLEXPersistenceStore.sharedStore synchronizeNow];
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
    if (!entry) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(@[], @[]);
            });
        }
        return;
    }
    [self applyEntries:@[entry]
                 force:YES
                reason:@"runtime-toggle-applied"
            completion:completion];
}

- (void)failClosedEntryIdentifier:(NSString *)identifier reason:(NSString *)reason {
    FLEXHookEntry *entry = [self entryForIdentifier:identifier];
    if (!entry) {
        return;
    }
    entry.desiredEnabled = NO;
    entry.pendingEnabled = NO;
    entry.effectiveEnabled = NO;
    entry.lastError = reason.length
        ? reason : @"Installed replacement failed runtime dispatch verification";
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
        ? [NSString stringWithUTF8String:method_getTypeEncoding(method) ?: ""] : nil;

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
                    ? ((BOOL (*)(id, SEL))original)(receiver, capturedSelector) : NO;
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
                    ? ((BOOL (*)(id, SEL, id))original)(receiver, capturedSelector, argument) : NO;
            });
            break;
        }
        case FLEXHookABIObjCBoolIntegerArgument: {
            replacement = imp_implementationWithBlock(^BOOL(id receiver, uintptr_t argument) {
                FLEXHookEntry *strongEntry = weakEntry;
                if (strongEntry.effectiveEnabled) {
                    [strongEntry recordOverrideHit];
                    return strongEntry.forceValue;
                }
                [strongEntry recordHit];
                return original
                    ? ((BOOL (*)(id, SEL, uintptr_t))original)(receiver, capturedSelector, argument) : NO;
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

- (void)reapplyPersistedEntriesWithReason:(NSString *)reason {
    for (FLEXHookEntry *entry in self.entries) {
        if (!entry.desiredEnabled ||
            !FLEXLocatorMatchesCurrentHost(entry.locator) ||
            [entry.identifier isEqualToString:self.safeModeEntryIdentifier]) {
            continue;
        }

        // Image notifications can arrive in bursts. Never install a second
        // replacement for an entry that already owns a validated trampoline.
        if (entry.installed) {
            entry.pendingEnabled = YES;
            entry.effectiveEnabled = [self engineEnabledForEntry:entry];
            [FLEXCHookEngine setEnabled:entry.effectiveEnabled forEntry:entry];
            continue;
        }

        [self refreshPersistedEntryAvailability:entry];
        if (!entry.available || !entry.hookable) {
            continue;
        }

        [self markApplyInFlight:entry];
        NSError *error = nil;
        BOOL installed = [self installEntry:entry error:&error];
        [self clearApplyInFlight];
        if (installed) {
            entry.pendingEnabled = YES;
            entry.effectiveEnabled = YES;
            [FLEXCHookEngine setEnabled:YES forEntry:entry];
            entry.lastError = nil;
        } else {
            entry.effectiveEnabled = NO;
            entry.lastError = error.localizedDescription ?: @"Launch reapply failed";
        }
    }
    [self persistEntries];
    [self postChange:reason ?: @"runtime-reapply"];
}

- (void)refreshPersistedEntryAvailability:(FLEXHookEntry *)entry {
    if (!FLEXLocatorMatchesCurrentHost(entry.locator)) {
        entry.available = NO;
        entry.hookable = NO;
        entry.stale = YES;
        entry.lastError = @"Target belongs to another host or image build";
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
            ? [NSString stringWithUTF8String:method_getTypeEncoding(method) ?: ""] : nil;
        NSString *saved = [entry.locator[@"encoding"] isKindOfClass:NSString.class]
            ? entry.locator[@"encoding"] : nil;
        entry.available = method != NULL && (!saved.length || [saved isEqualToString:encoding]);
        entry.hookable = entry.available && entry.abi != FLEXHookABIUnknown &&
                         FLEXMSHookMessageProviderAvailable() &&
                         FLEXFlag(@"engine.objc_ellekit");
        entry.stale = !entry.available;
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
            ? FLEXHookBackendFishhook : FLEXHookBackendInlineElleKit;
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
        if (!engineEnabled && !entry.installed) {
            entry.hookable = NO;
        }
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
    if (NSThread.isMainThread) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

@end
