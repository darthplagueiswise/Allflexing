#import "FLEXCompactRuntimeUI.h"

#import "FLEXLiquidGlass.h"

#import <objc/runtime.h>

__attribute__((used)) static const char kFLEXNativeUIKitRenderingMarker[] =
    "AllFLEXing native UIKit rendering bootstrap ABI 1";

static void FLEXExchangeClassMethods(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getClassMethod(cls, original);
    Method replacementMethod = class_getClassMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

@implementation FLEXLiquidGlass (AllFLEXingNativeUIKitTables)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FLEXLiquidGlass.class;
        FLEXExchangeClassMethods(cls,
                                 @selector(styleTableView:),
                                 @selector(af_native_styleTableView:));
        FLEXExchangeClassMethods(cls,
                                 @selector(styleTableCell:),
                                 @selector(af_native_styleTableCell:));
        FLEXExchangeClassMethods(cls,
                                 @selector(styleSearchBar:),
                                 @selector(af_native_styleSearchBar:));
    });
}

+ (void)af_native_styleTableView:(UITableView *)tableView {
    if (!tableView) {
        return;
    }
    tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    tableView.opaque = YES;
    tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    tableView.separatorColor = UIColor.separatorColor;
    tableView.cellLayoutMarginsFollowReadableWidth = YES;
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    tableView.sectionHeaderTopPadding = 8.0;
}

+ (void)af_native_styleTableCell:(UITableViewCell *)cell {
    if (!cell) {
        return;
    }
    cell.backgroundView = nil;
    cell.selectedBackgroundView = nil;
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.preservesSuperviewLayoutMargins = YES;
}

+ (void)af_native_styleSearchBar:(UISearchBar *)searchBar {
    if (!searchBar) {
        return;
    }
    searchBar.searchBarStyle = UISearchBarStyleDefault;
    searchBar.backgroundImage = nil;
    UISearchTextField *field = searchBar.searchTextField;
    field.backgroundColor = nil;
    field.background = nil;
    field.borderStyle = UITextBorderStyleRoundedRect;
}

@end

static void (*FLEXBaseTableViewDidLoad)(id, SEL) = NULL;

static void FLEXBaseStyledViewDidLoad(id self, SEL _cmd) {
    if (FLEXBaseTableViewDidLoad) {
        FLEXBaseTableViewDidLoad(self, _cmd);
    }

    UITableViewController *controller = self;
    UITableView *tableView = controller.tableView;
    if (!tableView) {
        return;
    }

    tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    tableView.opaque = YES;
    tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    tableView.separatorColor = UIColor.separatorColor;
    tableView.cellLayoutMarginsFollowReadableWidth = YES;
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    tableView.sectionHeaderTopPadding = 8.0;
    tableView.rowHeight = UITableViewAutomaticDimension;
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
    });
}

@end
