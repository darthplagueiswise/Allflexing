#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FLEXRuntimeBrowserKind) {
    FLEXRuntimeBrowserKindObjectiveC = 0,
    FLEXRuntimeBrowserKindC,
};

@interface FLEXRuntimeBrowserController : UITableViewController

- (instancetype)initWithKind:(FLEXRuntimeBrowserKind)kind;

@end

NS_ASSUME_NONNULL_END
