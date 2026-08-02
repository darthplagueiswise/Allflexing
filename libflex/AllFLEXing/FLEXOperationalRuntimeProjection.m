#import "FLEXRuntimeBrowserController.h"

#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"

#import <objc/runtime.h>
#import <string.h>

const char *FLEXOperationalRuntimeProjectionABIVersion =
    "AllFLEXing operational Objective-C hook-target projection ABI 1";

static IMP gFLEXOperationalBuildIndexIMP;
static IMP gFLEXOperationalFastBuildIndexIMP;

static const char *FLEXOperationalSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static FLEXHookABI FLEXOperationalObjectiveCABI(Method method) {
    if (!method) return FLEXHookABIUnknown;

    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (*FLEXOperationalSkipQualifiers(returnType) != 'B') {
        return FLEXHookABIUnknown;
    }

    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount == 2) {
        return FLEXHookABIObjCBoolNoArguments;
    }
    if (argumentCount != 3) {
        return FLEXHookABIUnknown;
    }

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *code = FLEXOperationalSkipQualifiers(argumentType);
    if (*code == '@' || *code == '#' || *code == ':') {
        return FLEXHookABIObjCBoolObjectArgument;
    }
    if (strchr("BcCsSiIlLqQ", *code)) {
        return FLEXHookABIObjCBoolIntegerArgument;
    }
    return FLEXHookABIUnknown;
}

static BOOL FLEXOperationalImageMatches(NSString *requested, const char *rawLoaded) {
    if (!requested.length || !rawLoaded) return YES;
    NSString *loaded = [NSString stringWithUTF8String:rawLoaded];
    if (!loaded.length) return NO;
    if ([requested containsString:@"/"]) {
        return [requested isEqualToString:loaded];
    }
    return [requested.lastPathComponent isEqualToString:loaded.lastPathComponent];
}

static BOOL FLEXOperationalObjectiveCEntry(FLEXHookEntry *entry) {
    if (!entry || entry.surface != FLEXHookSurfaceObjectiveC) return NO;
    if (!FLEXMSHookMessageProviderAvailable()) return NO;

    NSDictionary *locator = [entry.locator isKindOfClass:NSDictionary.class]
        ? entry.locator : nil;
    NSString *className = [locator[@"class"] isKindOfClass:NSString.class]
        ? locator[@"class"] : nil;
    NSString *selectorName = [locator[@"selector"] isKindOfClass:NSString.class]
        ? locator[@"selector"] : nil;
    if (!className.length || !selectorName.length) return NO;

    Class targetClass = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    BOOL classMethod = [locator[@"classMethod"] boolValue];
    if (!targetClass || !selector) return NO;

    NSString *requestedImage = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : nil;
    if (!FLEXOperationalImageMatches(requestedImage,
                                     class_getImageName(targetClass))) {
        return NO;
    }

    Method method = classMethod
        ? class_getClassMethod(targetClass, selector)
        : class_getInstanceMethod(targetClass, selector);
    FLEXHookABI exactABI = FLEXOperationalObjectiveCABI(method);
    if (exactABI == FLEXHookABIUnknown) return NO;

    entry.abi = exactABI;
    entry.backend = FLEXHookBackendObjectiveCElleKit;
    entry.available = YES;
    entry.hookable = YES;
    entry.stale = NO;
    entry.lastError = nil;

    NSMutableDictionary *updatedLocator = [locator mutableCopy]
        ?: [NSMutableDictionary dictionary];
    updatedLocator[@"abiEvidence"] = @"objc-type-encoding-operational-profile";
    updatedLocator[@"backendEvidence"] = @"MSHookMessageEx-live-provider";
    entry.locator = updatedLocator.copy;
    return YES;
}

static FLEXRuntimeBrowserKind FLEXOperationalBrowserKind(id controller) {
    @try {
        return (FLEXRuntimeBrowserKind)[[controller valueForKey:@"kind"] integerValue];
    } @catch (__unused NSException *exception) {
        return FLEXRuntimeBrowserKindC;
    }
}

static NSArray<FLEXHookEntry *> *FLEXOperationalProjection(
    id controller,
    NSArray<FLEXHookEntry *> *entries
) {
    if (FLEXOperationalBrowserKind(controller) != FLEXRuntimeBrowserKindObjectiveC) {
        return entries ?: @[];
    }

    NSMutableArray<FLEXHookEntry *> *operational =
        [NSMutableArray arrayWithCapacity:entries.count];
    for (FLEXHookEntry *entry in entries ?: @[]) {
        if (FLEXOperationalObjectiveCEntry(entry)) {
            [operational addObject:entry];
        }
    }
    return operational.copy;
}

static void FLEXOperationalBuildIndex(id object,
                                      SEL selector,
                                      NSArray<FLEXHookEntry *> *entries) {
    IMP original = sel_isEqual(selector,
                               NSSelectorFromString(@"af_fast_buildSearchIndexForEntries:"))
        ? gFLEXOperationalFastBuildIndexIMP
        : gFLEXOperationalBuildIndexIMP;
    if (!original) return;

    NSArray<FLEXHookEntry *> *projected =
        FLEXOperationalProjection(object, entries);
    ((void (*)(id, SEL, NSArray<FLEXHookEntry *> *))original)(
        object,
        selector,
        projected
    );
}

static void FLEXOperationalInstallSelector(Class cls,
                                            SEL selector,
                                            IMP *storage) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)FLEXOperationalBuildIndex) return;
    *storage = current;
    method_setImplementation(method, (IMP)FLEXOperationalBuildIndex);
}

static void FLEXInstallOperationalRuntimeProjection(void) {
    Class cls = FLEXRuntimeBrowserController.class;
    FLEXOperationalInstallSelector(
        cls,
        NSSelectorFromString(@"buildSearchIndexForEntries:"),
        &gFLEXOperationalBuildIndexIMP
    );
    FLEXOperationalInstallSelector(
        cls,
        NSSelectorFromString(@"af_fast_buildSearchIndexForEntries:"),
        &gFLEXOperationalFastBuildIndexIMP
    );
}

__attribute__((constructor))
static void FLEXOperationalRuntimeProjectionBootstrap(void) {
    // The complete-index module installs after two main-queue turns. Install
    // this projection one turn later so it wraps that implementation rather
    // than being overwritten by it.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                FLEXInstallOperationalRuntimeProjection();
            });
        });
    });
}
