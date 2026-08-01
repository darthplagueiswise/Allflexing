#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FLEXHookEntry;

typedef void (^FLEXRuntimeScanCompletion)(NSArray<FLEXHookEntry *> *entries);

FOUNDATION_EXPORT NSNotificationName const FLEXRuntimeImagesDidChangeNotification;

@interface FLEXRuntimeScanner : NSObject

+ (void)startMonitoringImages;
+ (void)scanObjectiveCRuntimeIncludingSystemImages:(BOOL)includeSystemImages
                                         completion:(FLEXRuntimeScanCompletion)completion;
+ (void)scanCImportsIncludingSystemImages:(BOOL)includeSystemImages
                                completion:(FLEXRuntimeScanCompletion)completion;
+ (FLEXHookEntry *)manualCEntryForSymbol:(NSString *)symbol
                               imageName:(nullable NSString *)imageName;

@end

NS_ASSUME_NONNULL_END
