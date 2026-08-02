#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The iPhoneOS 26.2 UIKit headers expose the standard UIAction factory without
/// a subtitle argument. AllFLEXing keeps call sites readable through this
/// compatibility category; its implementation forwards to the public factory
/// and applies a subtitle only when the runtime object supports one.
@interface UIAction (AllFLEXingSubtitleCompatibility)
+ (instancetype)af_actionWithTitle:(NSString *)title
                          subtitle:(nullable NSString *)subtitle
                             image:(nullable UIImage *)image
                        identifier:(nullable UIActionIdentifier)identifier
                           handler:(UIActionHandler)handler;
@end

typedef NS_ENUM(NSInteger, FLEXRuntimeBrowserKind) {
    FLEXRuntimeBrowserKindObjectiveC = 0,
    FLEXRuntimeBrowserKindC,
};

@interface FLEXRuntimeBrowserController : UITableViewController

@property (nonatomic, readonly) UISearchController *searchController;

- (instancetype)initWithKind:(FLEXRuntimeBrowserKind)kind;

@end

NS_ASSUME_NONNULL_END
