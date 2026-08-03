#import <Foundation/Foundation.h>

#import "../libflex/AllFLEXing/FLEXRuntimeSearchSemantics.h"

static BOOL FLEXTestMatches(NSArray *fields, NSString *query) {
    NSArray<NSString *> *candidateTokens =
        FLEXRuntimeSearchSemanticTokensForValues(fields);
    NSArray<NSString *> *queryTokens = FLEXRuntimeSearchQueryTokens(query);

    for (NSString *queryToken in queryTokens) {
        BOOL matched = NO;
        for (NSString *candidate in candidateTokens) {
            if ([candidate containsString:queryToken]) {
                matched = YES;
                break;
            }
        }
        if (!matched) {
            return NO;
        }
    }
    return YES;
}

static void FLEXRequire(BOOL condition, NSString *message) {
    if (condition) {
        return;
    }
    fprintf(stderr, "runtime search semantics failure: %s\n", message.UTF8String);
    exit(1);
}

int main(void) {
    @autoreleasepool {
        NSArray *manager = @[@"FBConfigManager"];
        FLEXRequire(FLEXTestMatches(manager, @"fbconfigmanager"),
                    @"compact lowercase class name");
        FLEXRequire(FLEXTestMatches(manager, @"fb config manager"),
                    @"spaced class name");
        FLEXRequire(FLEXTestMatches(manager, @"FBConfigManager"),
                    @"original CamelCase class name");
        FLEXRequire(FLEXTestMatches(manager, @"fb_config_manager"),
                    @"underscore-separated class name");
        FLEXRequire(FLEXTestMatches(manager, @"configmanager"),
                    @"compact suffix across CamelCase boundaries");
        FLEXRequire(FLEXTestMatches(manager, @"manager fb"),
                    @"AND terms in any order");

        NSArray *employee = @[@"is_employee_enable"];
        FLEXRequire(FLEXTestMatches(employee, @"employee enable"),
                    @"separated snake_case terms");
        FLEXRequire(FLEXTestMatches(employee, @"employeeenable"),
                    @"compact snake_case terms");
        FLEXRequire(!FLEXTestMatches(employee, @"employee disabled"),
                    @"unrelated term must not match");

        NSArray<NSString *> *tokens =
            FLEXRuntimeSearchSemanticTokensForValues(manager);
        FLEXRequire([tokens containsObject:@"fb"], @"split acronym token");
        FLEXRequire([tokens containsObject:@"config"], @"split middle token");
        FLEXRequire([tokens containsObject:@"manager"], @"split final token");
        FLEXRequire([tokens containsObject:@"fbconfigmanager"],
                    @"field-scoped compact token");

        printf("runtime search semantics: OK\n");
    }
    return 0;
}
