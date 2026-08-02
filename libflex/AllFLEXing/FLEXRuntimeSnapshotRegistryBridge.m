#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"

#import <objc/runtime.h>

const char *FLEXRuntimeSnapshotRegistryBridgeABIVersion =
    "AllFLEXing transient runtime snapshot bridge ABI 2";

@interface FLEXHookRegistry (AllFLEXingRuntimeSnapshotBridgePrivate)
- (FLEXHookEntry *)af_runtimeSnapshot_upsertDiscoveredEntry:(FLEXHookEntry *)entry;
- (void)af_runtimeSnapshot_stageEnabled:(BOOL)enabled
                     forEntryIdentifier:(NSString *)identifier;
@end

@interface FLEXHookEntryDetailController (AllFLEXingRuntimeSnapshotBridgePrivate)
- (instancetype)af_runtimeSnapshot_initWithEntry:(FLEXHookEntry *)entry;
@end

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
    NSMutableDictionary *locator = [copy.locator mutableCopy] ?: [NSMutableDictionary dictionary];
    locator[@"runtimeSnapshotPromoted"] = @YES;
    copy.locator = locator.copy;
    return copy;
}

static void FLEXBridgeExchangeInstanceMethods(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

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
        FLEXBridgeExchangeInstanceMethods(
            FLEXHookEntryDetailController.class,
            @selector(initWithEntry:),
            @selector(af_runtimeSnapshot_initWithEntry:)
        );
    });
}

- (FLEXHookEntry *)af_runtimeSnapshot_upsertDiscoveredEntry:(FLEXHookEntry *)entry {
    if (!FLEXEntryComesFromRuntimeImageSession(entry)) {
        return [self af_runtimeSnapshot_upsertDiscoveredEntry:entry];
    }

    FLEXHookEntry *existing = [self entryForIdentifier:entry.identifier];
    if (existing) {
        return [self af_runtimeSnapshot_upsertDiscoveredEntry:entry];
    }

    // A complete image may contain tens of thousands of entries. Keep every
    // unconfigured row transient so scanning emits no registry notifications.
    // NSMapTable holds weak values; the active browser snapshot owns the rows.
    @synchronized (FLEXTransientRuntimeEntries()) {
        [FLEXTransientRuntimeEntries() setObject:entry forKey:entry.identifier];
    }
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
    [self af_runtimeSnapshot_stageEnabled:enabled forEntryIdentifier:identifier];
}

@end

@implementation FLEXHookEntryDetailController (AllFLEXingRuntimeSnapshotBridge)

- (instancetype)af_runtimeSnapshot_initWithEntry:(FLEXHookEntry *)entry {
    FLEXHookEntry *resolved = entry;
    if (FLEXEntryComesFromRuntimeImageSession(entry)) {
        FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
        resolved = [registry entryForIdentifier:entry.identifier];
        if (!resolved) {
            FLEXHookEntry *promoted = FLEXPromotableEntryCopy(entry);
            promoted.userConfigured = NO;
            resolved = [registry af_runtimeSnapshot_upsertDiscoveredEntry:promoted];
        }
    }
    return [self af_runtimeSnapshot_initWithEntry:resolved ?: entry];
}

@end
