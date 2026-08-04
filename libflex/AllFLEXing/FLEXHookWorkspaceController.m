#import "FLEXHookWorkspaceController.h"

#import "FLEXHookSettingsController.h"
#import "FLEXHookToggles.h"
#import "FLEXLiquidGlass.h"
#import "FLEXRuntimeBrowserController.h"

const char *FLEXRuntimeWorkspacePresentationABIVersion =
    "AllFLEXing UI-first Runtime Workspace presentation ABI 2";

static __weak FLEXHookWorkspaceController *gFLEXPresentedWorkspace;
static BOOL gFLEXWorkspacePresentationInFlight = NO;
static UIWindow *gFLEXWorkspaceOwnedWindow;
static __weak UIWindow *gFLEXWorkspacePreviousKeyWindow;

static UIViewController *FLEXWorkspaceVisibleController(
    UIViewController *controller
) {
    if (!controller) return nil;
    UIViewController *presented = controller.presentedViewController;
    if (presented && !presented.isBeingDismissed) {
        return FLEXWorkspaceVisibleController(presented);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return FLEXWorkspaceVisibleController(
            ((UINavigationController *)controller).visibleViewController
        );
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return FLEXWorkspaceVisibleController(
            ((UITabBarController *)controller).selectedViewController
        );
    }
    if ([controller isKindOfClass:UISplitViewController.class]) {
        NSArray<UIViewController *> *children =
            ((UISplitViewController *)controller).viewControllers;
        return FLEXWorkspaceVisibleController(children.lastObject);
    }
    return controller;
}

static UIWindowScene *FLEXWorkspaceForegroundScene(UIViewController *preferred) {
    UIWindowScene *preferredScene = preferred.viewIfLoaded.window.windowScene;
    if (preferredScene.activationState == UISceneActivationStateForegroundActive) {
        return preferredScene;
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static NSArray<UIWindow *> *FLEXWorkspaceCandidateWindows(void) {
    NSMutableArray<UIWindow *> *flexWindows = [NSMutableArray array];
    NSMutableArray<UIWindow *> *keyWindows = [NSMutableArray array];
    NSMutableArray<UIWindow *> *otherWindows = [NSMutableArray array];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha <= 0.0 || !window.rootViewController) {
                continue;
            }
            NSString *className = NSStringFromClass(window.class);
            if ([className hasPrefix:@"FLEX"]) {
                [flexWindows addObject:window];
            } else if (window.isKeyWindow) {
                [keyWindows addObject:window];
            } else if (window.windowLevel == UIWindowLevelNormal) {
                [otherWindows addObject:window];
            }
        }
    }

    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    [result addObjectsFromArray:flexWindows];
    [result addObjectsFromArray:keyWindows];
    [result addObjectsFromArray:otherWindows];
    return result.copy;
}

static UIViewController *FLEXWorkspaceResolvePresenter(
    UIViewController *preferred
) {
    if (preferred.viewIfLoaded.window && !preferred.isBeingDismissed) {
        return FLEXWorkspaceVisibleController(preferred);
    }
    for (UIWindow *window in FLEXWorkspaceCandidateWindows()) {
        UIViewController *visible =
            FLEXWorkspaceVisibleController(window.rootViewController);
        if (visible.viewIfLoaded.window && !visible.isBeingDismissed) {
            return visible;
        }
    }
    return nil;
}

static void FLEXWorkspaceRestorePreviousKeyWindow(void) {
    UIWindow *previous = gFLEXWorkspacePreviousKeyWindow;
    gFLEXWorkspacePreviousKeyWindow = nil;
    if (previous.windowScene.activationState == UISceneActivationStateForegroundActive &&
        !previous.hidden) {
        [previous makeKeyWindow];
    }
}

static void FLEXWorkspaceTearDownOwnedWindow(void) {
    UIWindow *owned = gFLEXWorkspaceOwnedWindow;
    gFLEXWorkspaceOwnedWindow = nil;
    owned.hidden = YES;
    owned.rootViewController = nil;
    FLEXWorkspaceRestorePreviousKeyWindow();
}

@interface FLEXHookWorkspaceController () <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, copy) NSArray<UINavigationController *> *workspaceNavigationControllers;
@end

@implementation FLEXHookWorkspaceController

