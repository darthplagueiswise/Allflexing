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

static const void *kFLEXOriginalButtonConfigurationKey =
    &kFLEXOriginalButtonConfigurationKey;
static const void *kFLEXGlassCellBackgroundKey =
    &kFLEXGlassCellBackgroundKey;
static const void *kFLEXGlassCellSelectionKey =
    &kFLEXGlassCellSelectionKey;
static const void *kFLEXGlassSearchBackgroundKey =
    &kFLEXGlassSearchBackgroundKey;
static const void *kFLEXGlassPanelBackgroundKey =
    &kFLEXGlassPanelBackgroundKey;

static NSTimeInterval FLEXGlassDuration(NSTimeInterval duration) {
    return UIAccessibilityIsReduceMotionEnabled() ? 0.0 : duration;
}

static UIViewController *FLEXVisibleController(UIViewController *controller) {
    if (!controller) {
        return nil;
    }
    if (controller.presentedViewController) {
        return FLEXVisibleController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return FLEXVisibleController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return FLEXVisibleController(((UITabBarController *)controller).selectedViewController);
    }
    if ([controller isKindOfClass:UISplitViewController.class]) {
        return FLEXVisibleController(((UISplitViewController *)controller).viewControllers.lastObject);
    }
    return controller;
}

@interface FLEXGlassCellBackgroundView : UIView
@property (nonatomic) UIVisualEffectView *glassView;
@end

@implementation FLEXGlassCellBackgroundView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        _glassView = [FLEXLiquidGlass glassViewInteractive:YES tint:nil];
        _glassView.userInteractionEnabled = NO;
        _glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                     UIViewAutoresizingFlexibleHeight;
        _glassView.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        _glassView.layer.borderColor =
            [UIColor.separatorColor colorWithAlphaComponent:0.34].CGColor;
        [self addSubview:_glassView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.glassView.frame = CGRectInset(self.bounds, 0.0, 2.0);
    [FLEXLiquidGlass configureCornersForView:self.glassView
                                      radius:18.0
                                     capsule:NO];
}

@end

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

+ (UIVisualEffectView *)glassViewInteractive:(BOOL)interactive tint:(UIColor *)tint {
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
    if (!effect) {
        return nil;
    }
    UIVisualEffectView *view = [[UIVisualEffectView alloc] initWithEffect:effect];
    view.backgroundColor = UIColor.clearColor;
    return view;
}

+ (void)configureCornersForView:(UIView *)view
                         radius:(CGFloat)radius
                        capsule:(BOOL)capsule {
    if (!view) {
        return;
    }
#if ALLFLEXING_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        view.cornerConfiguration = capsule
            ? [UICornerConfiguration capsuleConfiguration]
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
    if (!glassView) {
        return;
    }
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
        if (completion) {
            completion();
        }
        return;
    }
    void (^changes)(void) = ^{
        glassView.effect = nil;
    };
    void (^finished)(BOOL) = ^(__unused BOOL done) {
        if (completion) {
            completion();
        }
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
    if (!navigationController) {
        return;
    }

    navigationController.navigationBar.translucent = YES;
    navigationController.navigationBar.prefersLargeTitles = YES;
    if (self.isGlassAvailable && self.isEnabled) {
        // A fresh default appearance removes FLEX's legacy opaque background
        // without suppressing UIKit 26's native scroll-edge and glass behavior.
        UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
        [appearance configureWithDefaultBackground];
        navigationController.navigationBar.standardAppearance = appearance;
        navigationController.navigationBar.scrollEdgeAppearance = nil;
        navigationController.navigationBar.compactAppearance = nil;
        if (@available(iOS 15.0, *)) {
            navigationController.navigationBar.compactScrollEdgeAppearance = nil;
        }
    } else {
        UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
        [appearance configureWithDefaultBackground];
        navigationController.navigationBar.standardAppearance = appearance;
        navigationController.navigationBar.scrollEdgeAppearance = appearance;
        navigationController.navigationBar.compactAppearance = appearance;
        if (@available(iOS 15.0, *)) {
            navigationController.navigationBar.compactScrollEdgeAppearance = appearance;
        }
    }
    [self styleToolbar:navigationController.toolbar];
}

+ (void)styleToolbar:(UIToolbar *)toolbar {
    if (!toolbar) {
        return;
    }
    toolbar.translucent = YES;
    UIToolbarAppearance *appearance = [UIToolbarAppearance new];
    [appearance configureWithDefaultBackground];
    toolbar.standardAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        toolbar.scrollEdgeAppearance = self.isGlassAvailable && self.isEnabled
            ? nil : appearance;
    }
}

