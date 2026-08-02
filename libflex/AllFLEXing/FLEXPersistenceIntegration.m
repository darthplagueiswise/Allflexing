#import "FLEXPersistenceStore.h"

#import "FLEXHookPersistence.h"
#import "FLEXHookRegistry.h"

#import <objc/runtime.h>

const char *FLEXDeferredPersistenceIntegrationABIVersion =
    "AllFLEXing deferred coalesced persistence integration ABI 1";

static void FLEXPersistenceExchange(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

@interface FLEXHookRegistry (AllFLEXingPersistencePrivate)
- (void)persistEntries;
@end

@implementation FLEXHookPersistence (AllFLEXingDurablePersistence)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Install the lightweight method exchanges only. Do not create the
        // persistence store or touch the filesystem from +load.
        FLEXPersistenceExchange(
            FLEXHookPersistence.class,
            @selector(setBool:forFlag:),
            @selector(af_persist_setBool:forFlag:)
        );
        FLEXPersistenceExchange(
            FLEXHookPersistence.class,
            @selector(storageDomainDescription),
            @selector(af_persist_storageDomainDescription)
        );
        FLEXPersistenceExchange(
            FLEXHookRegistry.class,
            NSSelectorFromString(@"persistEntries"),
            @selector(af_persist_registryEntries)
        );
    });
}

- (void)af_persist_setBool:(BOOL)value forFlag:(NSString *)identifier {
    [self af_persist_setBool:value forFlag:identifier];
    [FLEXPersistenceStore.sharedStore synchronizeSoon];
}

- (NSString *)af_persist_storageDomainDescription {
    return FLEXPersistenceStore.sharedStore.storageDescription;
}

@end

@implementation FLEXHookRegistry (AllFLEXingDurablePersistence)

- (void)af_persist_registryEntries {
    [self af_persist_registryEntries];
    [FLEXPersistenceStore.sharedStore synchronizeSoon];
}

@end
