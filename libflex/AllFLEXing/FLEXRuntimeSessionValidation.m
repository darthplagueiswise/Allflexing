#import "FLEXRuntimeImageSession.h"

#import "FLEXCHookEngine.h"
#import "FLEXHooking.h"
#import "FLEXSymbolRebind.h"

#import <objc/runtime.h>

const char *FLEXRuntimeSessionValidationABIVersion =
    "AllFLEXing selected-image verified-backend snapshot ABI 1";

static dispatch_queue_t FLEXRuntimeSessionValidationQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_USER_INITIATED,
            0
        );
        queue = dispatch_queue_create(
            "com.allflexing.runtime-session.backend-validation",
            attributes
        );
    });
    return queue;
}

static void FLEXSessionExchangeInstanceMethods(Class cls,
                                                SEL original,
                                                SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

static BOOL FLEXSessionEntryHasRealBackend(FLEXHookEntry *entry,
                                           FLEXRuntimeBrowserKind kind) {
    if (!entry.available || entry.stale) {
        return NO;
    }

    if (kind == FLEXRuntimeBrowserKindObjectiveC) {
        return entry.surface == FLEXHookSurfaceObjectiveC &&
               entry.backend == FLEXHookBackendObjectiveCElleKit &&
               entry.abi != FLEXHookABIUnknown &&
               FLEXMSHookMessageProviderAvailable();
    }

    if (entry.surface == FLEXHookSurfaceCImport) {
        return entry.backend == FLEXHookBackendFishhook &&
               FLEXEmbeddedFishhookAvailable() &&
               [entry.locator[@"bindSlots"] unsignedIntegerValue] > 0;
    }

    if (entry.surface == FLEXHookSurfaceCInline) {
        // The current inline engine resolves named symbols. Anonymous function
        // starts are useful disassembly evidence, but they are not toggleable
        // until an address-based engine is implemented end-to-end.
        if (entry.backend != FLEXHookBackendInlineElleKit ||
            ![entry.locator[@"source"] isEqualToString:@"mach-o-symbol-table"] ||
            !FLEXMSHookFunctionProviderAvailable()) {
            return NO;
        }
        NSString *symbol = [entry.locator[@"symbol"]
            isKindOfClass:NSString.class] ? entry.locator[@"symbol"] : nil;
        NSNumber *address = [entry.locator[@"address"]
            isKindOfClass:NSNumber.class] ? entry.locator[@"address"] : nil;
        if (!symbol.length || !address.unsignedLongLongValue) {
            return NO;
        }
        void *resolved = [FLEXCHookEngine resolveSymbol:symbol];
        return resolved == (void *)(uintptr_t)address.unsignedLongLongValue;
    }

    return NO;
}

@implementation FLEXRuntimeImageSession (AllFLEXingVerifiedSnapshot)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLEXSessionExchangeInstanceMethods(
            FLEXRuntimeImageSession.class,
            @selector(scanKind:progress:completion:),
            @selector(af_verified_scanKind:progress:completion:)
        );
    });
}

- (void)af_verified_scanKind:(FLEXRuntimeBrowserKind)kind
                    progress:(FLEXRuntimeImageProgress)progress
                  completion:(FLEXRuntimeImageCompletion)completion {
    __weak typeof(self) weakSelf = self;
    [self af_verified_scanKind:kind
                      progress:progress
                    completion:^(
        FLEXRuntimeImageSnapshot *snapshot,
        NSError *error
    ) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.cancelled || !snapshot || error) {
            if (completion) {
                completion(snapshot, error);
            }
            return;
        }

        if (progress) {
            progress(@"Validating available hook backends", 0, snapshot.entries.count);
        }
        dispatch_async(FLEXRuntimeSessionValidationQueue(), ^{
            if (self.cancelled) {
                return;
            }
            NSMutableArray<FLEXHookEntry *> *verified =
                [NSMutableArray arrayWithCapacity:snapshot.entries.count];
            NSUInteger processed = 0;
            NSUInteger imports = 0;
            NSUInteger inlineFunctions = 0;
            NSUInteger objectiveCMethods = 0;

            for (FLEXHookEntry *entry in snapshot.entries) {
                if (self.cancelled) {
                    return;
                }
                if (FLEXSessionEntryHasRealBackend(entry, kind)) {
                    [verified addObject:entry];
                    if (entry.surface == FLEXHookSurfaceObjectiveC) {
                        objectiveCMethods++;
                    } else if (entry.surface == FLEXHookSurfaceCImport) {
                        imports++;
                    } else if (entry.surface == FLEXHookSurfaceCInline) {
                        inlineFunctions++;
                    }
                }
                processed++;
                if (progress && ((processed & 2047) == 0 ||
                                 processed == snapshot.entries.count)) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!self.cancelled) {
                            progress(@"Validating available hook backends",
                                     processed,
                                     snapshot.entries.count);
                        }
                    });
                }
            }

            if (self.cancelled) {
                return;
            }
            snapshot.entries = verified.copy;
            snapshot.objectiveCMethodCount = objectiveCMethods;
            snapshot.importedSymbolCount = imports;
            snapshot.definedFunctionCount = inlineFunctions;
            snapshot.anonymousFunctionCount = 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.cancelled && completion) {
                    completion(snapshot, nil);
                }
            });
        });
    }];
}

@end
