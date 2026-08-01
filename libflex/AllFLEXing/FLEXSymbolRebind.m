#import "FLEXSymbolRebind.h"

#import "flex_fishhook.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>

NSUInteger const FLEXEmbeddedFishhookABIVersion = 1;

BOOL FLEXEmbeddedFishhookAvailable(void) {
    // Taking both addresses creates a strong link-time contract with the
    // namespaced implementation compiled into this Mach-O. The build cannot
    // succeed by accidentally resolving fishhook from the host process.
    static void *const implementations[] = {
        (void *)&flex_rebind_symbols,
        (void *)&flex_rebind_symbols_image,
    };
    return implementations[0] != NULL && implementations[1] != NULL;
}

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
    if (!FLEXEmbeddedFishhookAvailable()) {
        return NO;
    }
    int status = flex_rebind_symbols(&binding, 1);
    if (status != 0) {
        NSLog(@"[AllFLEXing] flex_rebind_symbols failed (%d) for %@", status, normalized);
    }
    return status == 0;
}

+ (BOOL)rebindSymbol:(NSString *)symbol
         inImageNamed:(NSString *)imageName
          replacement:(void *)replacement
             original:(void **)original {
    if (imageName.length == 0) {
        return [self rebindSymbol:symbol replacement:replacement original:original];
    }
    if (symbol.length == 0 || !replacement) {
        return NO;
    }

    NSString *normalized = [symbol hasPrefix:@"_"]
        ? [symbol substringFromIndex:1]
        : symbol;
    normalized = [self retainedSymbolName:normalized];

    const struct mach_header *header = NULL;
    intptr_t slide = 0;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *rawPath = _dyld_get_image_name(index);
        if (!rawPath) {
            continue;
        }
        NSString *path = [NSString stringWithUTF8String:rawPath];
        if ([path isEqualToString:imageName] ||
            [path.lastPathComponent isEqualToString:imageName.lastPathComponent]) {
            header = _dyld_get_image_header(index);
            slide = _dyld_get_image_vmaddr_slide(index);
            break;
        }
    }
    if (!header) {
        return NO;
    }

    if (original) {
        *original = NULL;
    }
    struct rebinding binding = {
        .name = normalized.UTF8String,
        .replacement = replacement,
        .replaced = original,
    };
    if (!FLEXEmbeddedFishhookAvailable()) {
        return NO;
    }
    int status = flex_rebind_symbols_image((void *)header, slide, &binding, 1);
    if (status != 0) {
        NSLog(@"[AllFLEXing] image fishhook failed (%d) for %@ in %@",
            status, normalized, imageName);
        return NO;
    }
    return original == NULL || *original != NULL;
}

+ (NSString *)backendDescription {
    return [NSString stringWithFormat:@"embedded FLEX flex_fishhook ABI %lu",
        (unsigned long)FLEXEmbeddedFishhookABIVersion];
}

@end
