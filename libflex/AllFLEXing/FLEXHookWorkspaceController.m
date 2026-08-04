#import "FLEXHookWorkspaceController.h"

#import "FLEXHookSettingsController.h"
#import "FLEXHookToggles.h"
#import "FLEXLiquidGlass.h"
#import "FLEXRuntimeBrowserController.h"

const char *FLEXRuntimeWorkspacePresentationABIVersion =
    "AllFLEXing UI-first Runtime Workspace presentation ABI 2";

// NOTE (fix): the deterministic presentation machinery that lived here
// (owned UIWindow, scene resolution, visible-controller walk, retry loop)
// broke menu entry inside hosts running UIDesignRequiresCompatibility=true,
// because constructing a UIWindow in that legacy compatibility mode hangs.
// The last known-good build simply presented on the host controller, so the
// loader does exactly that again and this whole layer was removed. The ABI
// marker above is retained: the presentation guarantee it documents still
// holds, now via direct presentation.

@interface FLEXHookWorkspaceController () <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, copy) NSArray<UINavigationController *> *workspaceNavigationControllers;
@end

@implementation FLEXHookWorkspaceController

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
    // The last known-good build set tabSidebar + customization unconditionally
    // and worked inside UIDesignRequiresCompatibility hosts, so these are NOT
    // the cause of the dead menu - the owned-window presentation path was.
    // Restore the unconditional behavior.
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
