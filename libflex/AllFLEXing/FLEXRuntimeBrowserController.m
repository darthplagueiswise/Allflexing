#import "FLEXRuntimeBrowserController.h"

#import "FLEXCHookEngine.h"
#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXLiquidGlass.h"
#import "FLEXRuntimeScanner.h"

#import <objc/runtime.h>

static const void *kFLEXRuntimeBrowserEntryIDKey = &kFLEXRuntimeBrowserEntryIDKey;

@interface FLEXRuntimeBrowserController () <UISearchResultsUpdating>
@property (nonatomic) FLEXRuntimeBrowserKind kind;
@property (nonatomic) BOOL includeSystemImages;
@property (nonatomic) BOOL scanning;
@property (nonatomic) UISearchController *searchController;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *filteredEntries;
@property (nonatomic) UIBarButtonItem *scopeItem;
@property (nonatomic) UIBarButtonItem *reloadItem;
@end

@implementation FLEXRuntimeBrowserController

- (instancetype)initWithKind:(FLEXRuntimeBrowserKind)kind {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _kind = kind;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.kind == FLEXRuntimeBrowserKindObjectiveC
        ? @"Objective-C Runtime" : @"C Runtime";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 74.0;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"Class, selector, symbol, image";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self setContentScrollView:self.tableView
                      forEdge:(NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom)];

    self.scopeItem = [[UIBarButtonItem alloc]
        initWithTitle:@"App images"
                 menu:[self scopeMenu]];
    self.reloadItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(reloadScan)];
    UIBarButtonItem *separator = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace
                             target:nil
                             action:nil];
    separator.width = 8.0;
    if (@available(iOS 26.0, *)) {
        separator.hidesSharedBackground = YES;
    }
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithObjects:
        self.reloadItem, separator, self.scopeItem, nil];
    if (self.kind == FLEXRuntimeBrowserKindC) {
        UIBarButtonItem *add = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                 target:self
                                 action:@selector(addManualSymbol:)];
        [items insertObject:add atIndex:0];
    }
    self.navigationItem.rightBarButtonItems = items;

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryChanged:)
               name:FLEXHookRegistryDidChangeNotification
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(runtimeImagesChanged:)
               name:FLEXRuntimeImagesDidChangeNotification
             object:nil];
    [self reloadEntries];
    [self reloadScan];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadEntries];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)registryChanged:(NSNotification *)notification {
    (void)notification;
    [self reloadEntries];
}

- (void)runtimeImagesChanged:(NSNotification *)notification {
    (void)notification;
    if (self.viewIfLoaded.window) {
        [self reloadScan];
    }
}

- (void)reloadEntries {
    NSArray<FLEXHookEntry *> *entries = FLEXHookRegistry.sharedRegistry.entries;
    NSString *query = self.searchController.searchBar.text.lowercaseString ?: @"";
    NSMutableArray<FLEXHookEntry *> *filtered = [NSMutableArray array];
    for (FLEXHookEntry *entry in entries) {
        BOOL surfaceMatches = self.kind == FLEXRuntimeBrowserKindObjectiveC
            ? entry.surface == FLEXHookSurfaceObjectiveC
            : (entry.surface == FLEXHookSurfaceCImport ||
               entry.surface == FLEXHookSurfaceCInline);
        if (!surfaceMatches) {
            continue;
        }
        if (query.length) {
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@",
                entry.title, entry.detail, entry.imageName, entry.identifier].lowercaseString;
            if ([haystack rangeOfString:query].location == NSNotFound) {
                continue;
            }
        }
        [filtered addObject:entry];
    }
    self.filteredEntries = filtered.copy;
    [self.tableView reloadData];
    [self updateNavigationStatus];
    [self updateUnavailableConfiguration];
}

- (void)reloadScan {
    if (self.scanning) {
        return;
    }
    self.scanning = YES;
    self.reloadItem.enabled = NO;
    self.scopeItem.enabled = NO;
    [self updateNavigationStatus];
    [self updateUnavailableConfiguration];

    __weak typeof(self) weakSelf = self;
    FLEXRuntimeScanCompletion completion = ^(NSArray<FLEXHookEntry *> *entries) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        FLEXHookSurface surface = self.kind == FLEXRuntimeBrowserKindObjectiveC
            ? FLEXHookSurfaceObjectiveC : FLEXHookSurfaceCImport;
        [FLEXHookRegistry.sharedRegistry mergeDiscoveredEntries:entries surface:surface];
        self.scanning = NO;
        self.reloadItem.enabled = YES;
        self.scopeItem.enabled = YES;
        [self reloadEntries];
    };

    if (self.kind == FLEXRuntimeBrowserKindObjectiveC) {
        [FLEXRuntimeScanner
            scanObjectiveCRuntimeIncludingSystemImages:self.includeSystemImages
                                             completion:completion];
    } else {
        [FLEXRuntimeScanner
            scanCImportsIncludingSystemImages:self.includeSystemImages
                                    completion:completion];
    }
}

- (UIMenu *)scopeMenu {
    __weak typeof(self) weakSelf = self;
    UIAction *app = [UIAction
        actionWithTitle:@"Host app images"
                  image:[UIImage systemImageNamed:@"app"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        weakSelf.includeSystemImages = NO;
        weakSelf.scopeItem.title = @"App images";
        weakSelf.scopeItem.menu = [weakSelf scopeMenu];
        [weakSelf reloadScan];
    }];
    app.state = self.includeSystemImages ? UIMenuElementStateOff : UIMenuElementStateOn;
    UIAction *all = [UIAction
        actionWithTitle:@"All loaded images"
                  image:[UIImage systemImageNamed:@"square.stack.3d.up"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        weakSelf.includeSystemImages = YES;
        weakSelf.scopeItem.title = @"All images";
        weakSelf.scopeItem.menu = [weakSelf scopeMenu];
        [weakSelf reloadScan];
    }];
    all.state = self.includeSystemImages ? UIMenuElementStateOn : UIMenuElementStateOff;
    return [UIMenu menuWithTitle:@"Runtime scope"
                         image:nil
                    identifier:nil
                       options:UIMenuOptionsDisplayInline
                      children:@[app, all]];
}

