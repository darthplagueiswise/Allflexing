#import <Foundation/Foundation.h>
#import <objc/message.h>

NS_ASSUME_NONNULL_BEGIN

@class FLEXHookEntry;

/// Foundation has removal/union APIs but no public mutable intersection
/// selector. The runtime search indexes use this compatibility category to
/// intersect precomputed posting lists without rescanning symbol strings.
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
/// validating the recorded live address against the loaded image UUID and its
/// executable segments.
+ (nullable void *)resolveAddressForEntry:(FLEXHookEntry *)entry;

@end

NS_ASSUME_NONNULL_END
