#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class FLEXHookEntry;
@class FLEXMethod;
@class FLEXProperty;

/// Converts metadata already produced by FLEX into an AllFLEXing hook entry.
/// This class never enumerates classes or builds a parallel Objective-C index.
@interface FLEXObjCHookResolver : NSObject

+ (BOOL)canRepresentMethod:(FLEXMethod *)method
              inClassNamed:(NSString *)className;

+ (nullable FLEXHookEntry *)entryForMethod:(FLEXMethod *)method
                               targetClass:(Class)targetClass;

+ (nullable FLEXHookEntry *)entryForProperty:(FLEXProperty *)property
                                 targetClass:(Class)targetClass;

@end

NS_ASSUME_NONNULL_END
