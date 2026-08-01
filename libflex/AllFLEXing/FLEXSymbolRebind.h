#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FLEXSymbolRebind : NSObject

+ (BOOL)rebindSymbol:(NSString *)symbol
          replacement:(void *)replacement
             original:(void * _Nullable * _Nullable)original;

+ (NSString *)backendDescription;

@end

NS_ASSUME_NONNULL_END
