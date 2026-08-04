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

#if __has_include(<UIKit/UIScrollEdgeEffect.h>)
#import <UIKit/UIScrollEdgeEffect.h>
#define ALLFLEXING_HAS_SCROLL_EDGE_EFFECT 1
#else
#define ALLFLEXING_HAS_SCROLL_EDGE_EFFECT 0
#endif

const char *FLEXLiquidGlassNativeABIVersion =
    "AllFLEXing native UIKit 26 Liquid Glass and scroll-edge ABI 2";

// Native grouped rendering marker. This used to live in
// FLEXCompactFLEXBaseStyle.m, which re-applied a worse copy of the styling
// below over FLEXTableViewController via a +load swizzle. That layer is gone:
// the pinned FLEX patch calls styleTableView:/styleTableCell:/styleSearchBar:
// from FLEX's own viewDidLoad/viewWillAppear, so the grouped rendering the
// contract asserts is implemented here and nowhere else.
__attribute__((used)) const char *FLEXNativeUIKitRenderingABIVersion =
    "AllFLEXing native UIKit rendering bootstrap ABI 1";

static const void *kFLEXOriginalButtonConfigurationKey =
    &kFLEXOriginalButtonConfigurationKey;
static const void *kFLEXGlassCellSelectionKey =
    &kFLEXGlassCellSelectionKey;
static const void *kFLEXGlassPanelBackgroundKey =
    &kFLEXGlassPanelBackgroundKey;
static const void *kFLEXOriginalNavigationAppearancesKey =
    &kFLEXOriginalNavigationAppearancesKey;
static const void *kFLEXNavigationFallbackInstalledKey =
    &kFLEXNavigationFallbackInstalledKey;
static const void *kFLEXOriginalToolbarAppearancesKey =
    &kFLEXOriginalToolbarAppearancesKey;
static const void *kFLEXToolbarFallbackInstalledKey =
    &kFLEXToolbarFallbackInstalledKey;
static const void *kFLEXOriginalTabBarAppearancesKey =
    &kFLEXOriginalTabBarAppearancesKey;
static const void *kFLEXTabBarFallbackInstalledKey =
    &kFLEXTabBarFallbackInstalledKey;

static NSTimeInterval FLEXGlassDuration(NSTimeInterval duration) {
    return UIAccessibilityIsReduceMotionEnabled() ? 0.0 : duration;
}

static UIColor *FLEXGlassBaseSurfaceColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? UIColor.blackColor
            : UIColor.whiteColor;
    }];
}

static UIColor *FLEXGlassPanelFillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.075]
            : [UIColor colorWithWhite:1.0 alpha:0.12];
    }];
}

static UIColor *FLEXGlassBorderColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.14]
            : [UIColor colorWithWhite:0.0 alpha:0.10];
    }];
}

static id _Nullable FLEXGlassUnwrapAppearance(id object) {
    return object == NSNull.null ? nil : object;
}

static CGColorRef FLEXGlassResolvedCGColor(UIColor *color,
                                           UITraitCollection *traits) {
    return [[color resolvedColorWithTraitCollection:traits] CGColor];
}

static UIViewController *FLEXVisibleController(UIViewController *controller) {
    if (!controller) return nil;
    if (controller.presentedViewController) {
        return FLEXVisibleController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return FLEXVisibleController(
            ((UINavigationController *)controller).visibleViewController
        );
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return FLEXVisibleController(
            ((UITabBarController *)controller).selectedViewController
        );
    }
    if ([controller isKindOfClass:UISplitViewController.class]) {
        return FLEXVisibleController(
            ((UISplitViewController *)controller).viewControllers.lastObject
        );
    }
    return controller;
}

@implementation FLEXLiquidGlass

+ (BOOL)isEnabled {
    return FLEXFlag(@"glass.enabled");
}

/// YES when the host process opted out of the iOS 26 design via
/// UIDesignRequiresCompatibility. In that mode the process renders with the
/// legacy design system even though the SDK-26 symbols (UIGlassEffect, tab
/// sidebar, minimize behavior) still resolve - so gating purely on
/// @available(iOS 26) or "class exists" is wrong and can drive UIKit into a
/// state it rejects. This is read once from the host's own Info.plist.
+ (BOOL)hostRequiresLegacyCompatibility {
    static BOOL requiresCompat = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id value = NSBundle.mainBundle
            .infoDictionary[@"UIDesignRequiresCompatibility"];
        requiresCompat = [value respondsToSelector:@selector(boolValue)]
            && [value boolValue];
    });
    return requiresCompat;
}

