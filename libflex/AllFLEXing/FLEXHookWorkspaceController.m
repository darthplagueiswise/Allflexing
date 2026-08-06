#import "FLEXHookWorkspaceController.h"

#import "FLEXHookSettingsController.h"
#import "FLEXHookToggles.h"
#import "FLEXHookableObjCRuntimeViewController.h"
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

    // FLEX supplies the optimized Objective-C discovery/reflection backend.
    // AllFLEXing owns the product UI: a direct list of eligible methods with
    // concrete resolved Objective-C ABIs and shared registry controls.
    FLEXHookableObjCRuntimeViewController *objectiveC =
        [FLEXHookableObjCRuntimeViewController new];

    // C has no universal runtime type encoding. Its dedicated patcher lists
    // imports/symbols and keeps exact ABI selection explicit in the detail UI.
    FLEXRuntimeBrowserController *cSymbolPatcher = [FLEXRuntimeBrowserController new];
    FLEXHookSettingsController *settings = [FLEXHookSettingsController new];

    UINavigationController *centerNavigation =
        [self navigationControllerWithRoot:center title:@"Center" symbol:@"bolt.shield.fill"];
    UINavigationController *objectiveCNavigation =
        [self navigationControllerWithRoot:objectiveC title:@"Objective-C" symbol:@"curlybraces"];
    UINavigationController *cNavigation =
        [self navigationControllerWithRoot:cSymbolPatcher
                                     title:@"C Patcher"
                                    symbol:@"function"];
    UINavigationController *settingsNavigation =
        [self navigationControllerWithRoot:settings title:@"Settings" symbol:@"gearshape.fill"];

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
        sheet.largestUndimmedDetentIdentifier = nil;
    }
}

- (void)closeWorkspace {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
