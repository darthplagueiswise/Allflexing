#import "FLEXABIResolver.h"

@implementation FLEXABIResolver (AllFLEXingExactCatalog)

+ (FLEXHookABI)exactKnownABIForSymbol:(NSString *)symbol {
    NSString *normalized = [symbol hasPrefix:@"_"]
        ? [symbol substringFromIndex:1] : symbol;
    static NSDictionary<NSString *, NSNumber *> *catalog;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Exact signature catalog only. Spelling patterns, prefixes and natural
        // language never classify an arbitrary runtime symbol.
        catalog = @{
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
    NSNumber *profile = catalog[normalized ?: @""];
    return profile ? (FLEXHookABI)profile.integerValue : FLEXHookABIUnknown;
}

@end
