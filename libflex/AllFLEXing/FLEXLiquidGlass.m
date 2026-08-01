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
static NSInteger const kFLEXLiquidGlassClusterTag = 0xF1E02604;
static const void *kFLEXLiquidGlassOriginalButtonConfigurationKey =
    &kFLEXLiquidGlassOriginalButtonConfigurationKey;
static const void *kFLEXLiquidGlassOriginalBackgroundColorKey =
    &kFLEXLiquidGlassOriginalBackgroundColorKey;

static BOOL FLEXIsManagedGlassView(UIView *view) {
    return view.tag == kFLEXLiquidGlassBackdropTag ||
           view.tag == kFLEXLiquidGlassPanelTag ||
           view.tag == kFLEXLiquidGlassSearchTag ||
           view.tag == kFLEXLiquidGlassClusterTag;
}

static void FLEXSetRestorableBackgroundColor(UIView *view, UIColor *color) {
    if (!view) {
        return;
    }
    if (!objc_getAssociatedObject(view, kFLEXLiquidGlassOriginalBackgroundColorKey)) {
        objc_setAssociatedObject(
            view,
            kFLEXLiquidGlassOriginalBackgroundColorKey,
            view.backgroundColor ?: NSNull.null,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
    view.backgroundColor = color;
}

static void FLEXRestoreBackgroundColor(UIView *view) {
    id original = objc_getAssociatedObject(view, kFLEXLiquidGlassOriginalBackgroundColorKey);
    if (!original) {
        return;
    }
    view.backgroundColor = original == NSNull.null ? nil : original;
    objc_setAssociatedObject(
        view,
        kFLEXLiquidGlassOriginalBackgroundColorKey,
        nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
}

static void FLEXConfigureCorners(UIView *view,
                                 CGFloat fixedRadius,
                                 BOOL capsule) {
    if (!view) {
        return;
    }
#if ALLFLEXING_HAS_UIKIT_GLASS
    if (@available(iOS 26.0, *)) {
        view.cornerConfiguration = capsule
            ? [UICornerConfiguration capsuleConfiguration]
            : [UICornerConfiguration configurationWithRadius:
                [UICornerRadius fixedRadius:fixedRadius]];
        view.layer.cornerRadius = 0.0;
        view.layer.masksToBounds = YES;
        return;
    }
#endif
    view.layer.cornerRadius = fixedRadius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.masksToBounds = YES;
}

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
        FLEXConfigureCorners(backdrop, cornerRadius, NO);
        return backdrop;
    }

    backdrop = [[UIVisualEffectView alloc] initWithEffect:effect];
    backdrop.tag = tag;
    backdrop.userInteractionEnabled = NO;
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    FLEXConfigureCorners(backdrop, cornerRadius, NO);

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
        if (FLEXIsManagedGlassView(subview)) {
            ownsPanel = YES;
            break;
        }
    }
    BOOL isPanel = insidePanel || ownsPanel;
    for (UIView *subview in view.subviews) {
        if (FLEXIsManagedGlassView(subview)) {
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

/// Hosts one UIGlassContainerEffect and a separate UIGlassEffect behind each
/// direct toolbar button. The buttons remain owned by FLEX, while the glass
/// views share the container required for uniform adaptation and morphing.
@interface FLEXGlassClusterHostView : UIView

@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic) UIVisualEffectView *containerView;
@property (nonatomic) NSMutableArray<UIVisualEffectView *> *glassViews;

- (instancetype)initWithSourceView:(UIView *)sourceView
                     containerEffect:(UIVisualEffect *)containerEffect;
- (void)updateContainerEffect:(UIVisualEffect *)containerEffect;

@end

@implementation FLEXGlassClusterHostView

- (instancetype)initWithSourceView:(UIView *)sourceView
                     containerEffect:(UIVisualEffect *)containerEffect {
    self = [super initWithFrame:sourceView.bounds];
    if (self) {
        _sourceView = sourceView;
        _glassViews = [NSMutableArray array];
        _containerView = [[UIVisualEffectView alloc] initWithEffect:containerEffect];
        _containerView.userInteractionEnabled = NO;
        [self addSubview:_containerView];

        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                UIViewAutoresizingFlexibleHeight;
    }
    return self;
}

- (void)updateContainerEffect:(UIVisualEffect *)containerEffect {
    self.containerView.effect = containerEffect;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.containerView.frame = self.bounds;

    NSMutableArray<UIView *> *controls = [NSMutableArray array];
    for (UIView *candidate in self.sourceView.subviews) {
        if (candidate != self && [candidate isKindOfClass:UIButton.class]) {
            [controls addObject:candidate];
        }
    }
    [controls sortUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat leftX = CGRectGetMinX(left.frame);
        CGFloat rightX = CGRectGetMinX(right.frame);
        if (leftX < rightX) {
            return NSOrderedAscending;
        }
        if (leftX > rightX) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    while (self.glassViews.count < controls.count) {
        UIVisualEffect *glass =
            [FLEXLiquidGlass glassEffectInteractive:YES tint:nil];
        UIVisualEffectView *glassView =
            [[UIVisualEffectView alloc] initWithEffect:nil];
        glassView.userInteractionEnabled = NO;
        glassView.accessibilityElementsHidden = YES;
        glassView.layer.masksToBounds = YES;
        [self.containerView.contentView addSubview:glassView];
        [self.glassViews addObject:glassView];

        // Setting effect, rather than alpha, gives UIKit the native glass
        // materialization transition inside the shared container.
        NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.24;
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            glassView.effect = glass;
        } completion:nil];
    }

    while (self.glassViews.count > controls.count) {
        UIVisualEffectView *glassView = self.glassViews.lastObject;
        [self.glassViews removeLastObject];
        NSTimeInterval duration = UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.20;
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            glassView.effect = nil;
        } completion:^(__unused BOOL finished) {
            [glassView removeFromSuperview];
        }];
    }

    NSTimeInterval morphDuration = UIAccessibilityIsReduceMotionEnabled() ? 0.0 : 0.28;
    [UIView animateWithDuration:morphDuration
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction |
                                UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        [controls enumerateObjectsUsingBlock:^(UIView *control, NSUInteger index, BOOL *stop) {
            (void)stop;
            UIVisualEffectView *glassView = self.glassViews[index];
            CGRect frame = [self convertRect:control.bounds fromView:control];
            frame = CGRectInset(frame, 3.0, 4.0);
            glassView.frame = frame;
            glassView.hidden = control.hidden || control.alpha <= 0.01;
            FLEXConfigureCorners(
                glassView,
                MIN(18.0, CGRectGetHeight(frame) / 2.0),
                YES
            );
        }];
    } completion:nil];
}

