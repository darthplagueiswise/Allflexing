#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FLEXHookEntry;

@interface FLEXCHookEngine : NSObject

+ (BOOL)installEntry:(FLEXHookEntry *)entry error:(NSError **)error;
+ (void)setEnabled:(BOOL)enabled forEntry:(FLEXHookEntry *)entry;
+ (NSUInteger)hitCountForEntry:(FLEXHookEntry *)entry;
+ (void)refreshAvailabilityForEntry:(FLEXHookEntry *)entry;
+ (nullable void *)resolveSymbol:(NSString *)symbol;

@end

NS_ASSUME_NONNULL_END
