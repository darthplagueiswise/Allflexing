#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// Hooks an Objective-C instance method. MSHookMessageEx is used when another
/// already-loaded framework exports it; otherwise the Objective-C runtime is
/// used without any external dependency.
FOUNDATION_EXPORT BOOL FLEXHookMessage(Class targetClass,
                                       SEL selector,
                                       IMP replacement,
                                       IMP _Nullable * _Nullable original);

FOUNDATION_EXPORT BOOL FLEXHookClassMessage(Class targetClass,
                                            SEL selector,
                                            IMP replacement,
                                            IMP _Nullable * _Nullable original);

/// Optional inline hook. Returns NO when MSHookFunction is unavailable. Use
/// FLEXSymbolRebind for the standalone, certificate-safe C-symbol path.
FOUNDATION_EXPORT BOOL FLEXHookFunctionIfAvailable(void *symbol,
                                                   void *replacement,
                                                   void * _Nullable * _Nullable original);

FOUNDATION_EXPORT NSString *FLEXMessageHookBackend(void);

NS_ASSUME_NONNULL_END
