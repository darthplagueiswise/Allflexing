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
@property (nonatomic) UIActivityIndicatorView *activityIndicator;
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

    self.scopeItem = [[UIBarButtonItem alloc]
        initWithTitle:@"App"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(chooseScope:)];
    UIBarButtonItem *reload = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(reloadScan)];
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithObjects:reload,
                                                                              self.scopeItem,
                                                                              nil];
    if (self.kind == FLEXRuntimeBrowserKindC) {
        UIBarButtonItem *add = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                 target:self
                                 action:@selector(addManualSymbol:)];
        [items insertObject:add atIndex:0];
    }
    self.navigationItem.rightBarButtonItems = items;

    self.activityIndicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryChanged:)
               name:FLEXHookRegistryDidChangeNotification
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
}

- (void)reloadScan {
    if (self.scanning) {
        return;
    }
    self.scanning = YES;
    self.navigationItem.titleView = self.activityIndicator;
    [self.activityIndicator startAnimating];

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
        [self.activityIndicator stopAnimating];
        self.navigationItem.titleView = nil;
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

- (void)chooseScope:(UIBarButtonItem *)sender {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"Runtime scope"
                         message:@"App images are safer and faster. System images are inspection-oriented."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Host app images"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        self.includeSystemImages = NO;
        self.scopeItem.title = @"App";
        [self reloadScan];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"All loaded images"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        self.includeSystemImages = YES;
        self.scopeItem.title = @"All";
        [self reloadScan];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.barButtonItem = sender;
    }
    [self presentViewController:sheet animated:YES completion:nil];
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
    cell.textLabel.text = entry.title;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@ · %@",
        entry.detail, entry.imageName, entry.statusSummary];
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryNone;

    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
    objc_setAssociatedObject(toggle,
                             kFLEXRuntimeBrowserEntryIDKey,
                             entry.identifier,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self
               action:@selector(toggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
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
        ? @"Only ABI-validated BOOL methods are toggleable. Apply revalidates the Method and type encoding."
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
    [FLEXHookRegistry.sharedRegistry stageEnabled:toggle.isOn
                               forEntryIdentifier:identifier];
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}

@end
