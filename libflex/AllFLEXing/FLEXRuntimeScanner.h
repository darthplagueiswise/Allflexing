#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FLEXHookEntry;

typedef void (^FLEXRuntimeScanCompletion)(NSArray<FLEXHookEntry *> *entries);

FOUNDATION_EXPORT NSNotificationName const FLEXRuntimeImagesDidChangeNotification;

/// Mach-O C import scanner only. Objective-C discovery/search is owned by FLEX.
@interface FLEXRuntimeScanner : NSObject

+ (void)startMonitoringImages;
+ (void)scanCImportsIncludingSystemImages:(BOOL)includeSystemImages
                                completion:(FLEXRuntimeScanCompletion)completion;
+ (FLEXHookEntry *)manualCEntryForSymbol:(NSString *)symbol
                               imageName:(nullable NSString *)imageName;

@end

NS_ASSUME_NONNULL_END
