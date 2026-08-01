#import "FLEXHooking.h"

#import <dlfcn.h>
#import <substrate.h>
#import <string.h>

typedef void (*FLEXMSHookMessageExFunction)(Class, SEL, IMP, IMP *);
typedef void (*FLEXMSHookFunctionFunction)(void *, void *, void **);

// Strong references make the Substrate-compatible dependency part of the
// Mach-O contract. Feather rewrites/installs that framework using ElleKit in the
// signed host app. dlsym below remains useful for capability diagnostics, but
// is no longer the only thing connecting the product to its hook provider.
__attribute__((used))
static FLEXMSHookMessageExFunction const FLEXLinkedMSHookMessageEx = MSHookMessageEx;
__attribute__((used))
static FLEXMSHookFunctionFunction const FLEXLinkedMSHookFunction = MSHookFunction;

static NSMutableDictionary<NSString *, NSValue *> *FLEXInstalledMessageHooks(void) {
    static NSMutableDictionary<NSString *, NSValue *> *hooks;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hooks = [NSMutableDictionary dictionary];
    });
    return hooks;
}

static NSString *FLEXHookKey(Class targetClass, SEL selector, BOOL classMethod) {
    return [NSString stringWithFormat:@"%p|%@|%@",
        targetClass,
        classMethod ? @"+" : @"-",
        NSStringFromSelector(selector)];
}

static FLEXMSHookMessageExFunction FLEXResolveMSHookMessageEx(void) {
    FLEXMSHookMessageExFunction resolved =
        (FLEXMSHookMessageExFunction)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    return resolved ?: FLEXLinkedMSHookMessageEx;
}

static FLEXMSHookFunctionFunction FLEXResolveMSHookFunction(void) {
    FLEXMSHookFunctionFunction resolved =
        (FLEXMSHookFunctionFunction)dlsym(RTLD_DEFAULT, "MSHookFunction");
    return resolved ?: FLEXLinkedMSHookFunction;
}

static BOOL FLEXInstallRuntimeMethodHook(Class dispatchClass,
                                         SEL selector,
                                         IMP replacement,
                                         IMP *original) {
    Method resolvedMethod = class_getInstanceMethod(dispatchClass, selector);
    if (!resolvedMethod) {
        return NO;
    }

    IMP inheritedOrCurrent = method_getImplementation(resolvedMethod);
    const char *types = method_getTypeEncoding(resolvedMethod);

    // class_addMethod creates a local override when the implementation is
    // inherited. That avoids accidentally mutating the superclass globally.
    if (class_addMethod(dispatchClass, selector, replacement, types)) {
        if (original) {
            *original = inheritedOrCurrent;
        }
        return YES;
    }

    Method localMethod = class_getInstanceMethod(dispatchClass, selector);
    if (!localMethod) {
        return NO;
    }

    IMP previous = method_setImplementation(localMethod, replacement);
    if (original) {
        *original = previous ?: inheritedOrCurrent;
    }
    return YES;
}

static BOOL FLEXHookMessageInternal(Class targetClass,
                                    SEL selector,
                                    IMP replacement,
                                    IMP *original,
                                    BOOL classMethod) {
    if (!targetClass || !selector || !replacement) {
        return NO;
    }

    NSString *key = FLEXHookKey(targetClass, selector, classMethod);
    NSMutableDictionary *installed = FLEXInstalledMessageHooks();
    @synchronized (installed) {
        NSValue *existing = installed[key];
        if (existing) {
            if (original) {
                *original = existing.pointerValue;
            }
            return YES;
        }
    }

    Class dispatchClass = classMethod ? object_getClass(targetClass) : targetClass;
    if (!dispatchClass) {
        return NO;
    }

    IMP capturedOriginal = NULL;
    FLEXMSHookMessageExFunction substrateHook = FLEXResolveMSHookMessageEx();
    if (substrateHook) {
        substrateHook(dispatchClass, selector, replacement, &capturedOriginal);
    } else if (!FLEXInstallRuntimeMethodHook(dispatchClass, selector, replacement, &capturedOriginal)) {
        return NO;
    }

    @synchronized (installed) {
        installed[key] = [NSValue valueWithPointer:capturedOriginal];
    }
    if (original) {
        *original = capturedOriginal;
    }
    return YES;
}

BOOL FLEXHookMessage(Class targetClass, SEL selector, IMP replacement, IMP *original) {
    return FLEXHookMessageInternal(targetClass, selector, replacement, original, NO);
}

BOOL FLEXHookClassMessage(Class targetClass, SEL selector, IMP replacement, IMP *original) {
    return FLEXHookMessageInternal(targetClass, selector, replacement, original, YES);
}

BOOL FLEXHookFunctionIfAvailable(void *symbol,
                                 void *replacement,
                                 void **original) {
    if (!symbol || !replacement) {
        return NO;
    }

    FLEXMSHookFunctionFunction hook = FLEXResolveMSHookFunction();
    if (!hook) {
        return NO;
    }

    void *captured = NULL;
    void **outOriginal = original ?: &captured;
    hook(symbol, replacement, outOriginal);
    return *outOriginal != NULL;
}

BOOL FLEXMSHookProviderAvailable(void) {
    return FLEXResolveMSHookMessageEx() != NULL &&
           FLEXResolveMSHookFunction() != NULL;
}

static BOOL FLEXProviderInfoForAddress(void *address, Dl_info *info) {
    if (!address || !info) {
        return NO;
    }
    memset(info, 0, sizeof(*info));
    return dladdr(address, info) != 0 && info->dli_fname != NULL;
}

NSString *FLEXMSHookProviderPath(void) {
    Dl_info info;
    if (!FLEXProviderInfoForAddress((void *)FLEXResolveMSHookMessageEx(), &info)) {
        return @"Unavailable";
    }
    return [NSString stringWithUTF8String:info.dli_fname] ?: @"Unknown image";
}

BOOL FLEXMSHookProviderIsElleKit(void) {
    void *marker = dlsym(RTLD_DEFAULT, "EKEnableThreadSafety");
    if (!marker) {
        return NO;
    }

    Dl_info hookInfo;
    Dl_info markerInfo;
    if (!FLEXProviderInfoForAddress((void *)FLEXResolveMSHookMessageEx(), &hookInfo) ||
        !FLEXProviderInfoForAddress(marker, &markerInfo)) {
        return NO;
    }
    return hookInfo.dli_fbase != NULL && hookInfo.dli_fbase == markerInfo.dli_fbase;
}

NSString *FLEXMSHookProviderName(void) {
    if (!FLEXMSHookProviderAvailable()) {
        return @"Unavailable";
    }
    if (FLEXMSHookProviderIsElleKit()) {
        return @"ElleKit (Substrate-compatible)";
    }

    NSString *path = FLEXMSHookProviderPath();
    NSString *image = path.lastPathComponent;
    return [NSString stringWithFormat:@"Substrate-compatible (%@)",
        image.length ? image : @"unknown provider"];
}

NSString *FLEXMessageHookBackend(void) {
    return FLEXResolveMSHookMessageEx()
        ? [NSString stringWithFormat:@"MSHookMessageEx · %@", FLEXMSHookProviderName()]
        : @"Objective-C runtime (degraded fallback)";
}