+ (BOOL)isGlassAvailable {
#if ALLFLEXING_HAS_UIKIT_GLASS
    if (self.hostRequiresLegacyCompatibility) {
        return NO;
    }
    if (@available(iOS 26.0, *)) {
        return NSClassFromString(@"UIGlassEffect") != nil;
    }
#endif
    return NO;
}

+ (UIVisualEffect *)glassEffectInteractive:(BOOL)interactive
                                       tint:(UIColor *)tint {
#if ALLFLEXING_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *effect = [UIGlassEffect
            effectWithStyle:UIGlassEffectStyleRegular];
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

+ (UIVisualEffectView *)glassViewInteractive:(BOOL)interactive
                                        tint:(UIColor *)tint {
    UIVisualEffectView *view = [[UIVisualEffectView alloc] initWithEffect:nil];
    view.backgroundColor = UIColor.clearColor;
    view.clipsToBounds = YES;
    [self materializeGlassView:view
                  interactive:interactive
                         tint:tint
                     animated:NO];
    return view;
}

+ (UIVisualEffectView *)glassContainerViewWithSpacing:(CGFloat)spacing {
    UIVisualEffect *effect = [self containerEffectWithSpacing:spacing];
    if (!effect) return nil;
    UIVisualEffectView *view = [[UIVisualEffectView alloc]
        initWithEffect:effect];
    view.backgroundColor = UIColor.clearColor;
    return view;
}

+ (void)configureCornersForView:(UIView *)view
                         radius:(CGFloat)radius
                        capsule:(BOOL)capsule {
    if (!view) return;
#if ALLFLEXING_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        view.cornerConfiguration = capsule
            ? UICornerConfiguration.capsuleConfiguration
            : [UICornerConfiguration configurationWithRadius:
                [UICornerRadius fixedRadius:radius]];
        view.layer.cornerRadius = 0.0;
        view.layer.masksToBounds = YES;
        return;
    }
#endif
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.masksToBounds = YES;
}

