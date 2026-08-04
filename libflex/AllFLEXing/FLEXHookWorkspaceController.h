#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Adaptive AllFLEXing shell. UIKit presents it as a floating tab bar in a
/// compact environment and as a Liquid Glass sidebar when space permits.
@interface FLEXHookWorkspaceController : UITabBarController

/// Presents the UI before any runtime, persistence or restore work begins.
/// When the current FLEX presenter is temporarily unavailable, the Workspace
/// owns a scene-bound overlay window rather than failing silently.
+ (void)presentDeterministicallyFromViewController:(nullable UIViewController *)host;
+ (void)presentDeterministicallyFromViewController:(nullable UIViewController *)host
                                        completion:(nullable dispatch_block_t)completion;

@end

NS_ASSUME_NONNULL_END
