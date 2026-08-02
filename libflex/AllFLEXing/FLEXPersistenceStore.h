#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const char *FLEXPersistenceStoreABIVersion;
FOUNDATION_EXPORT const char *FLEXPersistenceSafeLaunchABIVersion;

@interface FLEXPersistenceStore : NSObject

@property (class, nonatomic, readonly) FLEXPersistenceStore *sharedStore;
@property (nonatomic, copy, readonly) NSString *storageDescription;
@property (nonatomic, copy, readonly) NSString *hostScope;
@property (nonatomic, copy, readonly, nullable) NSString *applicationGroupIdentifier;
@property (nonatomic, readonly) BOOL usesApplicationGroup;
@property (nonatomic, copy, readonly, nullable) NSString *lastError;

/// Flushes every `com.allflexing.*` preference to standard defaults, an
/// entitlement-backed App Group when available, and atomic plist mirrors.
/// This must not be called from pre-main/+load code.
- (BOOL)synchronizeNow;
/// Coalesces frequent writes while still persisting them during the same run.
- (void)synchronizeSoon;

@end

NS_ASSUME_NONNULL_END
