#import "FLEXHookEntryDetailController.h"

#import "FLEXCHookEngine.h"
#import "FLEXCompactRuntimeUI.h"
#import "FLEXHookRegistry.h"
#import "FLEXLiquidGlass.h"

typedef NS_ENUM(NSInteger, FLEXHookDetailSection) {
    FLEXHookDetailSectionTarget = 0,
    FLEXHookDetailSectionConfiguration,
    FLEXHookDetailSectionRuntime,
    FLEXHookDetailSectionCount,
};

@interface FLEXHookEntryDetailController ()
@property (nonatomic) FLEXHookEntry *entry;
@property (nonatomic) UIBarButtonItem *applyItem;
@end

@implementation FLEXHookEntryDetailController

- (instancetype)initWithEntry:(FLEXHookEntry *)entry {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _entry = entry;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.entry.title;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    FLEXConfigureCompactRuntimeTable(self.tableView);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 58.0;
    self.applyItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Apply"
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(applyNow)];
    if (@available(iOS 26.0, *)) {
        self.applyItem.style = UIBarButtonItemStyleProminent;
    }
    self.navigationItem.rightBarButtonItem = self.applyItem;
    [self setContentScrollView:self.tableView
                      forEdge:(NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom)];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryChanged:)
               name:FLEXHookRegistryDidChangeNotification
             object:nil];
    [FLEXLiquidGlass applyToViewController:self];
    [self updateNavigationState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self resolveCanonicalEntry];
    [self.tableView reloadData];
    [self updateNavigationState];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)resolveCanonicalEntry {
    FLEXHookEntry *latest = [FLEXHookRegistry.sharedRegistry
        entryForIdentifier:self.entry.identifier];
    if (latest) self.entry = latest;
}

- (FLEXHookEntry *)ensurePersistentEntry {
    [self resolveCanonicalEntry];
    if (self.entry.userConfigured) return self.entry;

    FLEXHookEntry *promoted = self.entry.copy;
    promoted.userConfigured = YES;
    FLEXHookEntry *resolved = [FLEXHookRegistry.sharedRegistry
        upsertDiscoveredEntry:promoted];
    if (resolved) self.entry = resolved;
    return resolved ?: promoted;
}

- (void)registryChanged:(NSNotification *)notification {
    (void)notification;
    [self resolveCanonicalEntry];
    [self.tableView reloadData];
    [self updateNavigationState];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return FLEXHookDetailSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case FLEXHookDetailSectionTarget: return 4;
        case FLEXHookDetailSectionConfiguration: return 4;
        case FLEXHookDetailSectionRuntime: return 3;
        default: return 0;
    }
}