+ (void)materializeGlassView:(UIVisualEffectView *)glassView
                 interactive:(BOOL)interactive
                        tint:(UIColor *)tint
                    animated:(BOOL)animated {
    if (!glassView) return;
    UIVisualEffect *effect = [self glassEffectInteractive:interactive tint:tint];
    void (^changes)(void) = ^{
        glassView.effect = effect;
    };
    if (animated && self.isGlassAvailable) {
        [UIView animateWithDuration:FLEXGlassDuration(0.24)
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

+ (void)dematerializeGlassView:(UIVisualEffectView *)glassView
                      animated:(BOOL)animated
                    completion:(void (^)(void))completion {
    if (!glassView) {
        if (completion) completion();
        return;
    }
    void (^changes)(void) = ^{
        glassView.effect = nil;
    };
    void (^finished)(BOOL) = ^(__unused BOOL done) {
        if (completion) completion();
    };
    if (animated && self.isGlassAvailable) {
        [UIView animateWithDuration:FLEXGlassDuration(0.20)
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:changes
                         completion:finished];
    } else {
        changes();
        finished(YES);
    }
}

+ (void)styleNavigationController:(UINavigationController *)navigationController {
    if (!navigationController) return;

    BOOL usesGlass = self.isGlassAvailable && self.isEnabled;
    UINavigationBar *bar = navigationController.navigationBar;
    bar.translucent = YES;
    bar.prefersLargeTitles = YES;
    navigationController.view.backgroundColor = usesGlass
        ? FLEXGlassBaseSurfaceColor()
        : UIColor.systemBackgroundColor;
    navigationController.view.opaque = YES;

    NSArray *saved = objc_getAssociatedObject(
        bar,
        kFLEXOriginalNavigationAppearancesKey
    );
    if (!saved) {
        id compactScroll = NSNull.null;
        if (@available(iOS 15.0, *)) {
            compactScroll = bar.compactScrollEdgeAppearance ?: NSNull.null;
        }
        saved = @[
            bar.standardAppearance ?: NSNull.null,
            bar.scrollEdgeAppearance ?: NSNull.null,
            bar.compactAppearance ?: NSNull.null,
            compactScroll,
        ];
        objc_setAssociatedObject(
            bar,
            kFLEXOriginalNavigationAppearancesKey,
            saved,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    BOOL fallbackInstalled = [objc_getAssociatedObject(
        bar,
        kFLEXNavigationFallbackInstalledKey
    ) boolValue];
    if (usesGlass) {
        // SDK 26 bars create and group their own native glass. Restoring the
        // system-owned appearance prevents a second blur/material layer.
        if (fallbackInstalled) {
            UINavigationBarAppearance *standard =
                FLEXGlassUnwrapAppearance(saved[0]);
            bar.standardAppearance = standard ?: [UINavigationBarAppearance new];
            bar.scrollEdgeAppearance = FLEXGlassUnwrapAppearance(saved[1]);
            bar.compactAppearance = FLEXGlassUnwrapAppearance(saved[2]);
            if (@available(iOS 15.0, *)) {
                bar.compactScrollEdgeAppearance =
                    FLEXGlassUnwrapAppearance(saved[3]);
            }
            objc_setAssociatedObject(
                bar,
                kFLEXNavigationFallbackInstalledKey,
                @NO,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }
    } else {
        UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
        [appearance configureWithDefaultBackground];
        bar.standardAppearance = appearance;
        bar.scrollEdgeAppearance = appearance;
        bar.compactAppearance = appearance;
        if (@available(iOS 15.0, *)) {
            bar.compactScrollEdgeAppearance = appearance;
        }
        objc_setAssociatedObject(
            bar,
            kFLEXNavigationFallbackInstalledKey,
            @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
    [self styleToolbar:navigationController.toolbar];
}

+ (void)styleToolbar:(UIToolbar *)toolbar {
    if (!toolbar) return;
    toolbar.translucent = YES;

    NSArray *saved = objc_getAssociatedObject(
        toolbar,
        kFLEXOriginalToolbarAppearancesKey
    );
    if (!saved) {
        id scrollEdge = NSNull.null;
        if (@available(iOS 15.0, *)) {
            scrollEdge = toolbar.scrollEdgeAppearance ?: NSNull.null;
        }
        saved = @[toolbar.standardAppearance ?: NSNull.null, scrollEdge];
        objc_setAssociatedObject(
            toolbar,
            kFLEXOriginalToolbarAppearancesKey,
            saved,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    BOOL usesGlass = self.isGlassAvailable && self.isEnabled;
    BOOL fallbackInstalled = [objc_getAssociatedObject(
        toolbar,
        kFLEXToolbarFallbackInstalledKey
    ) boolValue];
    if (usesGlass) {
        if (fallbackInstalled) {
            UIToolbarAppearance *standard = FLEXGlassUnwrapAppearance(saved[0]);
            toolbar.standardAppearance = standard ?: [UIToolbarAppearance new];
            if (@available(iOS 15.0, *)) {
                toolbar.scrollEdgeAppearance =
                    FLEXGlassUnwrapAppearance(saved[1]);
            }
            objc_setAssociatedObject(
                toolbar,
                kFLEXToolbarFallbackInstalledKey,
                @NO,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }
    } else {
        UIToolbarAppearance *appearance = [UIToolbarAppearance new];
        [appearance configureWithDefaultBackground];
        toolbar.standardAppearance = appearance;
        if (@available(iOS 15.0, *)) toolbar.scrollEdgeAppearance = appearance;
        objc_setAssociatedObject(
            toolbar,
            kFLEXToolbarFallbackInstalledKey,
            @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
}

+ (void)styleTabBar:(UITabBar *)tabBar {
    if (!tabBar) return;
    tabBar.translucent = YES;

    NSArray *saved = objc_getAssociatedObject(
        tabBar,
        kFLEXOriginalTabBarAppearancesKey
    );
    if (!saved) {
        id scrollEdge = NSNull.null;
        if (@available(iOS 15.0, *)) {
            scrollEdge = tabBar.scrollEdgeAppearance ?: NSNull.null;
        }
        saved = @[tabBar.standardAppearance ?: NSNull.null, scrollEdge];
        objc_setAssociatedObject(
            tabBar,
            kFLEXOriginalTabBarAppearancesKey,
            saved,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }

    BOOL usesGlass = self.isGlassAvailable && self.isEnabled;
    BOOL fallbackInstalled = [objc_getAssociatedObject(
        tabBar,
        kFLEXTabBarFallbackInstalledKey
    ) boolValue];
    if (usesGlass) {
        // UITabBarController compiled with SDK 26 owns the floating glass bar,
        // selection morph and minimize transition.
        if (fallbackInstalled) {
            UITabBarAppearance *standard = FLEXGlassUnwrapAppearance(saved[0]);
            tabBar.standardAppearance = standard ?: [UITabBarAppearance new];
            if (@available(iOS 15.0, *)) {
                tabBar.scrollEdgeAppearance = FLEXGlassUnwrapAppearance(saved[1]);
            }
            objc_setAssociatedObject(
                tabBar,
                kFLEXTabBarFallbackInstalledKey,
                @NO,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }
    } else {
        UITabBarAppearance *appearance = [UITabBarAppearance new];
        [appearance configureWithDefaultBackground];
        tabBar.standardAppearance = appearance;
        if (@available(iOS 15.0, *)) tabBar.scrollEdgeAppearance = appearance;
        objc_setAssociatedObject(
            tabBar,
            kFLEXTabBarFallbackInstalledKey,
            @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
}

+ (void)styleTableView:(UITableView *)tableView {
    if (!tableView) return;
    BOOL usesGlass = self.isGlassAvailable && self.isEnabled;

    // Glass belongs to navigation and controls. The content canvas remains
    // opaque, readable and isolated from the host app below FLEX's overlay.
    tableView.backgroundColor = usesGlass
        ? FLEXGlassBaseSurfaceColor()
        : UIColor.systemGroupedBackgroundColor;
    tableView.opaque = YES;
    tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    tableView.separatorColor = UIColor.separatorColor;
    tableView.cellLayoutMarginsFollowReadableWidth = NO;
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self applyScrollEdgeEffectsToScrollView:tableView];
}

+ (void)applyScrollEdgeEffectsToScrollView:(UIScrollView *)scrollView {
    if (!scrollView) return;
#if ALLFLEXING_HAS_SCROLL_EDGE_EFFECT
    if (@available(iOS 26.0, *)) {
        if (self.isGlassAvailable && self.isEnabled) {
            scrollView.topEdgeEffect.hidden = NO;
            scrollView.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle;
            scrollView.bottomEdgeEffect.hidden = NO;
            scrollView.bottomEdgeEffect.style = UIScrollEdgeEffectStyle.hardStyle;
        } else {
            scrollView.topEdgeEffect.style = UIScrollEdgeEffectStyle.automaticStyle;
            scrollView.bottomEdgeEffect.style = UIScrollEdgeEffectStyle.automaticStyle;
        }
    }
#else
    (void)scrollView;
#endif
}

+ (void)styleTableCell:(UITableViewCell *)cell {
    if (!cell) return;

    // Do not put a separate UIGlassEffect behind every reusable row. That
    // duplicates blur sampling, hurts scroll performance and obscures text.
    cell.backgroundView = nil;
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.contentView.backgroundColor = UIColor.clearColor;

    UIView *selection = objc_getAssociatedObject(
        cell,
        kFLEXGlassCellSelectionKey
    );
    if (!selection) {
        selection = [UIView new];
        selection.backgroundColor = UIColor.tertiarySystemFillColor;
        objc_setAssociatedObject(
            cell,
            kFLEXGlassCellSelectionKey,
            selection,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
    cell.selectedBackgroundView = selection;
}

+ (void)styleSearchBar:(UISearchBar *)searchBar {
    if (!searchBar) return;
    searchBar.searchBarStyle = UISearchBarStyleMinimal;
    searchBar.backgroundImage = nil;
    UISearchTextField *field = searchBar.searchTextField;

#if ALLFLEXING_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        // A search controller embedded in a native SDK 26 navigation bar owns
        // its glass treatment. A second visual-effect view here creates the
        // milky double-blur seen in the old implementation.
        if (self.isGlassAvailable && self.isEnabled) {
            field.background = nil;
            field.backgroundColor = UIColor.clearColor;
            field.borderStyle = UITextBorderStyleNone;
            return;
        }
    }
#endif
    field.backgroundColor = UIColor.tertiarySystemFillColor;
}

+ (void)styleButton:(UIButton *)button prominent:(BOOL)prominent {
    if (!button) return;
#if ALLFLEXING_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        if (!(self.isGlassAvailable && self.isEnabled)) {
            id saved = objc_getAssociatedObject(
                button,
                kFLEXOriginalButtonConfigurationKey
            );
            if (saved) button.configuration = saved == NSNull.null ? nil : saved;
            return;
        }
        if (!objc_getAssociatedObject(
                button,
                kFLEXOriginalButtonConfigurationKey)) {
            objc_setAssociatedObject(
                button,
                kFLEXOriginalButtonConfigurationKey,
                button.configuration ?: NSNull.null,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }
        UIButtonConfiguration *old = button.configuration;
        UIButtonConfiguration *glass = prominent
            ? UIButtonConfiguration.prominentGlassButtonConfiguration
            : UIButtonConfiguration.glassButtonConfiguration;
        glass.title = old.title ?: [button titleForState:UIControlStateNormal];
        glass.subtitle = old.subtitle;
        glass.image = old.image ?: [button imageForState:UIControlStateNormal];
        glass.baseForegroundColor = old.baseForegroundColor ?: button.tintColor;
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
    [self configureCornersForView:button radius:12.0 capsule:NO];
}

+ (void)stylePanelView:(UIView *)view
            interactive:(BOOL)interactive
                  radius:(CGFloat)radius {
    if (!view) return;
    BOOL usesGlass = self.isGlassAvailable && self.isEnabled;
    UIVisualEffectView *glass = objc_getAssociatedObject(
        view,
        kFLEXGlassPanelBackgroundKey
    );
    if (!usesGlass) {
        if (glass) glass.hidden = YES;
        view.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        [self configureCornersForView:view radius:radius capsule:NO];
        return;
    }

    if (!glass) {
        glass = [self glassViewInteractive:interactive tint:nil];
        glass.userInteractionEnabled = NO;
        glass.contentView.backgroundColor = FLEXGlassPanelFillColor();
        glass.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        glass.layer.borderColor = FLEXGlassResolvedCGColor(
            FLEXGlassBorderColor(),
            view.traitCollection
        );
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        [view insertSubview:glass atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [glass.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
            [glass.topAnchor constraintEqualToAnchor:view.topAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        ]];
        objc_setAssociatedObject(
            view,
            kFLEXGlassPanelBackgroundKey,
            glass,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
    glass.hidden = NO;
    glass.contentView.backgroundColor = FLEXGlassPanelFillColor();
    glass.layer.borderColor = FLEXGlassResolvedCGColor(
        FLEXGlassBorderColor(),
        view.traitCollection
    );
    view.backgroundColor = UIColor.clearColor;
    [self configureCornersForView:view radius:radius capsule:NO];
    [self configureCornersForView:glass radius:radius capsule:NO];
}

+ (void)applyToViewController:(UIViewController *)viewController {
    if (!viewController) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyToViewController:viewController];
        });
        return;
    }

    [self styleNavigationController:viewController.navigationController];
    [self styleTabBar:viewController.tabBarController.tabBar];
    if ([viewController isKindOfClass:UITableViewController.class]) {
        UITableView *table = ((UITableViewController *)viewController).tableView;
        [self styleTableView:table];
    } else {
        for (UIView *subview in viewController.view.subviews) {
            if ([subview isKindOfClass:UIScrollView.class]) {
                [self applyScrollEdgeEffectsToScrollView:(UIScrollView *)subview];
            }
        }
    }

    UISearchController *searchController =
        viewController.navigationItem.searchController;
    if (searchController) {
        [self styleSearchBar:searchController.searchBar];
    }
}

+ (void)removeFromViewController:(UIViewController *)viewController {
    if (!viewController) return;
    [self styleNavigationController:viewController.navigationController];
}

+ (void)refreshVisibleFLEXViewControllers {
    dispatch_block_t refresh = ^{
        Class flexWindowClass = NSClassFromString(@"FLEXWindow");
        if (!flexWindowClass) return;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (![window isKindOfClass:flexWindowClass]) continue;
                UIViewController *visible =
                    FLEXVisibleController(window.rootViewController);
                [self applyToViewController:visible];
            }
        }
    };
    if (NSThread.isMainThread) refresh();
    else dispatch_async(dispatch_get_main_queue(), refresh);
}

@end
