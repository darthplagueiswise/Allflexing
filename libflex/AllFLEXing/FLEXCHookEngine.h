#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FLEXHookEntry;

/// Foundation has removal/union APIs but no public mutable intersection
/// selector. The runtime search index uses this small compatibility category
/// to intersect precomputed posting lists without rescanning symbol strings.
@interface NSMutableIndexSet (AllFLEXingIntersection)
- (void)intersectIndexes:(NSIndexSet *)indexes;
@end

@interface FLEXCHookEngine : NSObject

+ (BOOL)installEntry:(FLEXHookEntry *)entry error:(NSError **)error;
+ (void)setEnabled:(BOOL)enabled forEntry:(FLEXHookEntry *)entry;
+ (NSUInteger)hitCountForEntry:(FLEXHookEntry *)entry;
+ (NSUInteger)overrideHitCountForEntry:(FLEXHookEntry *)entry;
+ (void)refreshAvailabilityForEntry:(FLEXHookEntry *)entry;
+ (nullable void *)resolveSymbol:(NSString *)symbol;
/// Resolves an inline C target from its selected-image locator. Unlike dlsym,
/// this supports private/local symbols and LC_FUNCTION_STARTS entries by
/// rebuilding the live address from the loaded Mach-O header plus the persisted
/// image-relative offset, then validating that it lies in an executable segment.
+ (nullable void *)resolveAddressForEntry:(FLEXHookEntry *)entry;

@end

NS_ASSUME_NONNULL_END
