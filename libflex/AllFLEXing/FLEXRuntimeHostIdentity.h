#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const char *FLEXRuntimeHostIsolationABIVersion;
FOUNDATION_EXPORT NSString *FLEXCurrentHostBundleIdentifier(void);
FOUNDATION_EXPORT NSString *FLEXCurrentHostScope(void);
FOUNDATION_EXPORT NSString *FLEXCurrentHostExecutableUUID(void);
FOUNDATION_EXPORT NSString *FLEXRuntimeImageUUIDAtPath(NSString *path);
FOUNDATION_EXPORT BOOL FLEXRuntimeImageIsAllowedHostImage(NSString *path);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *
FLEXLocatorByAddingCurrentHostIdentity(NSDictionary<NSString *, id> *locator);
FOUNDATION_EXPORT BOOL
FLEXLocatorMatchesCurrentHost(NSDictionary<NSString *, id> *locator);

NS_ASSUME_NONNULL_END
