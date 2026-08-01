#import "FLEXHooking.h"

#import <dlfcn.h>

typedef void (*FLEXMSHookMessageExFunction)(Class, SEL, IMP, IMP *);
typedef void (*FLEXMSHookFunctionFunction)(void *, void *, void **);

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
    return (FLEXMSHookMessageExFunction)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
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

    FLEXMSHookFunctionFunction hook =
        (FLEXMSHookFunctionFunction)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!hook) {
        return NO;
    }

    hook(symbol, replacement, original);
    return YES;
}

NSString *FLEXMessageHookBackend(void) {
    return FLEXResolveMSHookMessageEx()
        ? @"MSHookMessageEx (optional loaded provider)"
        : @"Objective-C runtime (standalone fallback)";
}
