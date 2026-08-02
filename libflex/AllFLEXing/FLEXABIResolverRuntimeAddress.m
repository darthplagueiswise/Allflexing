#import "FLEXABIResolver.h"

#import <objc/runtime.h>

static void FLEXABIExchangeClassMethods(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getClassMethod(cls, original);
    Method replacementMethod = class_getClassMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

@implementation FLEXABIResolver (AllFLEXingRuntimeAddressBridge)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLEXABIExchangeClassMethods(
            FLEXABIResolver.class,
            @selector(resolveEntry:completion:),
            @selector(af_image_resolveEntry:completion:)
        );
    });
}

+ (void)af_image_resolveEntry:(FLEXHookEntry *)entry
                   completion:(void (^)(FLEXABIResolution *resolution))completion {
    if ((entry.surface == FLEXHookSurfaceCInline ||
         entry.surface == FLEXHookSurfaceCImport) &&
        ![entry.locator[@"address"] isKindOfClass:NSNumber.class]) {
        id rawAddress = entry.locator[@"runtimeAddress"];
        unsigned long long address = 0;
        if ([rawAddress isKindOfClass:NSNumber.class]) {
            address = [rawAddress unsignedLongLongValue];
        } else if ([rawAddress isKindOfClass:NSString.class]) {
            address = strtoull([rawAddress UTF8String], NULL, 0);
        }
        if (address) {
            FLEXHookEntry *bridged = [entry copy];
            NSMutableDictionary *locator = [bridged.locator mutableCopy] ?: [NSMutableDictionary dictionary];
            locator[@"address"] = @(address);
            bridged.locator = locator.copy;
            [self af_image_resolveEntry:bridged completion:completion];
            return;
        }
    }
    [self af_image_resolveEntry:entry completion:completion];
}

@end
