#import "FLEXCompactRuntimeUI.h"

#import "FLEXLiquidGlass.h"

#import <objc/runtime.h>

static UIFont *FLEXInternalScaledFont(CGFloat size,
                                      UIFontWeight weight,
                                      UIFontTextStyle style,
                                      CGFloat maximum) {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    return [[UIFontMetrics metricsForTextStyle:style]
        scaledFontForFont:base maximumPointSize:maximum];
}

static void (*FLEXBaseTableViewDidLoad)(id, SEL) = NULL;
static void (*FLEXBaseTableViewWillAppear)(id, SEL, BOOL) = NULL;
static void (*FLEXBaseTableViewDidLayoutSubviews)(id, SEL) = NULL;

static NSInteger FLEXInternalSectionCount(UITableView *tableView) {
    id<UITableViewDataSource> dataSource = tableView.dataSource;
    if ([dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)]) {
        return [dataSource numberOfSectionsInTableView:tableView];
    }
    return 1;
}

static NSInteger FLEXInternalRowCount(UITableView *tableView, NSInteger section) {
    id<UITableViewDataSource> dataSource = tableView.dataSource;
    if ([dataSource respondsToSelector:@selector(tableView:numberOfRowsInSection:)]) {
        return [dataSource tableView:tableView numberOfRowsInSection:section];
    }
    return 0;
}

static void FLEXStyleVisibleInternalCells(UITableViewController *controller) {
    UITableView *tableView = controller.tableView;
    if (!tableView) {
        return;
    }
    FLEXConfigureCompactRuntimeTable(tableView);
    for (UITableViewCell *cell in tableView.visibleCells) {
        NSIndexPath *indexPath = [tableView indexPathForCell:cell];
        if (!indexPath) {
            continue;
        }
        NSInteger count = FLEXInternalRowCount(tableView, indexPath.section);
        FLEXStyleCompactRuntimeCell(
            cell,
            FLEXCompactPositionForRow(indexPath.row, MAX(count, 1))
        );

        id configuration = cell.contentConfiguration;
        if ([configuration isKindOfClass:UIListContentConfiguration.class]) {
            UIListContentConfiguration *content =
                [(UIListContentConfiguration *)configuration copy];
            content.textProperties.font = FLEXInternalScaledFont(
                13.5,
                UIFontWeightMedium,
                UIFontTextStyleBody,
                17.0
            );
            content.secondaryTextProperties.font = FLEXInternalScaledFont(
                10.5,
                UIFontWeightRegular,
                UIFontTextStyleCaption1,
                13.0
            );
            content.secondaryTextProperties.numberOfLines = 2;
            content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(
                7.0, 14.0, 7.0, 12.0);
            cell.contentConfiguration = content;
        } else {
            cell.textLabel.font = FLEXInternalScaledFont(
                13.5,
                UIFontWeightMedium,
                UIFontTextStyleBody,
                17.0
            );
            cell.detailTextLabel.font = FLEXInternalScaledFont(
                10.5,
                UIFontWeightRegular,
                UIFontTextStyleCaption1,
                13.0
            );
        }
    }

    NSInteger sections = FLEXInternalSectionCount(tableView);
    for (NSInteger section = 0; section < sections; section++) {
        UITableViewHeaderFooterView *header = [tableView headerViewForSection:section];
        header.textLabel.font = FLEXInternalScaledFont(
            12.0,
            UIFontWeightSemibold,
            UIFontTextStyleSubheadline,
            14.5
        );
        header.textLabel.textColor = UIColor.secondaryLabelColor;
        UITableViewHeaderFooterView *footer = [tableView footerViewForSection:section];
        footer.textLabel.font = FLEXInternalScaledFont(
            10.5,
            UIFontWeightRegular,
            UIFontTextStyleCaption1,
            13.0
        );
    }

    UISearchController *search = controller.navigationItem.searchController;
    if (search) {
        search.searchBar.searchTextField.font = FLEXInternalScaledFont(
            13.5,
            UIFontWeightRegular,
            UIFontTextStyleBody,
            16.0
        );
        [FLEXLiquidGlass styleSearchBar:search.searchBar];
    }
}

static void FLEXBaseStyledViewDidLoad(id self, SEL _cmd) {
    if (FLEXBaseTableViewDidLoad) {
        FLEXBaseTableViewDidLoad(self, _cmd);
    }
    UITableViewController *controller = self;
    controller.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [FLEXLiquidGlass applyToViewController:controller];
    FLEXStyleVisibleInternalCells(controller);
}

static void FLEXBaseStyledViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (FLEXBaseTableViewWillAppear) {
        FLEXBaseTableViewWillAppear(self, _cmd, animated);
    }
    UITableViewController *controller = self;
    [FLEXLiquidGlass applyToViewController:controller];
    FLEXStyleVisibleInternalCells(controller);
}

static void FLEXBaseStyledViewDidLayoutSubviews(id self, SEL _cmd) {
    if (FLEXBaseTableViewDidLayoutSubviews) {
        FLEXBaseTableViewDidLayoutSubviews(self, _cmd);
    }
    FLEXStyleVisibleInternalCells((UITableViewController *)self);
}

static void FLEXInstallClassOverride(Class cls,
                                     SEL selector,
                                     IMP replacement,
                                     IMP *originalStorage) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }
    *originalStorage = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, selector, replacement, types)) {
        method_setImplementation(method, replacement);
    }
}

@interface FLEXCompactFLEXBaseStyleBootstrap : NSObject
@end

@implementation FLEXCompactFLEXBaseStyleBootstrap

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class base = NSClassFromString(@"FLEXTableViewController");
        if (!base) {
            return;
        }
        FLEXInstallClassOverride(
            base,
            @selector(viewDidLoad),
            (IMP)FLEXBaseStyledViewDidLoad,
            (IMP *)&FLEXBaseTableViewDidLoad
        );
        FLEXInstallClassOverride(
            base,
            @selector(viewWillAppear:),
            (IMP)FLEXBaseStyledViewWillAppear,
            (IMP *)&FLEXBaseTableViewWillAppear
        );
        FLEXInstallClassOverride(
            base,
            @selector(viewDidLayoutSubviews),
            (IMP)FLEXBaseStyledViewDidLayoutSubviews,
            (IMP *)&FLEXBaseTableViewDidLayoutSubviews
        );
    });
}

@end
