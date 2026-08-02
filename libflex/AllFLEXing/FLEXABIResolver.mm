#import "FLEXABIResolver.h"

#import "FLEXHooking.h"

#import <cxxabi.h>
#import <dlfcn.h>
#import <objc/runtime.h>

const char *FLEXABIResolverABIVersion =
    "AllFLEXing evidence-based ABI resolver ABI 1";

@implementation FLEXABIResolution
@end

static dispatch_queue_t FLEXABIResolverQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.allflexing.abi-resolver",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_USER_INITIATED,
                0
            )
        );
    });
    return queue;
}

static const char *FLEXSkipTypeQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static FLEXHookABI FLEXObjectiveCABI(Method method) {
    if (!method) return FLEXHookABIUnknown;
    char returnType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *returnCode = FLEXSkipTypeQualifiers(returnType);
    if (*returnCode != 'B' && *returnCode != 'c' && *returnCode != 'C') {
        return FLEXHookABIUnknown;
    }

    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return FLEXHookABIObjCBoolNoArguments;
    if (count != 3) return FLEXHookABIUnknown;

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *argumentCode = FLEXSkipTypeQualifiers(argumentType);
    if (*argumentCode == '@' || *argumentCode == '#' || *argumentCode == ':') {
        return FLEXHookABIObjCBoolObjectArgument;
    }
    if (strchr("BcCsSiIlLqQ^*", *argumentCode)) {
        return FLEXHookABIObjCBoolIntegerArgument;
    }
    return FLEXHookABIUnknown;
}

static NSString *FLEXNormalizedSymbol(NSString *symbol) {
    return [symbol hasPrefix:@"_"] ? [symbol substringFromIndex:1] : symbol;
}

static NSString *FLEXDemangleSymbol(NSString *symbol) {
    if (!symbol.length) return @"";
    NSString *normalized = FLEXNormalizedSymbol(symbol);
    int status = 0;
    char *demangled = abi::__cxa_demangle(normalized.UTF8String, NULL, NULL, &status);
    if (!demangled || status != 0) {
        if (demangled) free(demangled);
        return @"";
    }
    NSString *result = [NSString stringWithUTF8String:demangled] ?: @"";
    free(demangled);
    return result;
}

static NSDictionary<NSString *, NSNumber *> *FLEXKnownCSignatures(void) {
    static NSDictionary<NSString *, NSNumber *> *signatures;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        signatures = @{
            @"arc4random": @(FLEXHookABICInt64NoArguments),
            @"getpid": @(FLEXHookABICInt64NoArguments),
            @"getppid": @(FLEXHookABICInt64NoArguments),
            @"getuid": @(FLEXHookABICInt64NoArguments),
            @"geteuid": @(FLEXHookABICInt64NoArguments),
            @"getgid": @(FLEXHookABICInt64NoArguments),
            @"getegid": @(FLEXHookABICInt64NoArguments),
            @"mach_absolute_time": @(FLEXHookABICInt64NoArguments),
            @"MGGetBoolAnswer": @(FLEXHookABICBoolPointerArgument),
        };
    });
    return signatures;
}

static BOOL FLEXNameSuggestsBoolean(NSString *symbol) {
    NSString *name = FLEXNormalizedSymbol(symbol).lowercaseString;
    NSArray<NSString *> *tokens = @[
        @"isenabled", @"isavailable", @"isvalid", @"issupported",
        @"has", @"can", @"should", @"enabled", @"available",
        @"valid", @"supports", @"allow", @"eligible"
    ];
    for (NSString *token in tokens) {
        if ([name containsString:token]) return YES;
    }
    return NO;
}

static NSInteger FLEXDemangledParameterCount(NSString *demangled,
                                             BOOL *containsPointer) {
    if (containsPointer) *containsPointer = NO;
    NSRange open = [demangled rangeOfString:@"("];
    NSRange close = [demangled rangeOfString:@")" options:NSBackwardsSearch];
    if (open.location == NSNotFound || close.location == NSNotFound ||
        close.location < NSMaxRange(open)) {
        return NSNotFound;
    }
    NSString *arguments = [[demangled substringWithRange:NSMakeRange(
        NSMaxRange(open), close.location - NSMaxRange(open))]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!arguments.length || [arguments isEqualToString:@"void"]) return 0;

    NSInteger depth = 0;
    NSInteger count = 1;
    for (NSUInteger index = 0; index < arguments.length; index++) {
        unichar character = [arguments characterAtIndex:index];
        if (character == '<' || character == '(' || character == '[') depth++;
        else if (character == '>' || character == ')' || character == ']') depth--;
        else if (character == ',' && depth == 0) count++;
    }
    if (containsPointer) {
        *containsPointer = [arguments containsString:@"*"] ||
                           [arguments containsString:@"&"] ||
                           [arguments containsString:@" id"];
    }
    return count;
}

