#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Custom runtime browser for C imports/inline symbols only. Objective-C uses
/// FLEXHookableObjCRuntimeViewController and FLEX's native runtime pipeline.
@interface FLEXRuntimeBrowserController : UITableViewController
@end

NS_ASSUME_NONNULL_END
