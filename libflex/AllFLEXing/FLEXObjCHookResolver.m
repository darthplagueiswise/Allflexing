#import "FLEXObjCHookResolver.h"

#import "FLEXHookPersistence.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"
#import "FLEXRuntimeHostIdentity.h"
#import "FLEXMethod.h"
#import "FLEXProperty.h"

#import <objc/runtime.h>
#import <string.h>

static const char *FLEXHookSkipObjCQualifiers(const char *type) {
    if (!type) {
        return "";
    }
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static BOOL FLEXHookSelectorIsSafeCandidate(SEL selector) {
    const char *name = selector ? sel_getName(selector) : NULL;
    if (!name || !*name) {
        return NO;
    }
    return strncmp(name, "set", 3) != 0 &&
           strncmp(name, "init", 4) != 0 &&
           strcmp(name, "dealloc") != 0 &&
           strcmp(name, "isEqual:") != 0 &&
           strcmp(name, "respondsToSelector:") != 0;
}

static NSUInteger FLEXHookSelectorArgumentCount(NSString *selectorName) {
    NSUInteger count = 0;
    for (NSUInteger index = 0; index < selectorName.length; index++) {
        if ([selectorName characterAtIndex:index] == ':') {
            count++;
        }
    }
    return count;
}

/// FLEX renders method rows by pairing selector components with the argument
/// count supplied by the Objective-C runtime. Some runtime-generated or
/// malformed methods expose a selector and type encoding that disagree. Those
/// methods are valid enough to exist in the runtime, but not safe to render or
/// hook through FLEX's metadata UI. Reject them before they enter the browser.
static BOOL FLEXHookMethodMetadataIsStructurallySafe(FLEXMethod *method) {
    Method runtimeMethod = method.objc_method;
    if (!runtimeMethod || !method.selector || method.selectorString.length == 0) {
        return NO;
    }

    const char *encoding = method_getTypeEncoding(runtimeMethod);
    if (!encoding || !*encoding || !method.signature) {
        return NO;
    }

    unsigned int argumentCount = method_getNumberOfArguments(runtimeMethod);
    if (argumentCount < 2 || method.signature.numberOfArguments < argumentCount) {
        return NO;
    }

    NSUInteger explicitArguments = argumentCount - 2;
    if (FLEXHookSelectorArgumentCount(method.selectorString) != explicitArguments) {
        return NO;
    }

    // Validate every runtime argument through the C runtime only. This avoids
    // invoking FLEX's pretty-printer while deciding whether a row is safe.
    for (unsigned int index = 0; index < argumentCount; index++) {
        char argumentType[128] = {0};
        method_getArgumentType(runtimeMethod, index, argumentType, sizeof(argumentType));
        if (!*FLEXHookSkipObjCQualifiers(argumentType)) {
            return NO;
        }
    }

    char selfType[16] = {0};
    char commandType[16] = {0};
    method_getArgumentType(runtimeMethod, 0, selfType, sizeof(selfType));
    method_getArgumentType(runtimeMethod, 1, commandType, sizeof(commandType));
    const char *selfCode = FLEXHookSkipObjCQualifiers(selfType);
    const char *commandCode = FLEXHookSkipObjCQualifiers(commandType);
    if ((*selfCode != '@' && *selfCode != '#') || *commandCode != ':') {
        return NO;
    }

    return YES;
}

static FLEXHookABI FLEXHookABIForFLEXMethod(FLEXMethod *method) {
    Method runtimeMethod = method.objc_method;
    if (!runtimeMethod || !FLEXHookMethodMetadataIsStructurallySafe(method)) {
        return FLEXHookABIUnknown;
    }

    char returnType[32] = {0};
    method_getReturnType(runtimeMethod, returnType, sizeof(returnType));
    const char *returnCode = FLEXHookSkipObjCQualifiers(returnType);

    // arm64 Objective-C BOOL is encoded as B. c/C are char types and must not
    // be presented as boolean hooks.
    if (*returnCode != 'B') {
        return FLEXHookABIUnknown;
    }

    unsigned int argumentCount = method_getNumberOfArguments(runtimeMethod);
    if (argumentCount == 2) {
        return FLEXHookABIObjCBoolNoArguments;
    }
    if (argumentCount != 3) {
        return FLEXHookABIUnknown;
    }

    char argumentType[64] = {0};
    method_getArgumentType(runtimeMethod, 2, argumentType, sizeof(argumentType));
    const char *argumentCode = FLEXHookSkipObjCQualifiers(argumentType);
    if (*argumentCode == '@' || *argumentCode == '#' || *argumentCode == ':') {
        return FLEXHookABIObjCBoolObjectArgument;
    }
    if (strchr("BcCsSiIlLqQ^*", *argumentCode)) {
        return FLEXHookABIObjCBoolIntegerArgument;
    }
    return FLEXHookABIUnknown;
}

static NSString *FLEXHookStableObjectiveCIdentifier(NSString *image,
                                                      NSString *className,
                                                      NSString *selector,
                                                      BOOL classMethod) {
    return [NSString stringWithFormat:@"objc|%@|%@|%@|%@",
        image.lastPathComponent ?: @"unknown",
        className ?: @"",
        classMethod ? @"+" : @"-",
        selector ?: @""];
}

@implementation FLEXObjCHookResolver

+ (BOOL)canRepresentMethod:(FLEXMethod *)method
              inClassNamed:(NSString *)className {
    Class targetClass = NSClassFromString(className);
    if (!targetClass || ![method isKindOfClass:FLEXMethod.class]) {
        return NO;
    }
    if (!FLEXHookMethodMetadataIsStructurallySafe(method) ||
        !FLEXHookSelectorIsSafeCandidate(method.selector) ||
        FLEXHookABIForFLEXMethod(method) == FLEXHookABIUnknown) {
        return NO;
    }

    const char *rawImage = class_getImageName(targetClass);
    NSString *image = rawImage ? [NSString stringWithUTF8String:rawImage] : nil;
    return FLEXRuntimeImageIsAllowedHostImage(image);
}

+ (FLEXHookEntry *)entryForMethod:(FLEXMethod *)method
                      targetClass:(Class)targetClass {
    if (!targetClass || ![method isKindOfClass:FLEXMethod.class]) {
        return nil;
    }

    NSString *className = NSStringFromClass(targetClass);
    if (![self canRepresentMethod:method inClassNamed:className]) {
        return nil;
    }

    FLEXHookABI abi = FLEXHookABIForFLEXMethod(method);
    BOOL classMethod = !method.isInstanceMethod;
    NSString *selectorName = method.selectorString;
    const char *rawImage = class_getImageName(targetClass);
    NSString *image = rawImage
        ? [NSString stringWithUTF8String:rawImage]
        : @"Created at Runtime";
    NSString *encoding = method.typeEncoding ?: @"";

    BOOL providerAvailable = FLEXMSHookMessageProviderAvailable();
    BOOL engineEnabled = FLEXFlag(@"engine.objc_ellekit");

    FLEXHookEntry *entry = [FLEXHookEntry new];
    entry.identifier = FLEXHookStableObjectiveCIdentifier(
        image, className, selectorName, classMethod
    );
    entry.title = [method debugNameGivenClassName:className];
    entry.detail = [NSString stringWithFormat:@"%@ · %@",
        FLEXHookABIName(abi), encoding];
    entry.imageName = image.lastPathComponent ?: image;
    entry.surface = FLEXHookSurfaceObjectiveC;
    entry.backend = FLEXHookBackendObjectiveCElleKit;
    entry.abi = abi;
    entry.locator = FLEXLocatorByAddingCurrentHostIdentity(@{
        @"class": className ?: @"",
        @"selector": selectorName ?: @"",
        @"classMethod": @(classMethod),
        @"encoding": encoding,
        @"image": image ?: @"",
    });
    entry.available = providerAvailable;
    entry.hookable = providerAvailable && engineEnabled;
    entry.stale = NO;
    if (!providerAvailable) {
        entry.lastError = @"Substrate-compatible provider unavailable";
    } else if (!engineEnabled) {
        entry.lastError = @"Objective-C/ElleKit engine is disabled";
    }
    return entry;
}

+ (FLEXHookEntry *)entryForProperty:(FLEXProperty *)property
                        targetClass:(Class)targetClass {
    if (!targetClass || ![property isKindOfClass:FLEXProperty.class] ||
        !property.likelyGetter) {
        return nil;
    }

    BOOL classMethod = property.isClassProperty;
    Method runtimeMethod = classMethod
        ? class_getClassMethod(targetClass, property.likelyGetter)
        : class_getInstanceMethod(targetClass, property.likelyGetter);
    FLEXMethod *method = runtimeMethod
        ? [FLEXMethod method:runtimeMethod isInstanceMethod:!classMethod]
        : nil;
    return method ? [self entryForMethod:method targetClass:targetClass] : nil;
}

@end
