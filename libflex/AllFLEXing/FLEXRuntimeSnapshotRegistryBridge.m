#import "FLEXHookRegistry.h"

#import <objc/runtime.h>

const char *FLEXRuntimeSnapshotRegistryBridgeABIVersion =
    "AllFLEXing transient runtime snapshot bridge ABI 3 registry-only";

static NSMapTable<NSString *, FLEXHookEntry *> *FLEXTransientRuntimeEntries(void) {
    static NSMapTable<NSString *, FLEXHookEntry *> *entries;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        entries = [NSMapTable strongToWeakObjectsMapTable];
    });
    return entries;
}

static BOOL FLEXEntryComesFromRuntimeImageSession(FLEXHookEntry *entry) {
    NSString *source = [entry.locator[@"source"] isKindOfClass:NSString.class]
        ? entry.locator[@"source"] : @"";
    return [source isEqualToString:@"objc-runtime-metadata"] ||
           [source isEqualToString:@"mach-o-indirect-symbols"] ||
           [source isEqualToString:@"mach-o-symbol-table"] ||
           [source isEqualToString:@"LC_FUNCTION_STARTS"];
}

static FLEXHookEntry *FLEXPromotableEntryCopy(FLEXHookEntry *entry) {
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
- (FLEXHookEntry *)af_runtimeSnapshot_upsertDiscoveredEntry:(FLEXHookEntry *)entry;
- (void)af_runtimeSnapshot_stageEnabled:(BOOL)enabled
                     forEntryIdentifier:(NSString *)identifier;
@end

@implementation FLEXHookRegistry (AllFLEXingRuntimeSnapshotBridge)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLEXBridgeExchangeInstanceMethods(
            FLEXHookRegistry.class,
            @selector(upsertDiscoveredEntry:),
            @selector(af_runtimeSnapshot_upsertDiscoveredEntry:)
        );
        FLEXBridgeExchangeInstanceMethods(
            FLEXHookRegistry.class,
            @selector(stageEnabled:forEntryIdentifier:),
            @selector(af_runtimeSnapshot_stageEnabled:forEntryIdentifier:)
        );
    });
}

- (FLEXHookEntry *)af_runtimeSnapshot_upsertDiscoveredEntry:(FLEXHookEntry *)entry {
    if (!entry.identifier.length || !FLEXEntryComesFromRuntimeImageSession(entry)) {
        return [self af_runtimeSnapshot_upsertDiscoveredEntry:entry];
    }

    FLEXHookEntry *existing = [self entryForIdentifier:entry.identifier];
    if (existing) {
        return [self af_runtimeSnapshot_upsertDiscoveredEntry:entry];
    }

    @synchronized (FLEXTransientRuntimeEntries()) {
        [FLEXTransientRuntimeEntries() setObject:entry forKey:entry.identifier];
    }

    // Scanning and opening rows are read-only. Persist only after a real user
    // configuration operation marks the row as userConfigured.
    if (!entry.userConfigured) {
        return entry;
    }
    return [self af_runtimeSnapshot_upsertDiscoveredEntry:entry];
}

- (void)af_runtimeSnapshot_stageEnabled:(BOOL)enabled
                     forEntryIdentifier:(NSString *)identifier {
    if (enabled && ![self entryForIdentifier:identifier]) {
        FLEXHookEntry *transient = nil;
        @synchronized (FLEXTransientRuntimeEntries()) {
            transient = [FLEXTransientRuntimeEntries() objectForKey:identifier];
        }
        if (transient) {
            FLEXHookEntry *promoted = FLEXPromotableEntryCopy(transient);
            promoted.userConfigured = YES;
            [self af_runtimeSnapshot_upsertDiscoveredEntry:promoted];
        }
    }
    [self af_runtimeSnapshot_stageEnabled:enabled
                       forEntryIdentifier:identifier];
}

@end
