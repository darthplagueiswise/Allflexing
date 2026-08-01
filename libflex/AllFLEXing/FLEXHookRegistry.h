#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FLEXHookRegistryDidChangeNotification;

typedef NS_ENUM(NSInteger, FLEXHookSurface) {
    FLEXHookSurfaceFeature = 0,
    FLEXHookSurfaceObjectiveC,
    FLEXHookSurfaceCImport,
    FLEXHookSurfaceCInline,
    FLEXHookSurfaceInspection,
};

typedef NS_ENUM(NSInteger, FLEXHookBackend) {
    FLEXHookBackendNone = 0,
    FLEXHookBackendAuto,
    FLEXHookBackendObjectiveCElleKit,
    FLEXHookBackendFishhook,
    FLEXHookBackendInlineElleKit,
    FLEXHookBackendDobby,
};

typedef NS_ENUM(NSInteger, FLEXHookABI) {
    FLEXHookABIUnknown = 0,
    FLEXHookABIObjCBoolNoArguments,
    FLEXHookABIObjCBoolObjectArgument,
    FLEXHookABIObjCBoolIntegerArgument,
    FLEXHookABICBoolNoArguments,
    FLEXHookABICBoolPointerArgument,
    FLEXHookABICInt64NoArguments,
    FLEXHookABICPointerNoArguments,
};

FOUNDATION_EXPORT NSString *FLEXHookSurfaceName(FLEXHookSurface surface);
FOUNDATION_EXPORT NSString *FLEXHookBackendName(FLEXHookBackend backend);
FOUNDATION_EXPORT NSString *FLEXHookABIName(FLEXHookABI abi);

@interface FLEXHookEntry : NSObject <NSCopying>

@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *imageName;
@property (nonatomic) FLEXHookSurface surface;
@property (nonatomic) FLEXHookBackend backend;
@property (nonatomic) FLEXHookABI abi;
@property (nonatomic, copy) NSDictionary<NSString *, id> *locator;

@property (nonatomic) BOOL available;
@property (nonatomic) BOOL hookable;
@property (nonatomic) BOOL userConfigured;
@property (nonatomic) BOOL desiredEnabled;
@property (nonatomic) BOOL pendingEnabled;
@property (nonatomic) BOOL installed;
@property (atomic) BOOL effectiveEnabled;
@property (atomic) BOOL forceValue;
@property (nonatomic) BOOL requiresRestart;
@property (nonatomic) BOOL stale;
@property (nonatomic, copy, nullable) NSString *lastError;
@property (atomic, readonly) NSUInteger hitCount;

// Runtime-only state. These values are intentionally never serialized.
@property (nonatomic) void *original;
@property (nonatomic) IMP replacementIMP;
@property (nonatomic) NSInteger runtimeSlot;

- (void)recordHit;
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;
+ (nullable instancetype)entryWithDictionary:(NSDictionary<NSString *, id> *)dictionary;
- (NSString *)statusSummary;

@end

typedef void (^FLEXHookApplyCompletion)(NSArray<FLEXHookEntry *> *applied,
                                        NSArray<FLEXHookEntry *> *failed);

@interface FLEXHookRegistry : NSObject

@property (class, nonatomic, readonly) FLEXHookRegistry *sharedRegistry;
@property (nonatomic, copy, readonly) NSArray<FLEXHookEntry *> *entries;
@property (nonatomic, readonly) BOOL safeMode;
@property (nonatomic, copy, readonly, nullable) NSString *safeModeEntryIdentifier;
@property (nonatomic, readonly, getter=isApplying) BOOL applying;
@property (nonatomic, copy, readonly) NSString *providerName;
@property (nonatomic, copy, readonly) NSString *providerPath;

- (void)bootstrap;
- (nullable FLEXHookEntry *)entryForIdentifier:(NSString *)identifier;
- (NSArray<FLEXHookEntry *> *)entriesForSurface:(FLEXHookSurface)surface;
- (void)mergeDiscoveredEntries:(NSArray<FLEXHookEntry *> *)entries
                       surface:(FLEXHookSurface)surface;
- (FLEXHookEntry *)upsertDiscoveredEntry:(FLEXHookEntry *)entry;
- (void)addOrUpdateManualEntry:(FLEXHookEntry *)entry;

- (void)stageEnabled:(BOOL)enabled forEntryIdentifier:(NSString *)identifier;
- (void)stageForceValue:(BOOL)forceValue forEntryIdentifier:(NSString *)identifier;
- (void)configureEntryIdentifier:(NSString *)identifier
                              abi:(FLEXHookABI)abi
                          backend:(FLEXHookBackend)backend;
- (void)discardPendingChanges;
- (BOOL)hasPendingChanges;
- (NSUInteger)pendingCount;
- (NSUInteger)activeCount;
- (NSUInteger)failureCount;

- (void)applyPendingWithCompletion:(nullable FLEXHookApplyCompletion)completion;
/// Applies exactly one row's staged state. Runtime-browser and contextual
/// switches use this path so a toggle changes behavior immediately without
/// accidentally committing unrelated pending edits.
- (void)applyEntryIdentifier:(NSString *)identifier
                  completion:(nullable FLEXHookApplyCompletion)completion;
- (void)reapplyPersistedEntries;
- (void)refreshCapabilities;
- (void)clearSafeMode;

@end

NS_ASSUME_NONNULL_END