+ (void)presentDeterministicallyFromViewController:(UIViewController *)host {
    [self presentDeterministicallyFromViewController:host completion:nil];
}

+ (void)presentDeterministicallyFromViewController:(UIViewController *)host
                                        completion:(dispatch_block_t)completion {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentDeterministicallyFromViewController:host
                                                   completion:completion];
        });
        return;
    }
    [self attemptPresentationFrom:host retry:0 completion:completion];
}

+ (void)attemptPresentationFrom:(UIViewController *)host
                          retry:(NSUInteger)retry
                     completion:(dispatch_block_t)completion {
    FLEXHookWorkspaceController *existing = gFLEXPresentedWorkspace;
    if (existing.viewIfLoaded.window && !existing.isBeingDismissed) {
        existing.selectedIndex = 0;
        [existing.view.window makeKeyWindow];
        if (completion) completion();
        return;
    }

    if (gFLEXWorkspacePresentationInFlight) {
        if (retry < 40) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                dispatch_get_main_queue(),
                ^{
                    [self attemptPresentationFrom:host
                                            retry:retry + 1
                                       completion:completion];
                }
            );
        }
        return;
    }

    UIViewController *presenter = FLEXWorkspaceResolvePresenter(host);
    BOOL transitioning = presenter && (
        presenter.isBeingPresented ||
        presenter.isBeingDismissed ||
        presenter.presentedViewController.isBeingPresented ||
        presenter.presentedViewController.isBeingDismissed
    );
    if (transitioning && retry < 12) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
            dispatch_get_main_queue(),
            ^{
                [self attemptPresentationFrom:host
                                        retry:retry + 1
                                   completion:completion];
            }
        );
        return;
    }

    FLEXHookWorkspaceController *workspace = [FLEXHookWorkspaceController new];
    gFLEXPresentedWorkspace = workspace;
    gFLEXWorkspacePresentationInFlight = YES;

    dispatch_block_t didPresent = ^{
        gFLEXWorkspacePresentationInFlight = NO;
        workspace.presentationController.delegate = workspace;
        [FLEXLiquidGlass applyToViewController:workspace.selectedViewController];
        if (completion) completion();
    };

    if (presenter.viewIfLoaded.window && !transitioning) {
        [presenter presentViewController:workspace
                                animated:YES
                              completion:didPresent];

        // UIKit can reject a presentation without invoking completion when the
        // presenter becomes invalid during the transition. Fall back to an
        // owned scene window instead of leaving the global in-flight gate stuck.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC),
            dispatch_get_main_queue(),
            ^{
                if (gFLEXWorkspacePresentationInFlight &&
                    !workspace.viewIfLoaded.window) {
                    gFLEXWorkspacePresentationInFlight = NO;
                    gFLEXPresentedWorkspace = nil;
                    [self presentInOwnedWindowFrom:host completion:completion];
                }
            }
        );
        return;
    }

    gFLEXWorkspacePresentationInFlight = NO;
    gFLEXPresentedWorkspace = nil;
    [self presentInOwnedWindowFrom:host completion:completion];
}

+ (void)presentInOwnedWindowFrom:(UIViewController *)host
                       completion:(dispatch_block_t)completion {
    UIWindowScene *scene = FLEXWorkspaceForegroundScene(host);
    if (!scene) {
        NSLog(@"[AllFLEXing] Runtime Workspace presentation failed: no foreground UIWindowScene");
        return;
    }

    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow) {
            gFLEXWorkspacePreviousKeyWindow = window;
            break;
        }
    }

    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.systemBackgroundColor;
    root.view.opaque = YES;

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert - 1.0;
    window.rootViewController = root;
    gFLEXWorkspaceOwnedWindow = window;
    [window makeKeyAndVisible];

    FLEXHookWorkspaceController *workspace = [FLEXHookWorkspaceController new];
    gFLEXPresentedWorkspace = workspace;
    gFLEXWorkspacePresentationInFlight = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [root presentViewController:workspace
                           animated:YES
                         completion:^{
            gFLEXWorkspacePresentationInFlight = NO;
            workspace.presentationController.delegate = workspace;
            [FLEXLiquidGlass applyToViewController:workspace.selectedViewController];
            if (completion) completion();
        }];
    });
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationPageSheet;
        self.modalInPresentation = NO;
        [self configureWorkspace];
    }
    return self;
}