@end

static FLEXGlassClusterHostView *FLEXEnsureGlassCluster(UIView *view) {
    UIVisualEffect *containerEffect =
        [FLEXLiquidGlass containerEffectWithSpacing:8.0];
    if (!containerEffect) {
        return nil;
    }

    FLEXGlassClusterHostView *cluster = nil;
    for (UIView *subview in view.subviews) {
        if (subview.tag == kFLEXLiquidGlassClusterTag &&
            [subview isKindOfClass:FLEXGlassClusterHostView.class]) {
            cluster = (FLEXGlassClusterHostView *)subview;
            break;
        }
    }

    if (cluster) {
        [cluster updateContainerEffect:containerEffect];
    } else {
        cluster = [[FLEXGlassClusterHostView alloc]
            initWithSourceView:view
            containerEffect:containerEffect];
        cluster.tag = kFLEXLiquidGlassClusterTag;
        [view insertSubview:cluster atIndex:0];
    }

    cluster.frame = view.bounds;
    [cluster setNeedsLayout];
    [cluster layoutIfNeeded];
    return cluster;
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

    if (self.isGlassAvailable) {
        // Standard UIKit bars adopt Liquid Glass only when old opaque/custom
        // appearances stop overriding the system-provided material.
        bar.standardAppearance = nil;
        bar.scrollEdgeAppearance = nil;
        bar.compactAppearance = nil;
        if (@available(iOS 15.0, *)) {
            bar.compactScrollEdgeAppearance = nil;
        }
        [self styleToolbar:navigationController.toolbar];
        return;
    }

    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithTransparentBackground];
    appearance.backgroundColor = UIColor.clearColor;
    appearance.backgroundEffect =
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
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

    if (self.isGlassAvailable) {
        toolbar.translucent = YES;
        toolbar.standardAppearance = nil;
        if (@available(iOS 15.0, *)) {
            toolbar.scrollEdgeAppearance = nil;
        }
        return;
    }

    UIToolbarAppearance *appearance = [UIToolbarAppearance new];
    [appearance configureWithTransparentBackground];
    appearance.backgroundColor = UIColor.clearColor;
    appearance.backgroundEffect =
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
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

    // Liquid Glass belongs to navigation and controls. On iOS 26 leave content
    // colors owned by FLEX/UIKit; changing every cell creates stacked dark
    // slabs and breaks the system's scroll-edge adaptation.
    if (self.isGlassAvailable) {
        FLEXRestoreBackgroundColor(tableView);
        for (UITableViewCell *cell in tableView.visibleCells) {
            FLEXRestoreBackgroundColor(cell);
            FLEXRestoreBackgroundColor(cell.contentView);
        }
        return;
    }

    FLEXSetRestorableBackgroundColor(tableView, UIColor.systemBackgroundColor);
    tableView.backgroundView = nil;
    tableView.separatorColor = UIColor.separatorColor;
    for (UITableViewCell *cell in tableView.visibleCells) {
        FLEXSetRestorableBackgroundColor(cell, UIColor.secondarySystemBackgroundColor);
        FLEXSetRestorableBackgroundColor(cell.contentView, UIColor.clearColor);
    }
}

