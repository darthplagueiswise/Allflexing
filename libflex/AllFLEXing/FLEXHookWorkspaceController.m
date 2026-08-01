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
    root.tabBarItem = [[UITabBarItem alloc]
        initWithTitle:title
                image:[UIImage systemImageNamed:symbol]
        selectedImage:nil];
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:root];
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

    if (@available(iOS 18.0, *)) {
        NSArray<NSString *> *titles = @[@"Center", @"Objective-C", @"C Runtime", @"Settings"];
        NSArray<NSString *> *symbols = @[@"bolt.shield.fill", @"curlybraces", @"function", @"gearshape.fill"];
        NSArray<NSString *> *identifiers = @[
            @"allflexing.center",
            @"allflexing.objective-c",
            @"allflexing.c-runtime",
            @"allflexing.settings",
        ];
        NSMutableArray<UITab *> *tabs = [NSMutableArray arrayWithCapacity:titles.count];
        [titles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
            (void)stop;
            UINavigationController *navigationController =
                self.workspaceNavigationControllers[index];
            UITab *tab = [[UITab alloc]
                initWithTitle:title
                        image:[UIImage systemImageNamed:symbols[index]]
                   identifier:identifiers[index]
       viewControllerProvider:^UIViewController *(__unused UITab *selectedTab) {
                return navigationController;
            }];
            tab.preferredPlacement = UITabPlacementFixed;
            [tabs addObject:tab];
        }];
        self.tabs = tabs;
        self.mode = UITabBarControllerModeTabSidebar;
        self.customizationIdentifier = @"com.allflexing.runtime-workspace";
    } else {
        self.viewControllers = self.workspaceNavigationControllers;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UITabBarAppearance *appearance = [UITabBarAppearance new];
    [appearance configureWithDefaultBackground];
    self.tabBar.standardAppearance = appearance;
    if (@available(iOS 15.0, *)) {
        self.tabBar.scrollEdgeAppearance = nil;
    }
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
    }
}

- (void)closeWorkspace {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
