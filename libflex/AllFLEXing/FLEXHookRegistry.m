#import "FLEXHookRegistry.h"

#import "FLEXCHookEngine.h"
#import "FLEXHookPersistence.h"
#import "FLEXHooking.h"

#import <stdatomic.h>

NSNotificationName const FLEXHookRegistryDidChangeNotification =
    @"FLEXHookRegistryDidChangeNotification";

static NSString *const kFLEXHookRegistryStorageKey = @"com.allflexing.registry.v1";
static NSString *const kFLEXHookRegistryInFlightKey = @"com.allflexing.registry.applyInFlight";
static NSInteger const kFLEXHookRegistrySchema = 1;

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

- (void)recordHit {
    atomic_fetch_add_explicit(&_runtimeHits, 1, memory_order_relaxed);
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
        return [NSString stringWithFormat:@"%@ · %@ · %lu hits",
            self.effectiveEnabled ? @"Active" : @"Installed, forwarding original",
            FLEXHookBackendName(self.backend),
            (unsigned long)self.hitCount];
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
        _queue = dispatch_queue_create("com.allflexing.hook-registry", DISPATCH_QUEUE_SERIAL);
        _defaults = NSUserDefaults.standardUserDefaults;
        _mutableEntries = [NSMutableArray array];
        _entriesByIdentifier = [NSMutableDictionary dictionary];
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
    [self reapplyPersistedEntries];
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
        if (!entry || self.entriesByIdentifier[entry.identifier]) {
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
            if (entry.desiredEnabled || entry.userConfigured) {
                [records addObject:entry.dictionaryRepresentation];
            }
        }
    }
    NSDictionary *payload = @{
        @"schema": @(kFLEXHookRegistrySchema),
        @"entries": records.copy,
    };
    [self.defaults setObject:payload forKey:kFLEXHookRegistryStorageKey];
}

- (void)detectInterruptedApply {
    NSDictionary *inFlight = [self.defaults objectForKey:kFLEXHookRegistryInFlightKey];
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
    [self.defaults removeObjectForKey:kFLEXHookRegistryInFlightKey];
    [self persistEntries];
}

- (void)markApplyInFlight:(FLEXHookEntry *)entry {
    [self.defaults setObject:@{
        @"identifier": entry.identifier ?: @"",
        @"date": @([NSDate.date timeIntervalSince1970]),
    } forKey:kFLEXHookRegistryInFlightKey];
    [self.defaults synchronize];
}

- (void)clearApplyInFlight {
    [self.defaults removeObjectForKey:kFLEXHookRegistryInFlightKey];
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
            if (discovered.identifier.length == 0) {
                continue;
            }
            FLEXHookEntry *existing = self.entriesByIdentifier[discovered.identifier];
            if (!existing) {
                self.entriesByIdentifier[discovered.identifier] = discovered;
                [self.mutableEntries addObject:discovered];
                continue;
            }

            existing.title = discovered.title;
            existing.detail = discovered.detail;
            existing.imageName = discovered.imageName;
            existing.surface = discovered.surface;
            existing.locator = discovered.locator;
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

- (void)addOrUpdateManualEntry:(FLEXHookEntry *)entry {
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
    entry.forceValue = forceValue;
    entry.userConfigured = YES;
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

- (NSUInteger)activeCount {
    NSUInteger count = 0;
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.installed && entry.effectiveEnabled) {
            count++;
        }
    }
    return count;
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

- (void)applyPendingWithCompletion:(FLEXHookApplyCompletion)completion {
    @synchronized (self) {
        if (self.applying) {
            if (completion) {
                completion(@[], @[]);
            }
            return;
        }
        self.applying = YES;
    }
    [self postChange:@"apply-start"];

    dispatch_async(self.queue, ^{
        NSMutableArray<FLEXHookEntry *> *applied = [NSMutableArray array];
        NSMutableArray<FLEXHookEntry *> *failed = [NSMutableArray array];

        for (FLEXHookEntry *entry in self.entries) {
            BOOL needsStateChange = entry.pendingEnabled != entry.desiredEnabled;
            BOOL needsInstall = entry.pendingEnabled && !entry.installed;
            if (!needsStateChange && !needsInstall) {
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

            if (!entry.available || !entry.hookable) {
                entry.lastError = entry.available
                    ? @"ABI or provider is not valid for this target"
                    : @"Target is unavailable in the current process";
                entry.pendingEnabled = entry.desiredEnabled;
                [failed addObject:entry];
                continue;
            }

            [self markApplyInFlight:entry];
            NSError *error = nil;
            BOOL installed = entry.installed || [self installEntry:entry error:&error];
            [self clearApplyInFlight];
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
        @synchronized (self) {
            self.applying = NO;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self postChange:@"apply-finish"];
            if (completion) {
                completion(applied.copy, failed.copy);
            }
        });
    });
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
                BOOL native = original
                    ? ((BOOL (*)(id, SEL))original)(receiver, capturedSelector) : NO;
                [strongEntry recordHit];
                return strongEntry.effectiveEnabled ? strongEntry.forceValue : native;
            });
            break;
        }
        case FLEXHookABIObjCBoolObjectArgument: {
            replacement = imp_implementationWithBlock(^BOOL(id receiver, id argument) {
                FLEXHookEntry *strongEntry = weakEntry;
                BOOL native = original
                    ? ((BOOL (*)(id, SEL, id))original)(receiver, capturedSelector, argument) : NO;
                [strongEntry recordHit];
                return strongEntry.effectiveEnabled ? strongEntry.forceValue : native;
            });
            break;
        }
        case FLEXHookABIObjCBoolIntegerArgument: {
            replacement = imp_implementationWithBlock(^BOOL(id receiver, uintptr_t argument) {
                FLEXHookEntry *strongEntry = weakEntry;
                BOOL native = original
                    ? ((BOOL (*)(id, SEL, uintptr_t))original)(receiver, capturedSelector, argument) : NO;
                [strongEntry recordHit];
                return strongEntry.effectiveEnabled ? strongEntry.forceValue : native;
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
    for (FLEXHookEntry *entry in self.entries) {
        if (!entry.desiredEnabled ||
            [entry.identifier isEqualToString:self.safeModeEntryIdentifier]) {
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
    [self postChange:@"launch-reapply"];
}

- (void)refreshPersistedEntryAvailability:(FLEXHookEntry *)entry {
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
                         FLEXMSHookProviderAvailable() &&
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