- (void)addManualSymbol:(UIBarButtonItem *)sender {
    (void)sender;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Add inline C target"
                         message:@"The symbol must resolve in the current process. Choose its exact ABI on the next screen."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Symbol name";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Image name (optional)";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *symbol = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *image = [alert.textFields.lastObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (symbol.length == 0) {
            return;
        }
        FLEXHookEntry *entry = [FLEXRuntimeScanner manualCEntryForSymbol:symbol
                                                               imageName:image];
        [FLEXCHookEngine refreshAvailabilityForEntry:entry];
        [FLEXHookRegistry.sharedRegistry addOrUpdateManualEntry:entry];
        FLEXHookEntryDetailController *detail =
            [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
        [self.navigationController pushViewController:detail animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    (void)searchController;
    [self reloadEntries];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.filteredEntries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"AllFLEXingRuntimeBrowserCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    FLEXHookEntry *entry = self.filteredEntries[indexPath.row];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = entry.title;
    content.secondaryText = [NSString stringWithFormat:@"%@\n%@ · %@",
        entry.detail, entry.imageName, entry.statusSummary];
    content.secondaryTextProperties.numberOfLines = 0;
    content.image = [UIImage systemImageNamed:entry.effectiveEnabled
        ? (entry.overrideHitCount > 0 ? @"checkmark.circle.fill" : @"bolt.circle.fill")
        : (entry.hookable ? @"circle.dashed" : @"eye")];
    content.imageProperties.tintColor = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0 ? UIColor.systemGreenColor : UIColor.systemBlueColor)
        : (entry.hookable ? self.view.tintColor : UIColor.secondaryLabelColor);
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryNone;

    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
    [toggle sizeToFit];
    toggle.accessibilityLabel = [NSString stringWithFormat:@"Runtime hook for %@", entry.title];
    toggle.accessibilityValue = entry.statusSummary;
    objc_setAssociatedObject(toggle,
                             kFLEXRuntimeBrowserEntryIDKey,
                             entry.identifier,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self
               action:@selector(toggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    [FLEXLiquidGlass styleTableCell:cell];
    return cell;
}

- (void)updateNavigationStatus {
    NSString *status = self.scanning
        ? @"Scanning safely in the background…"
        : [NSString stringWithFormat:@"%lu discovered target(s)",
            (unsigned long)self.filteredEntries.count];
    if (@available(iOS 26.0, *)) {
        self.navigationItem.subtitle = status;
    }
}

- (void)updateUnavailableConfiguration {
    if (@available(iOS 17.0, *)) {
        if (self.filteredEntries.count) {
            self.contentUnavailableConfiguration = nil;
            return;
        }
        UIContentUnavailableConfiguration *configuration = self.scanning
            ? [UIContentUnavailableConfiguration loadingConfiguration]
            : (self.searchController.searchBar.text.length
                ? [UIContentUnavailableConfiguration searchConfiguration]
                : [UIContentUnavailableConfiguration emptyConfiguration]);
        configuration.text = self.scanning ? @"Scanning runtime" : @"No matching targets";
        configuration.secondaryText = self.scanning
            ? @"Class and Mach-O work is running away from the main thread."
            : @"Change the search or runtime scope, then scan again.";
        self.contentUnavailableConfiguration = configuration;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if (self.scanning) {
        return @"Scanning safely in the background…";
    }
    return [NSString stringWithFormat:@"%lu runtime entries",
        (unsigned long)self.filteredEntries.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.kind == FLEXRuntimeBrowserKindObjectiveC
        ? @"Only ABI-validated BOOL methods are toggleable. Each switch revalidates and applies its target immediately."
        : @"Imported symbols are listed from Mach-O bind sections. A C toggle remains disabled until an explicit ABI is selected.";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FLEXHookEntry *entry = self.filteredEntries[indexPath.row];
    FLEXHookEntryDetailController *detail =
        [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)toggleChanged:(UISwitch *)toggle {
    NSString *identifier = objc_getAssociatedObject(toggle, kFLEXRuntimeBrowserEntryIDKey);
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL requestedState = toggle.isOn;
    FLEXHookEntry *entry = [registry entryForIdentifier:identifier];
    if (requestedState && entry && !entry.userConfigured) {
        [registry stageForceValue:YES forEntryIdentifier:identifier];
    }
    [registry stageEnabled:requestedState forEntryIdentifier:identifier];
    entry = [registry entryForIdentifier:identifier];
    if (!entry || entry.pendingEnabled != requestedState) {
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeError];
        [self reloadEntries];
        return;
    }
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
    __weak typeof(self) weakSelf = self;
    [registry applyEntryIdentifier:identifier completion:^(
        __unused NSArray<FLEXHookEntry *> *applied,
        NSArray<FLEXHookEntry *> *failed
    ) {
        UINotificationFeedbackGenerator *resultFeedback = [UINotificationFeedbackGenerator new];
        FLEXHookEntry *resolved = [registry entryForIdentifier:identifier];
        UINotificationFeedbackType feedbackType = failed.count
            ? UINotificationFeedbackTypeError
            : (resolved.overrideHitCount > 0
                ? UINotificationFeedbackTypeSuccess
                : UINotificationFeedbackTypeWarning);
        [resultFeedback notificationOccurred:feedbackType];
        [weakSelf reloadEntries];
    }];
}

@end
