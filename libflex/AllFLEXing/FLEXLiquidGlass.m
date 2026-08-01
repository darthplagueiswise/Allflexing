#import "FLEXLiquidGlass.h"

#import "FLEXHookPersistence.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#if __has_include(<UIKit/UIGlassEffect.h>)
#import <UIKit/UIGlassEffect.h>
#define ALLFLEXING_HAS_UIKIT_GLASS 1
#else
#define ALLFLEXING_HAS_UIKIT_GLASS 0
#endif

static NSInteger const kFLEXLiquidGlassBackdropTag = 0xF1E02601;
static NSInteger const kFLEXLiquidGlassPanelTag = 0xF1E02602;
static NSInteger const kFLEXLiquidGlassSearchTag = 0xF1E02603;
static const void *kFLEXLiquidGlassOriginalButtonConfigurationKey =
    &kFLEXLiquidGlassOriginalButtonConfigurationKey;

static BOOL FLEXObjectBelongsToOverlay(id object) {
    NSString *className = NSStringFromClass([object class]);
    return [className hasPrefix:@"FLEX"] ||
           [className hasPrefix:@"FHS"] ||
           [className hasPrefix:@"AllFLEXing"];
}

static UIVisualEffectView *FLEXEnsureBackdrop(UIView *view,
                                              NSInteger tag,
                                              CGFloat cornerRadius,
                                              BOOL interactive) {
    if (!view) {
        return nil;
    }

    UIVisualEffectView *backdrop = nil;
    for (UIView *subview in view.subviews) {
        if (subview.tag == tag && [subview isKindOfClass:UIVisualEffectView.class]) {
            backdrop = (UIVisualEffectView *)subview;
            break;
        }
    }
    UIVisualEffect *effect = [FLEXLiquidGlass glassEffectInteractive:interactive tint:nil];
    if ([backdrop isKindOfClass:UIVisualEffectView.class]) {
        backdrop.effect = effect;
        return backdrop;
    }

    backdrop = [[UIVisualEffectView alloc] initWithEffect:effect];
    backdrop.tag = tag;
    backdrop.userInteractionEnabled = NO;
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.layer.cornerRadius = cornerRadius;
    backdrop.layer.cornerCurve = kCACornerCurveContinuous;
    backdrop.layer.masksToBounds = YES;

    [view insertSubview:backdrop atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:view.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
    ]];
    return backdrop;
}

static void FLEXWalkViewTree(UIView *view, void (^block)(UIView *view, BOOL insideGlassPanel), BOOL insidePanel) {
    if (!view || !block) {
        return;
    }

    block(view, insidePanel);

    // Check only direct children. UIView's viewWithTag: searches recursively and
    // would incorrectly mark an entire screen as being inside one toolbar panel.
    BOOL ownsPanel = NO;
    for (UIView *subview in view.subviews) {
        if (subview.tag == kFLEXLiquidGlassBackdropTag ||
            subview.tag == kFLEXLiquidGlassPanelTag ||
            subview.tag == kFLEXLiquidGlassSearchTag) {
            ownsPanel = YES;
            break;
        }
    }
    BOOL isPanel = insidePanel || ownsPanel;
    for (UIView *subview in view.subviews) {
        if (subview.tag == kFLEXLiquidGlassBackdropTag ||
            subview.tag == kFLEXLiquidGlassPanelTag ||
            subview.tag == kFLEXLiquidGlassSearchTag) {
            continue;
        }
        FLEXWalkViewTree(subview, block, isPanel);
    }
}

static UIViewController *FLEXVisibleViewController(UIViewController *controller) {
    if (!controller) {
        return nil;
    }
    if (controller.presentedViewController) {
        return FLEXVisibleViewController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return FLEXVisibleViewController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return FLEXVisibleViewController(((UITabBarController *)controller).selectedViewController);
    }
    return controller;
}

@implementation FLEXLiquidGlass

+ (BOOL)isEnabled {
    return FLEXFlag(@"glass.enabled");
}

+ (BOOL)isGlassAvailable {
#if ALLFLEXING_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        return NSClassFromString(@"UIGlassEffect") != nil;
    }
#endif
    return NO;
}

