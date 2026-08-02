#import "FLEXRuntimeSearchSemantics.h"

const char *FLEXRuntimeSearchSemanticsABIVersion =
    "AllFLEXing field-scoped compact-token search ABI 1";

NSString *FLEXRuntimeSearchNormalizedText(NSString *source) {
    if (!source.length) {
        return @"";
    }

    NSMutableString *output = [NSMutableString stringWithCapacity:source.length + 8];
    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSCharacterSet *upper = NSCharacterSet.uppercaseLetterCharacterSet;
    NSCharacterSet *lower = NSCharacterSet.lowercaseLetterCharacterSet;

    for (NSUInteger index = 0; index < source.length; index++) {
        unichar current = [source characterAtIndex:index];
        BOOL alphanumeric = [letters characterIsMember:current] ||
                            [digits characterIsMember:current];
        if (!alphanumeric) {
            if (output.length && [output characterAtIndex:output.length - 1] != ' ') {
                [output appendString:@" "];
            }
            continue;
        }

        if ([upper characterIsMember:current] && index > 0 && output.length &&
            [output characterAtIndex:output.length - 1] != ' ') {
            unichar previous = [source characterAtIndex:index - 1];
            BOOL boundary = [lower characterIsMember:previous] ||
                            [digits characterIsMember:previous];
            if (!boundary && index + 1 < source.length) {
                unichar next = [source characterAtIndex:index + 1];
                boundary = [upper characterIsMember:previous] &&
                           [lower characterIsMember:next];
            }
            if (boundary) {
                [output appendString:@" "];
            }
        }
        [output appendFormat:@"%C", current];
    }

    NSString *folded = [output stringByFoldingWithOptions:
        (NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch |
         NSWidthInsensitiveSearch)
        locale:NSLocale.currentLocale];
    NSArray<NSString *> *parts = [folded.lowercaseString
        componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts) {
        if (part.length) {
            [tokens addObject:part];
        }
    }
    return [tokens componentsJoinedByString:@" "];
}

NSArray<NSString *> *FLEXRuntimeSearchQueryTokens(NSString *source) {
    NSString *normalized = FLEXRuntimeSearchNormalizedText(source);
    return normalized.length
        ? [normalized componentsSeparatedByString:@" "]
        : @[];
}

static NSString *FLEXRuntimeSearchStringValue(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        return [value stringValue];
    }
    return nil;
}

NSArray<NSString *> *FLEXRuntimeSearchSemanticTokensForValues(NSArray *values) {
    NSMutableOrderedSet<NSString *> *semanticTokens = [NSMutableOrderedSet orderedSet];

    for (id value in values ?: @[]) {
        NSString *field = FLEXRuntimeSearchStringValue(value);
        if (!field.length) {
            continue;
        }

        NSArray<NSString *> *fieldTokens = FLEXRuntimeSearchQueryTokens(field);
        for (NSString *token in fieldTokens) {
            if (token.length) {
                [semanticTokens addObject:token];
            }
        }

        if (fieldTokens.count > 1) {
            NSString *compact = [fieldTokens componentsJoinedByString:@""];
            if (compact.length) {
                [semanticTokens addObject:compact];
            }
        }
    }

    return semanticTokens.array;
}
