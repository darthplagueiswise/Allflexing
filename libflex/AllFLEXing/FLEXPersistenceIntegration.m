#import "FLEXPersistenceStore.h"

#import "FLEXHookPersistence.h"
#import "FLEXHookRegistry.h"
#import "FLEXHookToggles.h"

#import <objc/runtime.h>

static void FLEXPersistenceExchange(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

@interface FLEXHookRegistry (AllFLEXingPrivateApply)
- (void)applyEntries:(NSArray<FLEXHookEntry *> *)entries
               force:(BOOL)force
              reason:(NSString *)reason
          completion:(nullable FLEXHookApplyCompletion)completion;
- (void)persistEntries;
- (void)af_applyConfiguredEntriesWithCompletion:(nullable FLEXHookApplyCompletion)completion;
@end

@interface FLEXHookToggles (AllFLEXingPrivateApply)
- (void)updateNavigationActions;
- (void)applyPendingWithRestart:(BOOL)restart;
- (void)confirmCloseAndReopen;
@end

@implementation FLEXHookPersistence (AllFLEXingDurablePersistence)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        (void)FLEXPersistenceStore.sharedStore;
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
        FLEXPersistenceExchange(
            FLEXHookToggles.class,
            NSSelectorFromString(@"updateNavigationActions"),
            @selector(af_persist_updateNavigationActions)
        );
        FLEXPersistenceExchange(
            FLEXHookToggles.class,
            NSSelectorFromString(@"applyPendingWithRestart:"),
            @selector(af_persist_applyPendingWithRestart:)
        );
    });
}

- (void)af_persist_setBool:(BOOL)value forFlag:(NSString *)identifier {
    [self af_persist_setBool:value forFlag:identifier];
    [FLEXPersistenceStore.sharedStore synchronizeNow];
}

- (NSString *)af_persist_storageDomainDescription {
    return FLEXPersistenceStore.sharedStore.storageDescription;
}

@end

@implementation FLEXHookRegistry (AllFLEXingDurablePersistence)

- (void)af_persist_registryEntries {
    [self af_persist_registryEntries];
    [FLEXPersistenceStore.sharedStore synchronizeNow];
}

- (void)af_applyConfiguredEntriesWithCompletion:(FLEXHookApplyCompletion)completion {
    [self refreshCapabilities];
    NSMutableArray<FLEXHookEntry *> *targets = [NSMutableArray array];
    for (FLEXHookEntry *entry in self.entries) {
        if (entry.pendingEnabled != entry.desiredEnabled ||
            entry.desiredEnabled || entry.installed || entry.userConfigured) {
            [targets addObject:entry];
        }
    }

    if (!targets.count) {
        [FLEXPersistenceStore.sharedStore synchronizeNow];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(@[], @[]);
            }
        });
        return;
    }

    [self applyEntries:targets.copy
                 force:YES
                reason:@"manual-apply-all"
            completion:^(NSArray<FLEXHookEntry *> *applied,
                         NSArray<FLEXHookEntry *> *failed) {
        [FLEXPersistenceStore.sharedStore synchronizeNow];
        if (completion) {
            completion(applied, failed);
        }
    }];
}

@end

@implementation FLEXHookToggles (AllFLEXingFunctionalApply)

- (void)af_persist_updateNavigationActions {
    [self af_persist_updateNavigationActions];
    @try {
        UIBarButtonItem *applyItem = [self valueForKey:@"applyItem"];
        FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
        applyItem.enabled = !registry.isApplying;
        applyItem.title = registry.isApplying
            ? @"Applying…"
            : (registry.hasPendingChanges ? @"Apply" : @"Reapply");
    } @catch (__unused NSException *exception) {
    }
}

- (void)af_persist_applyPendingWithRestart:(BOOL)restart {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    if (registry.isApplying) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    [registry af_applyConfiguredEntriesWithCompletion:^(
        NSArray<FLEXHookEntry *> *applied,
        NSArray<FLEXHookEntry *> *failed
    ) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        BOOL persisted = [FLEXPersistenceStore.sharedStore synchronizeNow];
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:(failed.count || !persisted)
            ? UINotificationFeedbackTypeError
            : UINotificationFeedbackTypeSuccess];

        if (restart && !failed.count && persisted) {
            [self confirmCloseAndReopen];
            return;
        }

        NSString *message = nil;
        if (failed.count) {
            message = [NSString stringWithFormat:
                @"Applied/revalidated %lu target(s); %lu failed. Persistence: %@",
                (unsigned long)applied.count,
                (unsigned long)failed.count,
                FLEXPersistenceStore.sharedStore.storageDescription];
        } else if (!persisted) {
            message = [NSString stringWithFormat:
                @"Hooks were revalidated, but persistence failed: %@",
                FLEXPersistenceStore.sharedStore.lastError ?: @"unknown write error"];
        } else {
            message = [NSString stringWithFormat:
                @"Revalidated %lu configured target(s) and synchronized persistence through %@.",
                (unsigned long)applied.count,
                FLEXPersistenceStore.sharedStore.storageDescription];
        }

        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:(failed.count || !persisted)
                ? @"Apply completed with errors" : @"Apply completed"
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

@end