+ (UIVisualEffect *)glassEffectInteractive:(BOOL)interactive tint:(UIColor *)tint {
#if ALLFLEXING_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        effect.interactive = interactive;
        effect.tintColor = tint;
        return effect;
    }
#endif
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
}

+ (UIVisualEffect *)containerEffectWithSpacing:(CGFloat)spacing {
#if ALLFLEXING_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        UIGlassContainerEffect *effect = [UIGlassContainerEffect new];
        effect.spacing = spacing;
        return effect;
    }
#endif
    return nil;
}

+ (void)styleNavigationController:(UINavigationController *)navigationController {
    if (!navigationController) {
        return;
    }

    UINavigationBar *bar = navigationController.navigationBar;
    bar.translucent = YES;

    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithTransparentBackground];
    appearance.backgroundColor = UIColor.clearColor;
    appearance.backgroundEffect = [self glassEffectInteractive:NO tint:nil];
    appearance.shadowColor = UIColor.clearColor;

    bar.standardAppearance = appearance;
    bar.scrollEdgeAppearance = appearance;
    bar.compactAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        bar.compactScrollEdgeAppearance = appearance;
    }

    [self styleToolbar:navigationController.toolbar];
}

+ (void)styleToolbar:(UIToolbar *)toolbar {
    if (!toolbar) {
        return;
    }

    UIToolbarAppearance *appearance = [UIToolbarAppearance new];
    [appearance configureWithTransparentBackground];
    appearance.backgroundColor = UIColor.clearColor;
    appearance.backgroundEffect = [self glassEffectInteractive:NO tint:nil];
    appearance.shadowColor = UIColor.clearColor;

    toolbar.translucent = YES;
    toolbar.standardAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        toolbar.scrollEdgeAppearance = appearance;
    }
}

+ (void)styleTableView:(UITableView *)tableView {
    if (!tableView) {
        return;
    }

    // Liquid Glass is a floating control/navigation layer. The table remains
    // content so cells do not compete with the bars or stack glass on glass.
    tableView.backgroundColor = UIColor.systemBackgroundColor;
    tableView.backgroundView = nil;
    tableView.separatorColor = UIColor.separatorColor;
    for (UITableViewCell *cell in tableView.visibleCells) {
        cell.backgroundColor = UIColor.secondarySystemBackgroundColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
    }
}

+ (void)styleSearchBar:(UISearchBar *)searchBar {
    if (!searchBar) {
        return;
    }

    searchBar.searchBarStyle = UISearchBarStyleMinimal;
    searchBar.backgroundImage = [UIImage new];
    UITextField *textField = searchBar.searchTextField;
    textField.backgroundColor = UIColor.clearColor;
    textField.layer.cornerRadius = 16.0;
    textField.layer.cornerCurve = kCACornerCurveContinuous;
    textField.layer.masksToBounds = YES;
    FLEXEnsureBackdrop(textField, kFLEXLiquidGlassSearchTag, 16.0, YES);
}

+ (void)styleButton:(UIButton *)button prominent:(BOOL)prominent {
    if (!button) {
        return;
    }

#if ALLFLEXING_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        if (!objc_getAssociatedObject(button, kFLEXLiquidGlassOriginalButtonConfigurationKey)) {
            objc_setAssociatedObject(
                button,
                kFLEXLiquidGlassOriginalButtonConfigurationKey,
                button.configuration ?: NSNull.null,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }

        UIButtonConfiguration *old = button.configuration;
        UIButtonConfiguration *glass = prominent
            ? [UIButtonConfiguration prominentGlassButtonConfiguration]
            : [UIButtonConfiguration glassButtonConfiguration];

        glass.title = old.title ?: [button titleForState:UIControlStateNormal];
        glass.subtitle = old.subtitle;
        glass.image = old.image ?: [button imageForState:UIControlStateNormal];
        glass.baseForegroundColor = old.baseForegroundColor ?: button.tintColor;
        glass.baseBackgroundColor = old.baseBackgroundColor;
        if (old) {
            glass.contentInsets = old.contentInsets;
            glass.imagePlacement = old.imagePlacement;
            glass.imagePadding = old.imagePadding;
            glass.titlePadding = old.titlePadding;
        }
        button.configuration = glass;
        return;
    }
