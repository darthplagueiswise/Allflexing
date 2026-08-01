#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSUInteger const FLEXEmbeddedFishhookABIVersion;
FOUNDATION_EXPORT BOOL FLEXEmbeddedFishhookAvailable(void);

@interface FLEXSymbolRebind : NSObject

+ (BOOL)rebindSymbol:(NSString *)symbol
          replacement:(void *)replacement
             original:(void * _Nullable * _Nullable)original;

+ (BOOL)rebindSymbol:(NSString *)symbol
         inImageNamed:(nullable NSString *)imageName
          replacement:(void *)replacement
             original:(void * _Nullable * _Nullable)original;

+ (NSString *)backendDescription;

@end

NS_ASSUME_NONNULL_END
