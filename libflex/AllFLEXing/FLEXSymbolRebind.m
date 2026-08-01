#import "FLEXSymbolRebind.h"

#import "flex_fishhook.h"
#import <dlfcn.h>

@implementation FLEXSymbolRebind

+ (NSString *)retainedSymbolName:(NSString *)symbol {
    static NSMutableSet<NSString *> *symbolNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        symbolNames = [NSMutableSet set];
    });

    @synchronized (symbolNames) {
        NSString *retained = [symbolNames member:symbol];
        if (!retained) {
            retained = [symbol copy];
            [symbolNames addObject:retained];
        }
        return retained;
    }
}

+ (BOOL)rebindSymbol:(NSString *)symbol
          replacement:(void *)replacement
             original:(void **)original {
    if (symbol.length == 0 || !replacement) {
        return NO;
    }

    NSString *normalized = [symbol hasPrefix:@"_"]
        ? [symbol substringFromIndex:1]
        : symbol;
    normalized = [self retainedSymbolName:normalized];

    if (original && !*original) {
        *original = dlsym(RTLD_DEFAULT, normalized.UTF8String);
    }

    struct rebinding binding = {
        .name = normalized.UTF8String,
        .replacement = replacement,
        .replaced = original,
    };
    int status = flex_rebind_symbols(&binding, 1);
    if (status != 0) {
        NSLog(@"[AllFLEXing] flex_rebind_symbols failed (%d) for %@", status, normalized);
    }
    return status == 0;
}

+ (NSString *)backendDescription {
    return @"embedded FLEX flex_fishhook";
}

@end
