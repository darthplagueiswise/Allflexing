#import "FLEXHookableObjCRuntimeViewController.h"

#import "FLEXHookableObjCSearchController.h"
#import "FLEXHookableObjectExplorerViewController.h"
#import "FLEXLiquidGlass.h"
#import "FLEXRuntimeClient.h"

@interface FLEXHookableObjCRuntimeViewController ()
    <FLEXHookableObjCSearchControllerDelegate>
@property (nonatomic) FLEXHookableObjCSearchController *semanticSearch;
@end

@implementation FLEXHookableObjCRuntimeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Objective-C";

    // Reuse FLEX's search bar infrastructure, but drive it with our own
    // natural-text controller instead of the key-path grammar.
    self.showsSearchBar = YES;
    self.showSearchBarInitially = YES;
    self.activatesSearchBarAutomatically = NO;
    self.searchController.searchBar.placeholder =
        @"Type words: fb config manager, employee enable";
    self.searchController.searchBar.autocapitalizationType =
        UITextAutocapitalizationTypeNone;
    self.searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;

    // Initialize WebKit legacy on the main thread up front, exactly as FLEX's
    // own runtime browser does, to avoid a first-touch crash during discovery.
    [FLEXRuntimeClient initializeWebKitLegacy];

    self.semanticSearch = [FLEXHookableObjCSearchController delegate:self];
    [self.semanticSearch loadIfNeeded];

    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView deselectRowAtIndexPath:self.tableView.indexPathForSelectedRow
                                  animated:YES];
    [FLEXLiquidGlass applyToViewController:self];
}

#pragma mark - FLEXHookableObjCSearchControllerDelegate

- (void)hookableSearchDidSelectClass:(Class)cls {
    if (!cls) {
        return;
    }
    UIViewController *explorer =
        [FLEXHookableObjectExplorerViewController exploringHookableClass:cls];
    [self.navigationController pushViewController:explorer animated:YES];
}

@end
