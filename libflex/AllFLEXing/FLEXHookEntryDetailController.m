#import "FLEXHookEntryDetailController.h"

#import "FLEXCHookEngine.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"
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
    if (self) {
        _entry = entry;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.entry.title;
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
    [self setContentScrollView:self.tableView
                      forEdge:(NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom)];
    self.navigationItem.rightBarButtonItem = self.applyItem;
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryChanged:)
               name:FLEXHookRegistryDidChangeNotification
             object:nil];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    FLEXHookEntry *latest = [FLEXHookRegistry.sharedRegistry
        entryForIdentifier:self.entry.identifier];
    if (latest) {
        self.entry = latest;
    }
    [self.tableView reloadData];
    [self updateNavigationState];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)registryChanged:(NSNotification *)notification {
    (void)notification;
    FLEXHookEntry *latest = [FLEXHookRegistry.sharedRegistry
        entryForIdentifier:self.entry.identifier];
    if (latest) {
        self.entry = latest;
    }
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
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:identifier];
    }
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.textColor = UIColor.labelColor;
    return cell;
}

- (void)configureCell:(UITableViewCell *)cell
                  text:(NSString *)text
             secondary:(NSString *)secondary
                 image:(NSString *)image
                  tint:(UIColor *)tint {
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = text;
    content.secondaryText = secondary;
    content.secondaryTextProperties.numberOfLines = 0;
    content.image = image.length ? [UIImage systemImageNamed:image] : nil;
    content.imageProperties.tintColor = tint;
    cell.contentConfiguration = content;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self baseCellForTableView:tableView];
    FLEXHookEntry *entry = self.entry;

    if (indexPath.section == FLEXHookDetailSectionTarget) {
        NSArray<NSString *> *titles = @[@"Surface", @"Target", @"Image", @"Locator"];
        NSString *value = nil;
        if (indexPath.row == 0) {
            value = FLEXHookSurfaceName(entry.surface);
        } else if (indexPath.row == 1) {
            value = entry.title;
        } else if (indexPath.row == 2) {
            value = entry.imageName.length ? entry.imageName : @"Unknown";
        } else {
            value = entry.identifier;
        }
        NSArray<NSString *> *images = @[@"square.stack.3d.up", @"scope", @"shippingbox", @"number"];
        [self configureCell:cell
                       text:titles[indexPath.row]
                  secondary:value
                      image:images[indexPath.row]
                       tint:UIColor.secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (indexPath.section == FLEXHookDetailSectionConfiguration) {
        if (indexPath.row == 0) {
            [self configureCell:cell
                           text:@"ABI profile"
                      secondary:FLEXHookABIName(entry.abi)
                          image:@"point.3.filled.connected.trianglepath.dotted"
                           tint:self.view.tintColor];
            BOOL configurable = entry.surface == FLEXHookSurfaceCImport ||
                                entry.surface == FLEXHookSurfaceCInline;
            cell.accessoryType = configurable
                ? UITableViewCellAccessoryDisclosureIndicator
                : UITableViewCellAccessoryNone;
            cell.selectionStyle = configurable
                ? UITableViewCellSelectionStyleDefault
                : UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 1) {
            [self configureCell:cell
                           text:@"Hook backend"
                      secondary:FLEXHookBackendName(entry.backend)
                          image:@"cpu"
                           tint:self.view.tintColor];
            BOOL configurable = entry.surface == FLEXHookSurfaceCImport ||
                                entry.surface == FLEXHookSurfaceCInline;
            cell.accessoryType = configurable
                ? UITableViewCellAccessoryDisclosureIndicator
                : UITableViewCellAccessoryNone;
            cell.selectionStyle = configurable
                ? UITableViewCellSelectionStyleDefault
                : UITableViewCellSelectionStyleNone;
        } else if (indexPath.row == 2) {
            [self configureCell:cell
                           text:@"Forced result"
                      secondary:entry.forceValue ? @"TRUE" : @"FALSE"
                          image:@"arrow.triangle.branch"
                           tint:UIColor.systemPurpleColor];
            UISwitch *toggle = [UISwitch new];
            toggle.on = entry.forceValue;
            toggle.enabled = entry.abi != FLEXHookABIUnknown;
            [toggle sizeToFit];
            [toggle addTarget:self
                       action:@selector(forceChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            [self configureCell:cell
                           text:@"Runtime hook"
                      secondary:entry.pendingEnabled ? @"Requested ON" : @"Requested OFF"
                          image:@"bolt.circle"
                           tint:entry.pendingEnabled ? UIColor.systemGreenColor : UIColor.secondaryLabelColor];
            UISwitch *toggle = [UISwitch new];
            toggle.on = entry.pendingEnabled;
            toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
            [toggle sizeToFit];
            [toggle addTarget:self
                       action:@selector(enabledChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        return cell;
    }

    if (indexPath.section == FLEXHookDetailSectionRuntime) {
        NSArray<NSString *> *titles = @[@"State", @"Calls", @"Provider"];
        NSArray<NSString *> *images = @[@"waveform.path.ecg", @"number.circle", @"shield.lefthalf.filled"];
        NSString *value = nil;
        if (indexPath.row == 0) {
            value = entry.statusSummary;
        } else if (indexPath.row == 1) {
            value = [NSString stringWithFormat:@"%lu",
                (unsigned long)entry.hitCount];
        } else {
            value = FLEXHookRegistry.sharedRegistry.providerName;
        }
        [self configureCell:cell
                       text:titles[indexPath.row]
                  secondary:value
                      image:images[indexPath.row]
                       tint:indexPath.row == 0 && entry.lastError.length
                            ? UIColor.systemRedColor : UIColor.secondaryLabelColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
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
            return @"C symbols remain inspection-only until you choose an exact ABI. Auto uses fishhook for a confirmed import slot and ElleKit inline otherwise.";
        }
        return @"Disabling keeps the installed patch but immediately forwards calls to the original implementation.";
    }
    if (section == FLEXHookDetailSectionRuntime) {
        return self.entry.detail;
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == FLEXHookDetailSectionConfiguration && indexPath.row == 0 &&
        (self.entry.surface == FLEXHookSurfaceCImport ||
         self.entry.surface == FLEXHookSurfaceCInline)) {
        [self presentABIChooserFromCell:[tableView cellForRowAtIndexPath:indexPath]];
        return;
    }
    if (indexPath.section == FLEXHookDetailSectionConfiguration && indexPath.row == 1 &&
        (self.entry.surface == FLEXHookSurfaceCImport ||
         self.entry.surface == FLEXHookSurfaceCInline)) {
        [self presentBackendChooserFromCell:[tableView cellForRowAtIndexPath:indexPath]];
        return;
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
                configureEntryIdentifier:self.entry.identifier
                                      abi:abi
                                  backend:self.entry.backend == FLEXHookBackendNone
                                      ? FLEXHookBackendAuto : self.entry.backend];
            [FLEXCHookEngine refreshAvailabilityForEntry:self.entry];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Inspection only"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [FLEXHookRegistry.sharedRegistry
            configureEntryIdentifier:self.entry.identifier
                                  abi:FLEXHookABIUnknown
                              backend:FLEXHookBackendNone];
        [self.tableView reloadData];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self anchorSheet:sheet toCell:cell];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentBackendChooserFromCell:(UITableViewCell *)cell {
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
        BOOL fishhookPossible = [self.entry.locator[@"bindSlots"] unsignedIntegerValue] > 0;
        if (backend == FLEXHookBackendFishhook && !fishhookPossible) {
            continue;
        }
        [sheet addAction:[UIAlertAction actionWithTitle:FLEXHookBackendName(backend)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [FLEXHookRegistry.sharedRegistry
                configureEntryIdentifier:self.entry.identifier
                                      abi:self.entry.abi
                                  backend:backend];
            [FLEXCHookEngine refreshAvailabilityForEntry:self.entry];
            [self.tableView reloadData];
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
    [FLEXHookRegistry.sharedRegistry stageForceValue:toggle.isOn
                                 forEntryIdentifier:self.entry.identifier];
    [FLEXCHookEngine setEnabled:self.entry.effectiveEnabled forEntry:self.entry];
}

- (void)enabledChanged:(UISwitch *)toggle {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL requestedState = toggle.isOn;
    [registry stageEnabled:requestedState forEntryIdentifier:self.entry.identifier];
    if (self.entry.pendingEnabled != requestedState) {
        [toggle setOn:self.entry.pendingEnabled animated:YES];
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeError];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [registry applyEntryIdentifier:self.entry.identifier completion:^(
        __unused NSArray<FLEXHookEntry *> *applied,
        NSArray<FLEXHookEntry *> *failed
    ) {
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:failed.count
            ? UINotificationFeedbackTypeError
            : UINotificationFeedbackTypeSuccess];
        [weakSelf.tableView reloadData];
    }];
}

- (void)applyNow {
    [FLEXHookRegistry.sharedRegistry applyEntryIdentifier:self.entry.identifier completion:^(
        NSArray<FLEXHookEntry *> *applied,
        NSArray<FLEXHookEntry *> *failed
    ) {
        NSString *message = [NSString stringWithFormat:@"Applied: %lu\nFailed: %lu",
            (unsigned long)applied.count, (unsigned long)failed.count];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:
            failed.count ? @"Applied with errors" : @"Hooks updated"
            message:message
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

@end
