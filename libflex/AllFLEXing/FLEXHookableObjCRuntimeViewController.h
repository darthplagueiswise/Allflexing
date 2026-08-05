#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// AllFLEXing presentation for Objective-C hook targets. FLEX remains the
/// discovery/reflection backend, while this controller lists only methods with
/// a concrete supported ABI and routes them directly into the shared registry.
@interface FLEXHookableObjCRuntimeViewController : UITableViewController
@end

NS_ASSUME_NONNULL_END
