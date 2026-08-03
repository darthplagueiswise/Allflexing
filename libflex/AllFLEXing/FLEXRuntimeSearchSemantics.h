#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const char *FLEXRuntimeSearchSemanticsABIVersion;

/// Normalizes separators, diacritics and CamelCase/acronym boundaries.
FOUNDATION_EXPORT NSString *FLEXRuntimeSearchNormalizedText(NSString *source);

/// Query semantics: separate normalized terms remain AND terms in any order.
FOUNDATION_EXPORT NSArray<NSString *> *FLEXRuntimeSearchQueryTokens(NSString *source);

/// Index semantics: each field contributes its split tokens plus one compact
/// token with separators/CamelCase boundaries removed. Fields are compacted
/// independently so unrelated metadata is never concatenated together.
FOUNDATION_EXPORT NSArray<NSString *> *FLEXRuntimeSearchSemanticTokensForValues(
    NSArray *values
);

NS_ASSUME_NONNULL_END
