#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Adaptive AllFLEXing shell. UIKit presents it as a floating tab bar in a
/// compact environment and as a Liquid Glass sidebar when space permits.
@interface FLEXHookWorkspaceController : UITabBarController

/// Resolves the current foreground scene and visible FLEX presenter after lazy
/// runtime activation. Repeated calls never stack duplicate workspaces.
+ (void)presentDeterministicallyFromViewController:(nullable UIViewController *)host;

@end

NS_ASSUME_NONNULL_END