static void *FLEXResolveSymbolAddress(NSString *symbol, NSString *imagePath) {
    NSString *normalized = FLEXNormalizedSymbol(symbol);
    if (!normalized.length) return NULL;

    void *handle = RTLD_DEFAULT;
    if (imagePath.length) {
        handle = dlopen(imagePath.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
        if (!handle) handle = RTLD_DEFAULT;
    }
    void *address = dlsym(handle, normalized.UTF8String);
    if (handle != RTLD_DEFAULT && handle) dlclose(handle);
    return address;
}

@implementation FLEXABIResolver

+ (NSString *)confidenceName:(FLEXABIResolutionConfidence)confidence {
    switch (confidence) {
        case FLEXABIResolutionConfidenceExact: return @"Exact";
        case FLEXABIResolutionConfidenceStrong: return @"Strong";
        case FLEXABIResolutionConfidenceHeuristic: return @"Heuristic";
        case FLEXABIResolutionConfidenceUnknown: return @"Unknown";
    }
}

+ (void)resolveEntry:(FLEXHookEntry *)entry
          completion:(void (^)(FLEXABIResolution *resolution))completion {
    FLEXHookEntry *snapshot = [entry copy];
    dispatch_async(FLEXABIResolverQueue(), ^{
        FLEXABIResolution *resolution = [FLEXABIResolution new];
        resolution.abi = FLEXHookABIUnknown;
        resolution.backend = FLEXHookBackendNone;
        resolution.confidence = FLEXABIResolutionConfidenceUnknown;
        NSMutableArray<NSString *> *evidence = [NSMutableArray array];

        if (snapshot.surface == FLEXHookSurfaceObjectiveC) {
            NSString *className = snapshot.locator[@"class"];
            NSString *selectorName = snapshot.locator[@"selector"];
            BOOL classMethod = [snapshot.locator[@"classMethod"] boolValue];
            Class targetClass = NSClassFromString(className);
            SEL selector = NSSelectorFromString(selectorName);
            Method method = classMethod
                ? class_getClassMethod(targetClass, selector)
                : class_getInstanceMethod(targetClass, selector);
            FLEXHookABI abi = FLEXObjectiveCABI(method);
            if (abi != FLEXHookABIUnknown) {
                resolution.abi = abi;
                resolution.backend = FLEXHookBackendObjectiveCElleKit;
                resolution.confidence = FLEXABIResolutionConfidenceExact;
                resolution.symbolResolved = method != NULL;
                resolution.canAutoApply = FLEXMSHookMessageProviderAvailable();
                [evidence addObject:@"Objective-C runtime type encoding is authoritative."];
                const char *encoding = method ? method_getTypeEncoding(method) : NULL;
                if (encoding) {
                    [evidence addObject:[NSString stringWithFormat:@"Encoding: %s", encoding]];
                }
            }
        } else {
            NSString *symbol = snapshot.locator[@"symbol"] ?: snapshot.title;
            NSString *imagePath = snapshot.locator[@"image"];
            NSUInteger bindSlots = [snapshot.locator[@"bindSlots"] unsignedIntegerValue];
            void *address = FLEXResolveSymbolAddress(symbol, imagePath);
            resolution.symbolResolved = address != NULL;

            if (bindSlots > 0) {
                resolution.backend = FLEXHookBackendFishhook;
                [evidence addObject:[NSString stringWithFormat:
                    @"%lu imported bind slot%@ confirm fishhook eligibility.",
                    (unsigned long)bindSlots, bindSlots == 1 ? @"" : @"s"]];
            } else if (address && FLEXMSHookFunctionProviderAvailable()) {
                resolution.backend = FLEXHookBackendInlineElleKit;
                [evidence addObject:@"The symbol resolves to a live address; inline MSHookFunction is available."];
            } else {
                [evidence addObject:@"No confirmed bind slot or live inline address was found."];
            }

            NSString *normalized = FLEXNormalizedSymbol(symbol);
            NSNumber *known = FLEXKnownCSignatures()[normalized];
            if (known) {
                resolution.abi = (FLEXHookABI)known.integerValue;
                resolution.confidence = FLEXABIResolutionConfidenceExact;
                [evidence addObject:@"Matched the built-in verified public-signature database."];
            } else {
                NSString *demangled = FLEXDemangleSymbol(symbol);
                if (demangled.length) {
                    [evidence addObject:[@"Demangled: " stringByAppendingString:demangled]];
                    BOOL pointerArgument = NO;
                    NSInteger parameterCount = FLEXDemangledParameterCount(
                        demangled, &pointerArgument);
                    if (FLEXNameSuggestsBoolean(normalized) && parameterCount == 0) {
                        resolution.abi = FLEXHookABICBoolNoArguments;
                        resolution.confidence = FLEXABIResolutionConfidenceStrong;
                        [evidence addObject:@"Demangled signature has no parameters and the symbol name indicates a Boolean result."];
                    } else if (FLEXNameSuggestsBoolean(normalized) &&
                               parameterCount == 1 && pointerArgument) {
                        resolution.abi = FLEXHookABICBoolPointerArgument;
                        resolution.confidence = FLEXABIResolutionConfidenceStrong;
                        [evidence addObject:@"Demangled signature has one pointer-like parameter and the symbol name indicates a Boolean result."];
                    }
                } else if (FLEXNameSuggestsBoolean(normalized)) {
                    resolution.confidence = FLEXABIResolutionConfidenceHeuristic;
                    [evidence addObject:@"The name suggests a Boolean result, but argument count is not encoded in a plain C symbol."];
                }
            }

            resolution.canAutoApply = resolution.abi != FLEXHookABIUnknown &&
                resolution.backend != FLEXHookBackendNone &&
                resolution.confidence >= FLEXABIResolutionConfidenceStrong;
        }

        resolution.evidence = evidence.copy;
        resolution.summary = [NSString stringWithFormat:@"%@ confidence · %@ · %@",
            [self confidenceName:resolution.confidence],
            FLEXHookABIName(resolution.abi),
            FLEXHookBackendName(resolution.backend)];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(resolution);
        });
    });
}

@end
