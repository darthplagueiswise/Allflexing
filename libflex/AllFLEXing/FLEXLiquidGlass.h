#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FLEXLiquidGlass : NSObject

+ (BOOL)isEnabled;
+ (BOOL)isGlassAvailable;
+ (UIVisualEffect *)glassEffectInteractive:(BOOL)interactive
                                       tint:(nullable UIColor *)tint;
+ (nullable UIVisualEffect *)containerEffectWithSpacing:(CGFloat)spacing;
+ (UIVisualEffectView *)glassViewInteractive:(BOOL)interactive
                                        tint:(nullable UIColor *)tint;
+ (nullable UIVisualEffectView *)glassContainerViewWithSpacing:(CGFloat)spacing;
+ (void)configureCornersForView:(nullable UIView *)view
                         radius:(CGFloat)radius
                        capsule:(BOOL)capsule;
+ (void)materializeGlassView:(nullable UIVisualEffectView *)glassView
                 interactive:(BOOL)interactive
                        tint:(nullable UIColor *)tint
                    animated:(BOOL)animated;
+ (void)dematerializeGlassView:(nullable UIVisualEffectView *)glassView
                      animated:(BOOL)animated
                    completion:(nullable void (^)(void))completion;

+ (void)styleNavigationController:(nullable UINavigationController *)navigationController;
+ (void)styleToolbar:(nullable UIToolbar *)toolbar;
+ (void)styleTabBar:(nullable UITabBar *)tabBar;
+ (void)styleTableView:(nullable UITableView *)tableView;
+ (void)applyScrollEdgeEffectsToScrollView:(nullable UIScrollView *)scrollView;
+ (void)styleTableCell:(nullable UITableViewCell *)cell;
+ (void)styleSearchBar:(nullable UISearchBar *)searchBar;
+ (void)styleButton:(nullable UIButton *)button prominent:(BOOL)prominent;
+ (void)stylePanelView:(nullable UIView *)view
            interactive:(BOOL)interactive
                  radius:(CGFloat)radius;

+ (void)applyToViewController:(nullable UIViewController *)viewController;
+ (void)removeFromViewController:(nullable UIViewController *)viewController;
+ (void)refreshVisibleFLEXViewControllers;

@end

NS_ASSUME_NONNULL_END
