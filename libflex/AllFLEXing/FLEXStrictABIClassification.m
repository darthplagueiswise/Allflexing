#import "FLEXABIResolver.h"
#import "FLEXRuntimeScanner.h"

#import <objc/runtime.h>

const char *FLEXStrictABIClassificationVersion =
    "AllFLEXing strict Objective-C BOOL encoding ABI 1";

static const char *FLEXStrictSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static BOOL FLEXStrictObjectiveCMethodIsSupported(Method method,
                                                   NSString **reason) {
    if (!method) {
        if (reason) *reason = @"Objective-C method is no longer present";
        return NO;
    }

    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *returnCode = FLEXStrictSkipQualifiers(returnType);
    // On arm64, only 'B' proves C++ bool / modern Objective-C BOOL. 'c' and
    // 'C' are plain 8-bit integers and must never be promoted automatically.
    if (*returnCode != 'B') {
        if (reason) {
            *reason = [NSString stringWithFormat:
                @"Return encoding '%s' is not an exact BOOL ('B')", returnCode];
        }
        return NO;
    }

    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount == 2) {
        return YES;
    }
    if (argumentCount != 3) {
        if (reason) {
            *reason = [NSString stringWithFormat:
                @"%u explicit arguments are outside the supported BOOL ABI profiles",
                argumentCount >= 2 ? argumentCount - 2 : 0];
        }
        return NO;
    }

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *argumentCode = FLEXStrictSkipQualifiers(argumentType);
    if (*argumentCode == '@' || *argumentCode == '#' || *argumentCode == ':') {
        return YES;
    }
    // Integer profiles are scalar-only. Pointers ('^', '*'), structs, unions,
    // vectors and floating-point values remain inspection-only.
    if (strchr("BcCsSiIlLqQ", *argumentCode)) {
        return YES;
    }

    if (reason) {
        *reason = [NSString stringWithFormat:
            @"Argument encoding '%s' is not a supported object or integer scalar",
            argumentCode];
    }
    return NO;
}

static Method FLEXStrictMethodForEntry(FLEXHookEntry *entry) {
    NSString *className = entry.locator[@"class"];
    NSString *selectorName = entry.locator[@"selector"];
    BOOL classMethod = [entry.locator[@"classMethod"] boolValue];
    Class targetClass = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (!targetClass || !selector) return NULL;
    return classMethod
        ? class_getClassMethod(targetClass, selector)
        : class_getInstanceMethod(targetClass, selector);
}

static void FLEXExchangeClassMethods(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getClassMethod(cls, original);
    Method replacementMethod = class_getClassMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

@implementation FLEXRuntimeScanner (AllFLEXingStrictABI)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLEXExchangeClassMethods(
            FLEXRuntimeScanner.class,
            @selector(objectiveCEntryForClass:selector:classMethod:),
            @selector(af_strict_objectiveCEntryForClass:selector:classMethod:)
        );
    });
}

+ (FLEXHookEntry *)af_strict_objectiveCEntryForClass:(Class)targetClass
                                            selector:(SEL)selector
                                         classMethod:(BOOL)classMethod {
    Method method = classMethod
        ? class_getClassMethod(targetClass, selector)
        : class_getInstanceMethod(targetClass, selector);
    NSString *reason = nil;
    if (!FLEXStrictObjectiveCMethodIsSupported(method, &reason)) {
        return nil;
    }

    FLEXHookEntry *entry = [self
        af_strict_objectiveCEntryForClass:targetClass
                                 selector:selector
                              classMethod:classMethod];
    if (!entry) return nil;

    NSMutableDictionary *locator = [entry.locator mutableCopy] ?: [NSMutableDictionary dictionary];
    locator[@"abiEvidence"] = @"objc-type-encoding-exact-B";
    locator[@"abiConfidence"] = @"exact";
    entry.locator = locator.copy;
    return entry;
}

@end

@implementation FLEXABIResolver (AllFLEXingStrictABI)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLEXExchangeClassMethods(
            FLEXABIResolver.class,
            @selector(resolveEntry:completion:),
            @selector(af_strict_resolveEntry:completion:)
        );
    });
}

+ (void)af_strict_resolveEntry:(FLEXHookEntry *)entry
                    completion:(void (^)(FLEXABIResolution *resolution))completion {
    if (entry.surface != FLEXHookSurfaceObjectiveC) {
        [self af_strict_resolveEntry:entry completion:completion];
        return;
    }

    NSString *reason = nil;
    Method method = FLEXStrictMethodForEntry(entry);
    if (FLEXStrictObjectiveCMethodIsSupported(method, &reason)) {
        [self af_strict_resolveEntry:entry completion:completion];
        return;
    }

    FLEXABIResolution *resolution = [FLEXABIResolution new];
    resolution.abi = FLEXHookABIUnknown;
    resolution.backend = FLEXHookBackendNone;
    resolution.confidence = FLEXABIResolutionConfidenceUnknown;
    resolution.symbolResolved = method != NULL;
    resolution.canAutoApply = NO;
    resolution.summary = @"Unknown confidence · Inspection only";
    resolution.evidence = @[
        reason ?: @"The runtime encoding does not prove a supported BOOL ABI.",
        @"Name-based heuristics never authorize an Objective-C hook."
    ];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(resolution);
    });
}

@end