- (UITableViewCell *)baseCellForTableView:(UITableView *)tableView {
    static NSString *identifier = @"AllFLEXingHookDetailCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleValue1
            reuseIdentifier:identifier];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)configureCell:(UITableViewCell *)cell
                  text:(NSString *)text
             secondary:(NSString *)secondary
                 image:(NSString *)image
                  tint:(UIColor *)tint {
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = text;
    content.textProperties.numberOfLines = 0;
    content.secondaryText = secondary;
    content.secondaryTextProperties.numberOfLines = 0;
    content.image = image.length ? [UIImage systemImageNamed:image] : nil;
    content.imageProperties.tintColor = tint;
    cell.contentConfiguration = content;
    [FLEXLiquidGlass styleTableCell:cell];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self baseCellForTableView:tableView];
    FLEXHookEntry *entry = self.entry;

    if (indexPath.section == FLEXHookDetailSectionTarget) {
        NSArray<NSString *> *titles = @[@"Surface", @"Target", @"Image", @"Locator"];
        NSArray<NSString *> *images = @[@"square.stack.3d.up", @"scope", @"shippingbox", @"number"];
        NSString *value = indexPath.row == 0
            ? FLEXHookSurfaceName(entry.surface)
            : (indexPath.row == 1
                ? entry.title
                : (indexPath.row == 2
                    ? (entry.imageName.length ? entry.imageName : @"Unknown")
                    : entry.identifier));
        [self configureCell:cell
                       text:titles[indexPath.row]
                  secondary:value
                      image:images[indexPath.row]
                       tint:UIColor.secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (indexPath.section == FLEXHookDetailSectionConfiguration) {
        BOOL configurableC = entry.surface == FLEXHookSurfaceCImport ||
            entry.surface == FLEXHookSurfaceCInline;
        if (indexPath.row == 0) {
            [self configureCell:cell
                           text:@"ABI profile"
                      secondary:FLEXHookABIName(entry.abi)
                          image:@"point.3.filled.connected.trianglepath.dotted"
                           tint:self.view.tintColor];
            cell.accessoryType = configurableC
                ? UITableViewCellAccessoryDisclosureIndicator
                : UITableViewCellAccessoryNone;
            cell.selectionStyle = configurableC
                ? UITableViewCellSelectionStyleDefault
                : UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            [self configureCell:cell
                           text:@"Hook backend"
                      secondary:FLEXHookBackendName(entry.backend)
                          image:@"cpu"
                           tint:self.view.tintColor];
            cell.accessoryType = configurableC
                ? UITableViewCellAccessoryDisclosureIndicator
                : UITableViewCellAccessoryNone;
            cell.selectionStyle = configurableC
                ? UITableViewCellSelectionStyleDefault
                : UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 2) {
            BOOL pointer = entry.abi == FLEXHookABICPointerNoArguments;
            NSString *result = pointer
                ? @"NULL"
                : (entry.abi == FLEXHookABICInt64NoArguments
                    ? (entry.forceValue ? @"1" : @"0")
                    : (entry.forceValue ? @"TRUE" : @"FALSE"));
            [self configureCell:cell
                           text:@"Forced result"
                      secondary:result
                          image:@"arrow.triangle.branch"
                           tint:UIColor.systemPurpleColor];
            UISwitch *toggle = [UISwitch new];
            toggle.on = entry.forceValue;
            toggle.enabled = entry.abi != FLEXHookABIUnknown && !pointer;
            [toggle sizeToFit];
            [toggle addTarget:self
                       action:@selector(forceChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            [self configureCell:cell
                           text:@"Runtime hook"
                      secondary:entry.pendingEnabled
                        ? @"Staged ON"
                        : @"Staged OFF"
                          image:@"bolt.circle"
                           tint:entry.pendingEnabled
                            ? UIColor.systemGreenColor
                            : UIColor.secondaryLabelColor];
            UISwitch *toggle = [UISwitch new];
            toggle.on = entry.pendingEnabled;
            toggle.enabled = (entry.available && entry.hookable) ||
                entry.pendingEnabled;
            [toggle sizeToFit];
            [toggle addTarget:self
                       action:@selector(enabledChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        return cell;
    }

    NSArray<NSString *> *titles = @[@"State", @"Calls", @"Provider"];
    NSArray<NSString *> *images = @[@"waveform.path.ecg", @"number.circle", @"shield.lefthalf.filled"];
    NSString *value = indexPath.row == 0
        ? entry.statusSummary
        : (indexPath.row == 1
            ? [NSString stringWithFormat:@"%lu total · %lu overridden",
                (unsigned long)entry.hitCount,
                (unsigned long)entry.overrideHitCount]
            : FLEXHookRegistry.sharedRegistry.providerName);
    [self configureCell:cell
                   text:titles[indexPath.row]
              secondary:value
                  image:images[indexPath.row]
                   tint:indexPath.row == 0 && entry.lastError.length
                    ? UIColor.systemRedColor
                    : UIColor.secondaryLabelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case FLEXHookDetailSectionTarget: return @"Target";
        case FLEXHookDetailSectionConfiguration: return @"Configuration";
        case FLEXHookDetailSectionRuntime: return @"Runtime";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == FLEXHookDetailSectionConfiguration) {
        if (self.entry.abi == FLEXHookABIUnknown) {
            return @"C targets remain inspection-only until an exact ABI is selected. Switches only stage changes; Apply performs installation.";
        }
        return @"No patch or hook is installed by these switches. Press Apply to commit the staged state.";
    }
    if (section == FLEXHookDetailSectionRuntime) return self.entry.detail;
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != FLEXHookDetailSectionConfiguration) return;
    BOOL configurableC = self.entry.surface == FLEXHookSurfaceCImport ||
        self.entry.surface == FLEXHookSurfaceCInline;
    if (!configurableC) return;
    if (indexPath.row == 0) {
        [self presentABIChooserFromCell:[tableView cellForRowAtIndexPath:indexPath]];
    } else if (indexPath.row == 1) {
        [self presentBackendChooserFromCell:[tableView cellForRowAtIndexPath:indexPath]];
    }
}

- (void)updateNavigationState {
    BOOL pending = self.entry.pendingEnabled != self.entry.desiredEnabled ||
        (self.entry.desiredEnabled && !self.entry.installed);
    self.applyItem.enabled = pending && !FLEXHookRegistry.sharedRegistry.isApplying;
    if (@available(iOS 26.0, *)) {
        self.navigationItem.subtitle = self.entry.statusSummary;
    }
}

- (void)presentABIChooserFromCell:(UITableViewCell *)cell {
    FLEXHookEntry *entry = [self ensurePersistentEntry];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"C ABI profile"
                         message:@"Choose only a signature verified for this symbol."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *abis = @[
        @(FLEXHookABICBoolNoArguments),
        @(FLEXHookABICBoolPointerArgument),
        @(FLEXHookABICInt64NoArguments),
        @(FLEXHookABICPointerNoArguments),
    ];
    for (NSNumber *number in abis) {
        FLEXHookABI abi = number.integerValue;
        [sheet addAction:[UIAlertAction actionWithTitle:FLEXHookABIName(abi)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [FLEXHookRegistry.sharedRegistry
                configureEntryIdentifier:entry.identifier
                                      abi:abi
                                  backend:entry.backend == FLEXHookBackendNone
                                    ? FLEXHookBackendAuto
                                    : entry.backend];
            [self resolveCanonicalEntry];
            [FLEXCHookEngine refreshAvailabilityForEntry:self.entry];
            [self.tableView reloadData];
            [self updateNavigationState];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Inspection only"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [FLEXHookRegistry.sharedRegistry
            configureEntryIdentifier:entry.identifier
                                  abi:FLEXHookABIUnknown
                              backend:FLEXHookBackendNone];
        [self resolveCanonicalEntry];
        [self.tableView reloadData];
        [self updateNavigationState];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self anchorSheet:sheet toCell:cell];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentBackendChooserFromCell:(UITableViewCell *)cell {
    FLEXHookEntry *entry = [self ensurePersistentEntry];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"Hook backend"
                         message:@"Invalid providers stay disabled and fail closed."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *backends = @[
        @(FLEXHookBackendAuto),
        @(FLEXHookBackendFishhook),
        @(FLEXHookBackendInlineElleKit),
    ];
    for (NSNumber *number in backends) {
        FLEXHookBackend backend = number.integerValue;
        BOOL fishhookPossible = [entry.locator[@"bindSlots"] unsignedIntegerValue] > 0;
        if (backend == FLEXHookBackendFishhook && !fishhookPossible) continue;
        [sheet addAction:[UIAlertAction actionWithTitle:FLEXHookBackendName(backend)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [FLEXHookRegistry.sharedRegistry
                configureEntryIdentifier:entry.identifier
                                      abi:entry.abi
                                  backend:backend];
            [self resolveCanonicalEntry];
            [FLEXCHookEngine refreshAvailabilityForEntry:self.entry];
            [self.tableView reloadData];
            [self updateNavigationState];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self anchorSheet:sheet toCell:cell];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)anchorSheet:(UIAlertController *)sheet toCell:(UITableViewCell *)cell {
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover && cell) {
        popover.sourceView = cell;
        popover.sourceRect = cell.bounds;
        popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
}

- (void)forceChanged:(UISwitch *)toggle {
    FLEXHookEntry *entry = [self ensurePersistentEntry];
    [FLEXHookRegistry.sharedRegistry
        stageForceValue:toggle.isOn
     forEntryIdentifier:entry.identifier];
    [self resolveCanonicalEntry];
    [UISelectionFeedbackGenerator.new selectionChanged];
    [self.tableView reloadData];
    [self updateNavigationState];
}

- (void)enabledChanged:(UISwitch *)toggle {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL requested = toggle.isOn;
    FLEXHookEntry *entry = requested ? [self ensurePersistentEntry] : self.entry;
    if (requested && !entry.userConfigured) {
        [registry stageForceValue:YES forEntryIdentifier:entry.identifier];
    }
    [registry stageEnabled:requested forEntryIdentifier:entry.identifier];
    [self resolveCanonicalEntry];
    BOOL accepted = self.entry.pendingEnabled == requested;
    [toggle setOn:accepted ? requested : !requested animated:YES];
    if (accepted) {
        [UISelectionFeedbackGenerator.new selectionChanged];
    } else {
        [UINotificationFeedbackGenerator.new
            notificationOccurred:UINotificationFeedbackTypeError];
    }
    [self.tableView reloadData];
    [self updateNavigationState];
}

- (void)applyNow {
    FLEXHookEntry *entry = [self ensurePersistentEntry];
    self.applyItem.enabled = NO;
    [FLEXHookRegistry.sharedRegistry
        applyEntryIdentifier:entry.identifier
                  completion:^(NSArray<FLEXHookEntry *> *applied,
                               NSArray<FLEXHookEntry *> *failed) {
        [self resolveCanonicalEntry];
        [self.tableView reloadData];
        [self updateNavigationState];
        NSString *message = [NSString stringWithFormat:@"Applied: %lu\nFailed: %lu",
            (unsigned long)applied.count,
            (unsigned long)failed.count];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:failed.count
                ? @"Applied with errors"
                : @"Hooks updated"
            message:message
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

@end
