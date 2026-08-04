#import "FLEXHookableObjCRuntimeViewController.h"

#import "FLEXHookableObjectExplorerViewController.h"
#import "FLEXLiquidGlass.h"
#import "FLEXMethod.h"
#import "FLEXObjCHookResolver.h"
#import "FLEXRuntimeHostIdentity.h"

@implementation FLEXHookableObjCRuntimeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hookable Objective-C";
    self.searchController.searchBar.placeholder = @"Image.Class.-selector:";

    // dlopen and generic object exploration belong to the unfiltered Runtime
    // Browser. This workspace is intentionally limited to hookable metadata.
    self.toolbarItems = @[];
    [self.navigationController setToolbarHidden:YES animated:NO];
    [FLEXLiquidGlass applyToViewController:self];
}

/// Optional FLEXKeyPathSearchController delegate extension installed by the
/// pinned AllFLEXing patch. Bundle/class/method discovery still belongs to FLEX.
- (BOOL)runtimeBrowserShouldIncludeImagePath:(NSString *)path
                                  shortName:(NSString *)shortName {
    (void)shortName;
    return FLEXRuntimeImageIsAllowedHostImage(path);
}

- (BOOL)runtimeBrowserShouldIncludeMethod:(FLEXMethod *)method
                             inClassNamed:(NSString *)className {
    return [FLEXObjCHookResolver canRepresentMethod:method
                                       inClassNamed:className];
}

- (void)didSelectClass:(Class)cls {
    NSParameterAssert(cls);
    FLEXHookableObjectExplorerViewController *explorer =
        [FLEXHookableObjectExplorerViewController exploringObject:cls
                                                   customSections:nil];
    [self.navigationController pushViewController:explorer animated:YES];
}

@end
