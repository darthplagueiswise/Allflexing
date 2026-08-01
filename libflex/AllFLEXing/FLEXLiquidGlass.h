#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FLEXLiquidGlass : NSObject

+ (BOOL)isEnabled;
+ (BOOL)isGlassAvailable;
+ (UIVisualEffect *)glassEffectInteractive:(BOOL)interactive
                                       tint:(nullable UIColor *)tint;
+ (nullable UIVisualEffect *)containerEffectWithSpacing:(CGFloat)spacing;

+ (void)styleNavigationController:(nullable UINavigationController *)navigationController;
+ (void)styleToolbar:(nullable UIToolbar *)toolbar;
+ (void)styleTableView:(nullable UITableView *)tableView;
+ (void)styleSearchBar:(nullable UISearchBar *)searchBar;
+ (void)styleButton:(nullable UIButton *)button prominent:(BOOL)prominent;
+ (void)stylePanelView:(nullable UIView *)view
          cornerRadius:(CGFloat)cornerRadius
           interactive:(BOOL)interactive;

+ (void)applyToViewController:(nullable UIViewController *)viewController;
+ (void)removeFromViewController:(nullable UIViewController *)viewController;
+ (void)refreshVisibleFLEXViewControllers;

@end

NS_ASSUME_NONNULL_END
