#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXRuntimeBrowserController.h"

#import <objc/runtime.h>

const char *FLEXRuntimeCrashGuardsABIVersion =
    "AllFLEXing runtime browser crash guards ABI 1";

typedef id (*FLEXDetailInitIMP)(id object, SEL selector, FLEXHookEntry *entry);

static IMP FLEXBridgeDetailInitImplementation = NULL;
static IMP FLEXOriginalDetailInitImplementation = NULL;

static id FLEXSafeDetailInit(id object, SEL selector, FLEXHookEntry *entry) {
    // Objective-C runtime entries already carry an exact Method-derived ABI.
    // Opening the inspector must be read-only: promoting the transient entry
    // here posts a synchronous registry notification while the navigation
    // controller is still constructing the detail screen.
    if (entry.surface == FLEXHookSurfaceObjectiveC &&
        FLEXOriginalDetailInitImplementation) {
        return ((FLEXDetailInitIMP)FLEXOriginalDetailInitImplementation)(
            object,
            selector,
            entry
        );
    }

    // C entries still use the bridge initializer so ABI/backend configuration
    // can promote the transient snapshot row before the user changes it.
    if (FLEXBridgeDetailInitImplementation) {
        return ((FLEXDetailInitIMP)FLEXBridgeDetailInitImplementation)(
            object,
            selector,
            entry
        );
    }
    if (FLEXOriginalDetailInitImplementation) {
        return ((FLEXDetailInitIMP)FLEXOriginalDetailInitImplementation)(
            object,
            selector,
            entry
        );
    }
    return nil;
}

static void FLEXInstallRuntimeCrashGuards(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class browserClass = FLEXRuntimeBrowserController.class;
        SEL fastScheduleSelector = NSSelectorFromString(
            @"scheduleSearchForText:immediate:"
        );
        SEL aliasScheduleSelector = NSSelectorFromString(
            @"af_fast_scheduleSearchForText:immediate:"
        );
        Method fastSchedule = class_getInstanceMethod(
            browserClass,
            fastScheduleSelector
        );
        Method aliasSchedule = class_getInstanceMethod(
            browserClass,
            aliasScheduleSelector
        );
        if (fastSchedule && aliasSchedule) {
            // The bridge intentionally swizzles these selectors. Its refresh
            // path calls the alias selector, which otherwise still points to
            // the obsolete array-scanning implementation and interprets
            // FLEXHookEntry objects as FLEXRuntimeSearchRecord objects.
            // Point both selectors at the indexed implementation so focus,
            // registry notifications and view appearance use one type-safe
            // search path.
            method_setImplementation(
                aliasSchedule,
                method_getImplementation(fastSchedule)
            );
        }

        Class detailClass = FLEXHookEntryDetailController.class;
        Method detailInitializer = class_getInstanceMethod(
            detailClass,
            @selector(initWithEntry:)
        );
        Method originalInitializerAlias = class_getInstanceMethod(
            detailClass,
            NSSelectorFromString(@"af_runtimeSnapshot_initWithEntry:")
        );
        if (detailInitializer && originalInitializerAlias) {
            FLEXBridgeDetailInitImplementation =
                method_getImplementation(detailInitializer);
            FLEXOriginalDetailInitImplementation =
                method_getImplementation(originalInitializerAlias);
            method_setImplementation(
                detailInitializer,
                (IMP)FLEXSafeDetailInit
            );
        }
    });
}

__attribute__((constructor))
static void FLEXRuntimeCrashGuardsBootstrap(void) {
    // Objective-C +load swizzles have completed before the app begins normal
    // UI work. Deferring to the main queue also makes the final IMP ownership
    // deterministic regardless of object-file order in the dylib.
    dispatch_async(dispatch_get_main_queue(), ^{
        FLEXInstallRuntimeCrashGuards();
    });
}