#endif

    button.backgroundColor = UIColor.tertiarySystemFillColor;
    button.layer.cornerRadius = 12.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
}

+ (void)stylePanelView:(UIView *)view
          cornerRadius:(CGFloat)cornerRadius
           interactive:(BOOL)interactive {
    if (!view) {
        return;
    }
    view.backgroundColor = UIColor.clearColor;
    FLEXEnsureBackdrop(view, kFLEXLiquidGlassPanelTag, cornerRadius, interactive);
}

+ (void)applyToViewController:(UIViewController *)viewController {
    if (!viewController || !viewController.isViewLoaded) {
        return;
    }
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyToViewController:viewController];
        });
        return;
    }
    if (!self.isEnabled) {
        [self removeFromViewController:viewController];
        return;
    }

    viewController.view.backgroundColor = UIColor.systemBackgroundColor;
    [self styleNavigationController:viewController.navigationController];
    if ([viewController isKindOfClass:UITableViewController.class]) {
        [self styleTableView:((UITableViewController *)viewController).tableView];
    }

    FLEXWalkViewTree(viewController.view, ^(UIView *view, BOOL insideGlassPanel) {
        if ([view isKindOfClass:UISearchBar.class]) {
            [self styleSearchBar:(UISearchBar *)view];
            return;
        }

        NSString *className = NSStringFromClass(view.class);
        BOOL isFLEXToolbar = [className containsString:@"FLEXExplorerToolbar"] ||
                             [className containsString:@"FLEXToolbar"];
        if (isFLEXToolbar) {
            [self stylePanelView:view cornerRadius:22.0 interactive:NO];
            return;
        }

        if ([view isKindOfClass:UIButton.class] && !insideGlassPanel) {
            [self styleButton:(UIButton *)view prominent:NO];
        }
    }, NO);
}

+ (void)removeTaggedBackdropsFromView:(UIView *)view {
    for (UIView *subview in [view.subviews copy]) {
        if (subview.tag == kFLEXLiquidGlassBackdropTag ||
            subview.tag == kFLEXLiquidGlassPanelTag ||
            subview.tag == kFLEXLiquidGlassSearchTag) {
            [subview removeFromSuperview];
            continue;
        }

        if ([subview isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)subview;
            id original = objc_getAssociatedObject(button, kFLEXLiquidGlassOriginalButtonConfigurationKey);
            if (original) {
                button.configuration = original == NSNull.null ? nil : original;
                objc_setAssociatedObject(
                    button,
                    kFLEXLiquidGlassOriginalButtonConfigurationKey,
                    nil,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );
            }
            button.backgroundColor = UIColor.clearColor;
        }
        [self removeTaggedBackdropsFromView:subview];
    }
}

+ (void)removeFromViewController:(UIViewController *)viewController {
    if (!viewController || !viewController.isViewLoaded) {
        return;
    }

    [self removeTaggedBackdropsFromView:viewController.view];

    UINavigationController *navigationController = viewController.navigationController;
    if (navigationController) {
        UINavigationBarAppearance *navigationAppearance = [UINavigationBarAppearance new];
        [navigationAppearance configureWithDefaultBackground];
        navigationController.navigationBar.standardAppearance = navigationAppearance;
        navigationController.navigationBar.scrollEdgeAppearance = navigationAppearance;
        navigationController.navigationBar.compactAppearance = navigationAppearance;

        UIToolbarAppearance *toolbarAppearance = [UIToolbarAppearance new];
        [toolbarAppearance configureWithDefaultBackground];
        navigationController.toolbar.standardAppearance = toolbarAppearance;
        if (@available(iOS 15.0, *)) {
            navigationController.toolbar.scrollEdgeAppearance = toolbarAppearance;
        }
    }
}

+ (void)refreshVisibleFLEXViewControllers {
    dispatch_block_t refresh = ^{
        UIApplication *application = UIApplication.sharedApplication;
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                UIViewController *visible = FLEXVisibleViewController(window.rootViewController);
                if (visible && FLEXObjectBelongsToOverlay(visible)) {
                    [self applyToViewController:visible];
                }
            }
        }
    };

    if (NSThread.isMainThread) {
        refresh();
    } else {
        dispatch_async(dispatch_get_main_queue(), refresh);
    }
}

@end