+ (void)styleTableView:(UITableView *)tableView {
    if (!tableView) {
        return;
    }
    BOOL usesGlass = self.isGlassAvailable && self.isEnabled;
    tableView.backgroundColor = usesGlass
        ? UIColor.clearColor : UIColor.systemGroupedBackgroundColor;
    tableView.separatorStyle = usesGlass
        ? UITableViewCellSeparatorStyleNone : UITableViewCellSeparatorStyleSingleLine;
    tableView.separatorColor = UIColor.separatorColor;
    tableView.cellLayoutMarginsFollowReadableWidth = YES;
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

+ (void)styleTableCell:(UITableViewCell *)cell {
    if (!cell) {
        return;
    }

    BOOL usesGlass = self.isGlassAvailable && self.isEnabled;
    FLEXGlassCellBackgroundView *background =
        objc_getAssociatedObject(cell, kFLEXGlassCellBackgroundKey);
    if (!usesGlass) {
        if (background && cell.backgroundView == background) {
            cell.backgroundView = nil;
        }
        cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        return;
    }

    if (!background) {
        background = [FLEXGlassCellBackgroundView new];
        objc_setAssociatedObject(cell,
                                 kFLEXGlassCellBackgroundKey,
                                 background,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.backgroundView = background;

    UIView *selection = objc_getAssociatedObject(cell, kFLEXGlassCellSelectionKey);
    if (!selection) {
        selection = [UIView new];
        selection.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.18];
        [self configureCornersForView:selection radius:18.0 capsule:NO];
        objc_setAssociatedObject(cell,
                                 kFLEXGlassCellSelectionKey,
                                 selection,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cell.selectedBackgroundView = selection;
}

+ (void)styleSearchBar:(UISearchBar *)searchBar {
    if (!searchBar) {
        return;
    }
    searchBar.searchBarStyle = UISearchBarStyleMinimal;
    searchBar.backgroundImage = nil;
    UISearchTextField *field = searchBar.searchTextField;
    UIVisualEffectView *glass =
        objc_getAssociatedObject(field, kFLEXGlassSearchBackgroundKey);
    if (!(self.isGlassAvailable && self.isEnabled)) {
        glass.hidden = YES;
        field.backgroundColor = UIColor.tertiarySystemFillColor;
        return;
    }

    if (!glass) {
        glass = [self glassViewInteractive:YES tint:nil];
        glass.userInteractionEnabled = NO;
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        [field insertSubview:glass atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [glass.leadingAnchor constraintEqualToAnchor:field.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:field.trailingAnchor],
            [glass.topAnchor constraintEqualToAnchor:field.topAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:field.bottomAnchor],
        ]];
        objc_setAssociatedObject(field,
                                 kFLEXGlassSearchBackgroundKey,
                                 glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.hidden = NO;
    field.backgroundColor = UIColor.clearColor;
    field.background = nil;
    field.borderStyle = UITextBorderStyleNone;
    [self configureCornersForView:glass radius:22.0 capsule:YES];
}

+ (void)styleButton:(UIButton *)button prominent:(BOOL)prominent {
    if (!button) {
        return;
    }
#if ALLFLEXING_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        if (!(self.isGlassAvailable && self.isEnabled)) {
            id saved = objc_getAssociatedObject(button, kFLEXOriginalButtonConfigurationKey);
            if (saved) {
                button.configuration = saved == NSNull.null ? nil : saved;
            }
            return;
        }
        if (!objc_getAssociatedObject(button, kFLEXOriginalButtonConfigurationKey)) {
            objc_setAssociatedObject(
                button,
                kFLEXOriginalButtonConfigurationKey,
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
    if (!view) {
        return;
    }
    BOOL usesGlass = self.isGlassAvailable && self.isEnabled;
    UIVisualEffectView *glass =
        objc_getAssociatedObject(view, kFLEXGlassPanelBackgroundKey);
    if (!usesGlass) {
        if (glass) {
            glass.hidden = YES;
        }
        view.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        [self configureCornersForView:view radius:radius capsule:NO];
        return;
    }

    if (!glass) {
        glass = [self glassViewInteractive:interactive tint:nil];
        glass.userInteractionEnabled = NO;
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        [view insertSubview:glass atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [glass.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
            [glass.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
            [glass.topAnchor constraintEqualToAnchor:view.topAnchor],
            [glass.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
        ]];
        objc_setAssociatedObject(view,
                                 kFLEXGlassPanelBackgroundKey,
                                 glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.hidden = NO;
    view.backgroundColor = UIColor.clearColor;
    [self configureCornersForView:view radius:radius capsule:NO];
    [self configureCornersForView:glass radius:radius capsule:NO];
}

+ (void)applyToViewController:(UIViewController *)viewController {
    if (!viewController) {
        return;
    }
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyToViewController:viewController];
        });
        return;
    }
    [self styleNavigationController:viewController.navigationController];
    if ([viewController isKindOfClass:UITableViewController.class]) {
        [self styleTableView:((UITableViewController *)viewController).tableView];
    }
    UISearchController *searchController = viewController.navigationItem.searchController;
    if (searchController) {
        [self styleSearchBar:searchController.searchBar];
    }
}

+ (void)removeFromViewController:(UIViewController *)viewController {
    if (!viewController) {
        return;
    }
    [self styleNavigationController:viewController.navigationController];
}

+ (void)refreshVisibleFLEXViewControllers {
    dispatch_block_t refresh = ^{
        Class flexWindowClass = NSClassFromString(@"FLEXWindow");
        if (!flexWindowClass) {
            return;
        }
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (![window isKindOfClass:flexWindowClass]) {
                    continue;
                }
                UIViewController *visible = FLEXVisibleController(window.rootViewController);
                [self applyToViewController:visible];
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
