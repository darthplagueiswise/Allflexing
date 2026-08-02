#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"

#import <objc/runtime.h>

const char *FLEXRuntimeSnapshotRegistryBridgeABIVersion =
    "AllFLEXing transient runtime snapshot bridge ABI 1";

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

    // Keep unresolved/inspection entries out of the persistent registry while
    // scanning a complete image. A verified hookable target may enter directly;
    // every other entry is promoted only when the user opens it.
    if (!entry.hookable && !entry.userConfigured) {
        return entry;
    }
    return [self af_runtimeSnapshot_upsertDiscoveredEntry:entry];
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
