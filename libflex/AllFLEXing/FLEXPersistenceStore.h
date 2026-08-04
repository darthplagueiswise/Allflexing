#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const char *FLEXPersistenceStoreABIVersion;
FOUNDATION_EXPORT const char *FLEXPersistenceSafeLaunchABIVersion;
FOUNDATION_EXPORT const char *FLEXPersistenceKeychainABIVersion;

@interface FLEXPersistenceStore : NSObject

@property (class, nonatomic, readonly) FLEXPersistenceStore *sharedStore;
@property (nonatomic, copy, readonly) NSString *storageDescription;
@property (nonatomic, copy, readonly) NSString *hostScope;
@property (nonatomic, copy, readonly, nullable) NSString *applicationGroupIdentifier;
@property (nonatomic, readonly) BOOL usesApplicationGroup;
@property (nonatomic, readonly) BOOL usesKeychain;
@property (nonatomic, copy, readonly) NSString *keychainService;
@property (nonatomic, copy, readonly) NSString *keychainAccount;
@property (nonatomic, copy, readonly, nullable) NSString *keychainAccessGroup;
@property (nonatomic, readonly) NSInteger lastKeychainStatus;
@property (nonatomic, copy, readonly, nullable) NSString *lastError;

/// Commits confirmed `com.allflexing.*` state to Keychain and mirrors it to
/// host defaults, an entitlement-backed App Group, and atomic plist files.
/// This method must never be called from pre-main/+load code.
- (BOOL)synchronizeNow;
/// Coalesces confirmed writes on the persistence queue.
- (void)synchronizeSoon;

@end

NS_ASSUME_NONNULL_END
