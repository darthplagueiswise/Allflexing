#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FLEXHookEntry;

typedef void (^FLEXRuntimeScanCompletion)(NSArray<FLEXHookEntry *> *entries);
typedef void (^FLEXRuntimeScanProgress)(NSString *stage,
                                        NSString * _Nullable imagePath,
                                        NSUInteger completed,
                                        NSUInteger total);

FOUNDATION_EXPORT NSNotificationName const FLEXRuntimeImagesDidChangeNotification;
FOUNDATION_EXPORT const char *FLEXRuntimeImageScopedScannerABIVersion;

@interface FLEXRuntimeScanner : NSObject

+ (void)startMonitoringImages;
+ (nullable FLEXHookEntry *)objectiveCEntryForClass:(Class)targetClass
                                           selector:(SEL)selector
                                        classMethod:(BOOL)classMethod;

/// Compatibility wrappers. New Runtime Browser code must use the image-scoped
/// APIs below so scan cost and registry contents match the selected image.
+ (void)scanObjectiveCRuntimeIncludingSystemImages:(BOOL)includeSystemImages
                                         completion:(FLEXRuntimeScanCompletion)completion;
+ (void)scanCImportsIncludingSystemImages:(BOOL)includeSystemImages
                                completion:(FLEXRuntimeScanCompletion)completion;

/// Returns exact paths for images currently loaded in the process. When
/// includeSystemImages is NO, the result is restricted to the host app bundle.
+ (NSArray<NSString *> *)loadedImagePathsIncludingSystemImages:(BOOL)includeSystemImages;

/// Performs a complete Objective-C scan only for the supplied loaded images.
/// Every returned entry has a real Method, an exact supported runtime encoding,
/// and a currently available message-hook provider.
+ (void)scanObjectiveCRuntimeInImagePaths:(NSArray<NSString *> *)imagePaths
                                progress:(nullable FLEXRuntimeScanProgress)progress
                              completion:(FLEXRuntimeScanCompletion)completion;

/// Performs a complete Mach-O scan only for the supplied loaded images.
/// Returned entries are limited to targets validated for an actual backend:
/// confirmed import bind slots for fishhook, or exported live addresses for
/// MSHookFunction. ABI may remain unknown until the detail resolver proves it.
+ (void)scanCFunctionsInImagePaths:(NSArray<NSString *> *)imagePaths
                          progress:(nullable FLEXRuntimeScanProgress)progress
                        completion:(FLEXRuntimeScanCompletion)completion;

+ (FLEXHookEntry *)manualCEntryForSymbol:(NSString *)symbol
                               imageName:(nullable NSString *)imageName;

@end

NS_ASSUME_NONNULL_END