+ (void)styleSearchBar:(UISearchBar *)searchBar {
    if (!searchBar) {
        return;
    }

    if (self.isGlassAvailable) {
        // UISearchBar is a standard component and supplies its own Liquid Glass
        // when linked with UIKit 26. Do not stack a custom glass view under it.
        FLEXRestoreBackgroundColor(searchBar.searchTextField);
        return;
    }

    searchBar.searchBarStyle = UISearchBarStyleMinimal;
    searchBar.backgroundImage = [UIImage new];
    UITextField *textField = searchBar.searchTextField;
    FLEXSetRestorableBackgroundColor(textField, UIColor.clearColor);
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

    FLEXSetRestorableBackgroundColor(button, UIColor.tertiarySystemFillColor);
    button.layer.cornerRadius = 12.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
}

+ (void)stylePanelView:(UIView *)view
          cornerRadius:(CGFloat)cornerRadius
           interactive:(BOOL)interactive {
    if (!view) {
        return;
    }
    FLEXSetRestorableBackgroundColor(view, UIColor.clearColor);

    NSString *className = NSStringFromClass(view.class);
    if (self.isGlassAvailable &&
        ([className containsString:@"FLEXExplorerToolbar"] ||
         [className containsString:@"FLEXToolbar"])) {
        UIView *legacyBackground = nil;
        @try {
            legacyBackground = [view valueForKey:@"backgroundView"];
        } @catch (__unused NSException *exception) {
        }
        if ([legacyBackground isKindOfClass:UIView.class]) {
            FLEXSetRestorableBackgroundColor(legacyBackground, UIColor.clearColor);
        }
        for (UIView *subview in view.subviews) {
            if ([subview isKindOfClass:UIButton.class]) {
                FLEXSetRestorableBackgroundColor(subview, UIColor.clearColor);
            }
        }
        FLEXEnsureGlassCluster(view);
        return;
    }

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

    if (self.isGlassAvailable) {
        FLEXRestoreBackgroundColor(viewController.view);
    } else {
        FLEXSetRestorableBackgroundColor(
            viewController.view,
            UIColor.systemBackgroundColor
        );
    }
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

        (void)insideGlassPanel;
    }, NO);
}

+ (void)removeTaggedBackdropsFromView:(UIView *)view {
    FLEXRestoreBackgroundColor(view);
    for (UIView *subview in [view.subviews copy]) {
        if (FLEXIsManagedGlassView(subview)) {
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
