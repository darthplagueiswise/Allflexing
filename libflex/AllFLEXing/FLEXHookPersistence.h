#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const FLEXHookFlagsDidChangeNotification;

@interface FLEXHookFlag : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *detail;
@property (nonatomic, readonly) BOOL defaultValue;

@end

typedef void (^FLEXHookInstallBlock)(void);

@interface FLEXHookPersistence : NSObject

@property (class, nonatomic, readonly) FLEXHookPersistence *sharedManager;
@property (nonatomic, copy, readonly) NSArray<FLEXHookFlag *> *registeredFlags;
@property (nonatomic, copy, readonly) NSString *storageDomainDescription;

- (void)registerFlag:(NSString *)identifier
                title:(NSString *)title
               detail:(NSString *)detail
         defaultValue:(BOOL)defaultValue;

- (void)registerInstallOnce:(NSString *)identifier
                       title:(NSString *)title
                      detail:(NSString *)detail
                defaultValue:(BOOL)defaultValue
                       block:(FLEXHookInstallBlock)block;

- (BOOL)boolForFlag:(NSString *)identifier;
- (void)setBool:(BOOL)value forFlag:(NSString *)identifier;
- (void)reloadPersistedValues;

/// Installs every registered hook exactly once. Flag values gate hook bodies;
/// they never cause a running process to be re-hooked.
- (void)activateRegisteredHooks;

@end

FOUNDATION_EXPORT BOOL FLEXFlag(NSString *identifier);

NS_ASSUME_NONNULL_END
