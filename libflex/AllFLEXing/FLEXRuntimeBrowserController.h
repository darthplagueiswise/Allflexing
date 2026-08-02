#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Compatibility factory for the Runtime Image menu. The iPhoneOS 26.2 UIKit
/// headers expose the standard UIAction factory without a subtitle argument;
/// the implementation forwards to that public factory and applies a subtitle
/// only when the runtime object supports one.
@interface UIAction (AllFLEXingSubtitleCompatibility)
+ (instancetype)actionWithTitle:(NSString *)title
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
