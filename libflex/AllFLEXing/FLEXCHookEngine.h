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

@end

NS_ASSUME_NONNULL_END
