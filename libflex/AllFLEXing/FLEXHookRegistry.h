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
    // Secondary scope: non-bool returns. All GP returns (bool, int, pointer)
    // leave in x0; double/float leave in d0/s0. The typed replacement stubs
    // return the matching C type so the compiler emits the correct AAPCS64
    // return-register move (fmov for the FP profiles) - no machine code is
    // hand-patched into the target.
    FLEXHookABICDoubleNoArguments,
    FLEXHookABICFloatNoArguments,
};

FOUNDATION_EXPORT NSString *FLEXHookSurfaceName(FLEXHookSurface surface);
FOUNDATION_EXPORT NSString *FLEXHookBackendName(FLEXHookBackend backend);
FOUNDATION_EXPORT NSString *FLEXHookABIName(FLEXHookABI abi);
@class FLEXHookEntry;
/// Human description of the value a hook forces, per ABI profile.
FOUNDATION_EXPORT NSString *FLEXHookForcedValueDescription(FLEXHookEntry *entry);
/// YES when the profile needs the typed value editor instead of a bool switch.
FOUNDATION_EXPORT BOOL FLEXHookABIUsesTypedForceValue(FLEXHookABI abi);
/// Round-trippable editor text for the typed force value.
FOUNDATION_EXPORT NSString *FLEXHookForcedValueEditableText(FLEXHookEntry *entry);
/// Parses editor text into the exact bit pattern; NO on malformed/out-of-range.
FOUNDATION_EXPORT BOOL FLEXHookParseForcedValue(NSString *text,
                                                FLEXHookABI abi,
                                                uint64_t *outBits);

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
// Secondary-scope typed force value. Holds the raw bit pattern the hook returns
// for non-bool profiles: a signed/unsigned integer, a pointer, or the IEEE-754
// bits of a double/float. forceValue stays the source of truth for the bool
// profiles; the registry keeps the two consistent.
@property (atomic) uint64_t forceRawValue;
@property (nonatomic) BOOL requiresRestart;
@property (nonatomic) BOOL stale;
@property (nonatomic, copy, nullable) NSString *lastError;
@property (atomic, readonly) NSUInteger hitCount;
@property (atomic, readonly) NSUInteger overrideHitCount;

// Runtime-only state. These values are intentionally never serialized.
@property (nonatomic) void *original;
@property (nonatomic) IMP replacementIMP;
@property (nonatomic) NSInteger runtimeSlot;

- (void)recordHit;
- (void)recordOverrideHit;
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;
+ (nullable instancetype)entryWithDictionary:(NSDictionary<NSString *, id> *)dictionary;
- (NSString *)statusSummary;

@end

typedef void (^FLEXHookApplyCompletion)(NSArray<FLEXHookEntry *> *applied,
                                        NSArray<FLEXHookEntry *> *failed);

@interface FLEXHookRegistry : NSObject

@property (class, nonatomic, readonly) FLEXHookRegistry *sharedRegistry;
/// Cheap host-scoped launch probe. Returns YES only for entries previously
/// confirmed by Apply in this exact host executable.
@property (class, nonatomic, readonly) BOOL hasPersistedConfirmedEntries;
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
/// Secondary-scope typed force value (int64 / pointer / double / float bits).
- (void)stageForceRawValue:(uint64_t)rawValue forEntryIdentifier:(NSString *)identifier;
- (void)configureEntryIdentifier:(NSString *)identifier
                              abi:(FLEXHookABI)abi
                          backend:(FLEXHookBackend)backend;
- (void)discardPendingChanges;
- (BOOL)hasPendingChanges;
- (NSUInteger)pendingCount;
/// Installed gates that currently override their original implementation.
- (NSUInteger)armedCount;
/// Armed hooks whose replacement has handled at least one real call.
- (NSUInteger)observedCount;
/// Compatibility alias for armedCount. UI must not label this as observed.
- (NSUInteger)activeCount;
- (NSUInteger)failureCount;

- (void)applyPendingWithCompletion:(nullable FLEXHookApplyCompletion)completion;
/// Applies exactly one row's staged state. Runtime-browser and contextual
/// switches use this path so a toggle changes behavior immediately without
/// accidentally committing unrelated pending edits.
- (void)applyEntryIdentifier:(NSString *)identifier
                  completion:(nullable FLEXHookApplyCompletion)completion;
/// Disables a replacement that accepted installation but failed a direct,
/// ABI-safe dispatch probe. The physical patch remains and forwards original.
- (void)failClosedEntryIdentifier:(NSString *)identifier reason:(NSString *)reason;
- (void)reapplyPersistedEntries;
- (void)refreshCapabilities;
- (void)clearSafeMode;

@end

NS_ASSUME_NONNULL_END
