#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const char *FLEXPersistenceStoreABIVersion;
FOUNDATION_EXPORT const char *FLEXPersistenceHostIsolationABIVersion;

@interface FLEXPersistenceStore : NSObject

@property (class, nonatomic, readonly) FLEXPersistenceStore *sharedStore;
@property (nonatomic, copy, readonly) NSString *storageDescription;
@property (nonatomic, copy, readonly) NSString *hostScope;
@property (nonatomic, copy, readonly, nullable) NSString *applicationGroupIdentifier;
@property (nonatomic, readonly) BOOL usesApplicationGroup;
@property (nonatomic, readonly) BOOL usesKeychain;
@property (nonatomic, copy, readonly, nullable) NSString *lastError;

/// Flushes host-scoped AllFLEXing preferences to host defaults, Keychain and
/// entitlement-backed App Group/sandbox mirrors. No foreign-host snapshot is
/// accepted.
- (BOOL)synchronizeNow;
- (void)synchronizeSoon;

@end

NS_ASSUME_NONNULL_END
