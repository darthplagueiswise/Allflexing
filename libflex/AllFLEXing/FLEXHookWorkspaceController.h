#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Adaptive AllFLEXing shell. UIKit presents it as a floating tab bar in a
/// compact environment and as a Liquid Glass sidebar when space permits.
@interface FLEXHookWorkspaceController : UITabBarController

/// Presents the UI before any runtime, persistence or restore work begins.
/// Presented directly on the host FLEX controller (the known-good path that
/// also works inside UIDesignRequiresCompatibility hosts).

@end

NS_ASSUME_NONNULL_END
