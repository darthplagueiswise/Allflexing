#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "FLEXHookPersistence.h"

NS_ASSUME_NONNULL_BEGIN

/// Hooks an Objective-C instance method. The production sideload build links
/// the Substrate-compatible API that Feather supplies through ElleKit. The
/// Objective-C runtime path is retained only as an explicitly reported degraded
/// fallback for diagnostics.
FOUNDATION_EXPORT BOOL FLEXHookMessage(Class targetClass,
                                       SEL selector,
                                       IMP replacement,
                                       IMP _Nullable * _Nullable original);

FOUNDATION_EXPORT BOOL FLEXHookClassMessage(Class targetClass,
                                            SEL selector,
                                            IMP replacement,
                                            IMP _Nullable * _Nullable original);

/// Inline C/C++ hook through the loaded Substrate-compatible provider. Returns
/// NO unless MSHookFunction is available and produces an original trampoline.
FOUNDATION_EXPORT BOOL FLEXHookFunctionIfAvailable(void *symbol,
                                                   void *replacement,
                                                   void * _Nullable * _Nullable original);

/// Capability checks are deliberately independent. A valid Objective-C hook
/// must not be hidden just because the loaded provider does not expose the
/// inline-function API (and vice versa).
FOUNDATION_EXPORT BOOL FLEXMSHookMessageProviderAvailable(void);
FOUNDATION_EXPORT BOOL FLEXMSHookFunctionProviderAvailable(void);
FOUNDATION_EXPORT BOOL FLEXMSHookProviderAvailable(void);
FOUNDATION_EXPORT BOOL FLEXMSHookProviderIsElleKit(void);
FOUNDATION_EXPORT NSString *FLEXMSHookProviderName(void);
FOUNDATION_EXPORT NSString *FLEXMSHookProviderPath(void);
FOUNDATION_EXPORT NSString *FLEXMessageHookBackend(void);

NS_ASSUME_NONNULL_END
