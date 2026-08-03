#import "FLEXRuntimeScanner.h"

#import "FLEXHookRegistry.h"

#import <objc/runtime.h>

const char *FLEXStrictObjectiveCRuntimeScannerABIVersion =
    "AllFLEXing exact-B Objective-C runtime classification ABI 1";

static const char *FLEXStrictSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static FLEXHookABI FLEXStrictABIForMethod(Method method) {
    if (!method) return FLEXHookABIUnknown;
    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (*FLEXStrictSkipQualifiers(returnType) != 'B') {
        return FLEXHookABIUnknown;
    }

    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount == 2) return FLEXHookABIObjCBoolNoArguments;
    if (argumentCount != 3) return FLEXHookABIUnknown;

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *code = FLEXStrictSkipQualifiers(argumentType);
    if (*code == '@' || *code == '#' || *code == ':') {
        return FLEXHookABIObjCBoolObjectArgument;
    }
    if (strchr("BcCsSiIlLqQ", *code)) {
        return FLEXHookABIObjCBoolIntegerArgument;
    }
    return FLEXHookABIUnknown;
}

@interface FLEXRuntimeScanner (AllFLEXingStrictObjectiveC)
+ (FLEXHookEntry *)af_strict_objectiveCEntryForClass:(Class)targetClass
                                            selector:(SEL)selector
                                         classMethod:(BOOL)classMethod;
@end

@implementation FLEXRuntimeScanner (AllFLEXingStrictObjectiveC)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class meta = object_getClass(FLEXRuntimeScanner.class);
        Method original = class_getInstanceMethod(
            meta,
            @selector(objectiveCEntryForClass:selector:classMethod:)
        );
        Method replacement = class_getInstanceMethod(
            meta,
            @selector(af_strict_objectiveCEntryForClass:selector:classMethod:)
        );
        if (original && replacement) {
            method_exchangeImplementations(original, replacement);
        }
    });
}

+ (FLEXHookEntry *)af_strict_objectiveCEntryForClass:(Class)targetClass
                                            selector:(SEL)selector
                                         classMethod:(BOOL)classMethod {
    FLEXHookEntry *entry = [self
        af_strict_objectiveCEntryForClass:targetClass
                                 selector:selector
                              classMethod:classMethod];
    if (!entry || !targetClass || !selector) return nil;

    Method method = classMethod
        ? class_getClassMethod(targetClass, selector)
        : class_getInstanceMethod(targetClass, selector);
    FLEXHookABI exactABI = FLEXStrictABIForMethod(method);
    if (exactABI == FLEXHookABIUnknown) {
        return nil;
    }
    entry.abi = exactABI;
    entry.hookable = entry.available;
    NSMutableDictionary *locator = [entry.locator mutableCopy] ?: [NSMutableDictionary dictionary];
    locator[@"abiEvidence"] = @"objc-type-encoding-exact-B";
    entry.locator = locator.copy;
    return entry;
}

@end
