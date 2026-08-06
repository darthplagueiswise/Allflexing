#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FLEXHookEntry;
@class FLEXMethod;
@class FLEXProperty;

/// Converts reflection metadata produced by FLEX into an AllFLEXing registry
/// entry with a concrete supported Objective-C ABI. FLEX owns discovery and
/// reflection; AllFLEXing owns eligibility, ABI validation and presentation.
@interface FLEXObjCHookResolver : NSObject

+ (BOOL)canRepresentMethod:(FLEXMethod *)method
              inClassNamed:(NSString *)className;

+ (nullable FLEXHookEntry *)entryForMethod:(FLEXMethod *)method
                               targetClass:(Class)targetClass;

+ (nullable FLEXHookEntry *)entryForProperty:(FLEXProperty *)property
                                 targetClass:(Class)targetClass;

@end

NS_ASSUME_NONNULL_END