- (UINavigationController *)navigationControllerWithRoot:(UIViewController *)root
                                                   title:(NSString *)title
                                                  symbol:(NSString *)symbol {
    UITabBarItem *tabBarItem = [[UITabBarItem alloc]
        initWithTitle:title
                image:[UIImage systemImageNamed:symbol]
        selectedImage:nil];
    root.tabBarItem = tabBarItem;
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:root];
    navigationController.tabBarItem = tabBarItem;
    navigationController.navigationBar.prefersLargeTitles = YES;
    [FLEXLiquidGlass styleNavigationController:navigationController];
    root.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeWorkspace)];
    return navigationController;
}

- (void)configureWorkspace {
    FLEXHookToggles *center = [FLEXHookToggles new];
    FLEXRuntimeBrowserController *objectiveC =
        [[FLEXRuntimeBrowserController alloc]
            initWithKind:FLEXRuntimeBrowserKindObjectiveC];
    FLEXRuntimeBrowserController *cRuntime =
        [[FLEXRuntimeBrowserController alloc]
            initWithKind:FLEXRuntimeBrowserKindC];
    FLEXHookSettingsController *settings = [FLEXHookSettingsController new];

    UINavigationController *centerNavigation =
        [self navigationControllerWithRoot:center
                                     title:@"Center"
                                    symbol:@"bolt.shield.fill"];
    UINavigationController *objectiveCNavigation =
        [self navigationControllerWithRoot:objectiveC
                                     title:@"Objective-C"
                                    symbol:@"curlybraces"];
    UINavigationController *cNavigation =
        [self navigationControllerWithRoot:cRuntime
                                     title:@"C Runtime"
                                    symbol:@"function"];
    UINavigationController *settingsNavigation =
        [self navigationControllerWithRoot:settings
                                     title:@"Settings"
                                    symbol:@"gearshape.fill"];

    self.workspaceNavigationControllers = @[
        centerNavigation,
        objectiveCNavigation,
        cNavigation,
        settingsNavigation,
    ];
    [self setViewControllers:self.workspaceNavigationControllers animated:NO];
    self.selectedIndex = 0;
    if (@available(iOS 18.0, *)) {
        self.mode = UITabBarControllerModeTabSidebar;
        self.customizationIdentifier = @"com.allflexing.runtime-workspace";
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.opaque = YES;
    [FLEXLiquidGlass styleTabBar:self.tabBar];
    self.tabBar.accessibilityIdentifier =
        @"AllFLEXing.RuntimeWorkspace.TabBar";
    self.view.accessibilityIdentifier =
        @"AllFLEXing.RuntimeWorkspace.Root";
    if (@available(iOS 26.0, *)) {
        self.tabBarMinimizeBehavior = UITabBarMinimizeBehaviorOnScrollDown;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    gFLEXPresentedWorkspace = self;
    UISheetPresentationController *sheet = self.sheetPresentationController;
    if (sheet) {
        sheet.detents = @[
            UISheetPresentationControllerDetent.mediumDetent,
            UISheetPresentationControllerDetent.largeDetent,
        ];
        sheet.selectedDetentIdentifier =
            UISheetPresentationControllerDetentIdentifierLarge;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
        sheet.prefersGrabberVisible = YES;
        sheet.largestUndimmedDetentIdentifier = nil;
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || !self.view.window) {
        if (gFLEXPresentedWorkspace == self) gFLEXPresentedWorkspace = nil;
        gFLEXWorkspacePresentationInFlight = NO;
        FLEXWorkspaceTearDownOwnedWindow();
    }
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    (void)presentationController;
    if (gFLEXPresentedWorkspace == self) gFLEXPresentedWorkspace = nil;
    gFLEXWorkspacePresentationInFlight = NO;
    FLEXWorkspaceTearDownOwnedWindow();
}

- (void)closeWorkspace {
    [self dismissViewControllerAnimated:YES completion:^{
        if (gFLEXPresentedWorkspace == self) gFLEXPresentedWorkspace = nil;
        gFLEXWorkspacePresentationInFlight = NO;
        FLEXWorkspaceTearDownOwnedWindow();
    }];
}

@end
