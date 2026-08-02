#import <objc/runtime.h>

#import <stdio.h>
#import <stdlib.h>
#import <string.h>

__attribute__((objc_root_class))
@interface AllFLEXingRetainlessRoot
+ (BOOL)runtimeProbe;
@end

@implementation AllFLEXingRetainlessRoot
+ (BOOL)runtimeProbe {
    return YES;
}
@end

int main(void) {
    Class expected = objc_getClass("AllFLEXingRetainlessRoot");
    if (!expected) {
        fprintf(stderr, "root class was not registered\n");
        return 1;
    }

    __block BOOL found = NO;
    __block BOOL methodFound = NO;
    objc_enumerateClasses(
        NULL,
        "AllFLEXingRetainlessRoot",
        NULL,
        Nil,
        ^(Class candidate, BOOL *stop) {
            if (candidate != expected) {
                return;
            }

            const char *name = class_getName(candidate);
            if (!name || strcmp(name, "AllFLEXingRetainlessRoot") != 0) {
                fprintf(stderr, "class_getName returned an unexpected value\n");
                *stop = YES;
                return;
            }

            unsigned int count = 0;
            Class metaClass = object_getClass(candidate);
            Method *methods = class_copyMethodList(metaClass, &count);
            for (unsigned int index = 0; index < count; index++) {
                SEL selector = method_getName(methods[index]);
                const char *selectorName = sel_getName(selector);
                if (selectorName && strcmp(selectorName, "runtimeProbe") == 0) {
                    methodFound = YES;
                    break;
                }
            }
            free(methods);
            found = YES;
            *stop = YES;
        }
    );

    if (!found || !methodFound) {
        fprintf(stderr, "image-scoped runtime enumeration missed the root class or method\n");
        return 2;
    }

    puts("Objective-C root-class enumeration: OK");
    return 0;
}
