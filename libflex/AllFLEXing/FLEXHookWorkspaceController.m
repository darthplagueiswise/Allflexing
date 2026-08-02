#import "FLEXHookWorkspaceController.h"

#import "FLEXHookSettingsController.h"
#import "FLEXHookToggles.h"
#import "FLEXLiquidGlass.h"
#import "FLEXRuntimeBrowserController.h"

@interface FLEXHookWorkspaceController ()
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
    // UITabBarController owns these navigation controllers, not their roots.
    // Assign the item to the actual child so the classic controller path keeps
    // selection and containment synchronized on every supported iOS version.
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
        [[FLEXRuntimeBrowserController alloc] initWithKind:FLEXRuntimeBrowserKindC];
    FLEXHookSettingsController *settings = [FLEXHookSettingsController new];

    UINavigationController *centerNavigation =
        [self navigationControllerWithRoot:center title:@"Center" symbol:@"bolt.shield.fill"];
    UINavigationController *objectiveCNavigation =
        [self navigationControllerWithRoot:objectiveC title:@"Objective-C" symbol:@"curlybraces"];
    UINavigationController *cNavigation =
        [self navigationControllerWithRoot:cRuntime title:@"C Runtime" symbol:@"function"];
    UINavigationController *settingsNavigation =
        [self navigationControllerWithRoot:settings title:@"Settings" symbol:@"gearshape.fill"];

    self.workspaceNavigationControllers = @[
        centerNavigation,
        objectiveCNavigation,
        cNavigation,
        settingsNavigation,
    ];

    // Use UIKit's direct child-controller contract. The previous lazy UITab
    // provider path rendered the tab items on iOS 26 but could leave the same
    // child visible after selection when this controller was presented inside
    // FLEX's injected sheet hierarchy.
    [self setViewControllers:self.workspaceNavigationControllers animated:NO];
    self.selectedIndex = 0;
    if (@available(iOS 18.0, *)) {
        // The mode remains adaptive, but ownership stays on the concrete child
        // array above. Compact width gets a tab bar; regular width can expose
        // the system sidebar without a lazy provider changing containment.
        self.mode = UITabBarControllerModeTabSidebar;
        self.customizationIdentifier = @"com.allflexing.runtime-workspace";
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.opaque = YES;
    [FLEXLiquidGlass styleTabBar:self.tabBar];
    self.tabBar.accessibilityIdentifier = @"AllFLEXing.RuntimeWorkspace.TabBar";
    if (@available(iOS 26.0, *)) {
        self.tabBarMinimizeBehavior = UITabBarMinimizeBehaviorOnScrollDown;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UISheetPresentationController *sheet = self.sheetPresentationController;
    if (sheet) {
        sheet.detents = @[
            UISheetPresentationControllerDetent.mediumDetent,
            UISheetPresentationControllerDetent.largeDetent,
        ];
        sheet.selectedDetentIdentifier = UISheetPresentationControllerDetentIdentifierLarge;
        sheet.prefersScrollingExpandsWhenScrolledToEdge = NO;
        sheet.prefersGrabberVisible = YES;
        // This is a modal control surface. Keeping the default noninteractive
        // dimming layer prevents taps outside/through it from reaching the host.
        sheet.largestUndimmedDetentIdentifier = nil;
    }
}

- (void)closeWorkspace {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
