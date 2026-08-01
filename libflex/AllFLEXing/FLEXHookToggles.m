#import "FLEXHookToggles.h"

#import "FLEXHookEntryDetailController.h"
#import "FLEXHookPersistence.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"
#import "FLEXLiquidGlass.h"
#import "FLEXRuntimeBrowserController.h"
#import "FLEXSymbolRebind.h"

#import <objc/runtime.h>
#import <stdlib.h>

static const void *kFLEXHookCenterIdentifierKey = &kFLEXHookCenterIdentifierKey;

typedef NS_ENUM(NSInteger, FLEXHookCenterSection) {
    FLEXHookCenterSectionStatus = 0,
    FLEXHookCenterSectionPending,
    FLEXHookCenterSectionActive,
    FLEXHookCenterSectionBrowsers,
    FLEXHookCenterSectionSettings,
    FLEXHookCenterSectionDiagnostics,
    FLEXHookCenterSectionCount,
};

@interface FLEXHookToggles ()
@property (nonatomic, copy) NSArray<FLEXHookFlag *> *flags;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *pendingEntries;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *activeEntries;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *failedEntries;
@property (nonatomic) UIBarButtonItem *applyItem;
@property (nonatomic) UIBarButtonItem *discardItem;
@property (nonatomic) UIBarButtonItem *restartItem;
@end

@implementation FLEXHookToggles

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hook Center";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 72.0;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;

    self.discardItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Discard"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(discardPending)];
    self.applyItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Apply"
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(applyPending)];
    self.restartItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Apply & Restart"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(applyAndRestart)];
    if (@available(iOS 26.0, *)) {
        self.applyItem.style = UIBarButtonItemStyleProminent;
    }

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryChanged:)
               name:FLEXHookRegistryDidChangeNotification
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(flagsChanged:)
               name:FLEXHookFlagsDidChangeNotification
             object:nil];
    [self reloadState];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadState];
    [self.navigationController setToolbarHidden:NO animated:animated];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController) {
        [self.navigationController setToolbarHidden:YES animated:animated];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)registryChanged:(NSNotification *)notification {
    (void)notification;
    [self reloadState];
}

- (void)flagsChanged:(NSNotification *)notification {
    (void)notification;
    [FLEXHookRegistry.sharedRegistry refreshCapabilities];
    [self reloadState];
}

- (void)reloadState {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    self.flags = FLEXHookPersistence.sharedManager.registeredFlags;

    NSMutableArray<FLEXHookEntry *> *pending = [NSMutableArray array];
    NSMutableArray<FLEXHookEntry *> *active = [NSMutableArray array];
    NSMutableArray<FLEXHookEntry *> *failed = [NSMutableArray array];
    for (FLEXHookEntry *entry in registry.entries) {
        if (entry.pendingEnabled != entry.desiredEnabled ||
            (entry.desiredEnabled && !entry.installed)) {
            [pending addObject:entry];
        }
        if (entry.installed) {
            [active addObject:entry];
        }
        if (entry.lastError.length) {
            [failed addObject:entry];
        }
    }
    self.pendingEntries = pending.copy;
    self.activeEntries = active.copy;
    self.failedEntries = failed.copy;
    [self.tableView reloadData];
    [self updateToolbarAnimated:YES];
}

- (void)updateToolbarAnimated:(BOOL)animated {
    BOOL hasPending = FLEXHookRegistry.sharedRegistry.hasPendingChanges;
    BOOL applying = FLEXHookRegistry.sharedRegistry.isApplying;
    self.applyItem.enabled = hasPending && !applying;
    self.discardItem.enabled = hasPending && !applying;
    self.restartItem.enabled = !applying;

    UIBarButtonItem *flexibleA = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                             target:nil
                             action:nil];
    UIBarButtonItem *flexibleB = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                             target:nil
                             action:nil];
    if (@available(iOS 26.0, *)) {
        // These actions have different consequences. Keep the flexible spaces
        // as real glass separators; the system can then give Apply its own
        // prominent material instead of stretching one giant pill edge-to-edge.
        flexibleA.hidesSharedBackground = YES;
        flexibleB.hidesSharedBackground = YES;
    }
    NSArray *items = @[
        self.discardItem,
        flexibleA,
        self.applyItem,
        flexibleB,
        self.restartItem,
    ];
    BOOL shouldAnimate = animated && !UIAccessibilityIsReduceMotionEnabled();
    [self setToolbarItems:items animated:shouldAnimate];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return FLEXHookCenterSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case FLEXHookCenterSectionStatus: return 3;
        case FLEXHookCenterSectionPending: return MAX((NSInteger)self.pendingEntries.count, 1);
        case FLEXHookCenterSectionActive: return MAX((NSInteger)self.activeEntries.count, 1);
        case FLEXHookCenterSectionBrowsers: return 2;
        case FLEXHookCenterSectionSettings: return self.flags.count;
        case FLEXHookCenterSectionDiagnostics: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)cellForTableView:(UITableView *)tableView identifier:(NSString *)identifier {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self cellForTableView:tableView
                                        identifier:@"AllFLEXingHookCenterCell"];
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;

    if (indexPath.section == FLEXHookCenterSectionStatus) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Hook provider";
            cell.detailTextLabel.text = registry.providerName;
            cell.imageView.image = [UIImage systemImageNamed:
                FLEXMSHookProviderAvailable() ? @"checkmark.shield.fill" : @"exclamationmark.shield.fill"];
            cell.imageView.tintColor = FLEXMSHookProviderAvailable()
                ? UIColor.systemGreenColor : UIColor.systemRedColor;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Engines";
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"Objective-C: %@\nC imports: %@\nC inline: %@",
                FLEXMSHookMessageProviderAvailable() ? @"MSHookMessageEx ready" : @"unavailable",
                FLEXSymbolRebind.backendDescription,
                FLEXMSHookFunctionProviderAvailable() ? @"MSHookFunction ready" : @"unavailable"];
            cell.imageView.image = [UIImage systemImageNamed:@"gearshape.2.fill"];
        } else {
            cell.textLabel.text = @"Runtime summary";
            cell.detailTextLabel.text = [NSString stringWithFormat:
                @"%lu active · %lu pending · %lu errors",
                (unsigned long)registry.activeCount,
                (unsigned long)registry.pendingCount,
                (unsigned long)registry.failureCount];
            cell.imageView.image = [UIImage systemImageNamed:@"waveform.path.ecg"];
        }
        return cell;
    }

    if (indexPath.section == FLEXHookCenterSectionPending) {
        if (self.pendingEntries.count == 0) {
            cell.textLabel.text = @"No pending changes";
            cell.detailTextLabel.text = @"Runtime and persisted intent are synchronized.";
            cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            FLEXHookEntry *entry = self.pendingEntries[indexPath.row];
            [self configureEntryCell:cell entry:entry];
        }
        return cell;
    }

    if (indexPath.section == FLEXHookCenterSectionActive) {
        if (self.activeEntries.count == 0) {
            cell.textLabel.text = @"No installed runtime hooks";
            cell.detailTextLabel.text = @"Browse a runtime surface and stage a validated target.";
            cell.imageView.image = [UIImage systemImageNamed:@"power"];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            FLEXHookEntry *entry = self.activeEntries[indexPath.row];
            [self configureEntryCell:cell entry:entry];
        }
        return cell;
    }

    if (indexPath.section == FLEXHookCenterSectionBrowsers) {
        BOOL objc = indexPath.row == 0;
        cell.textLabel.text = objc ? @"Objective-C Runtime" : @"C Runtime";
        cell.detailTextLabel.text = objc
            ? @"ABI-validated BOOL methods with live per-target toggles"
            : @"Mach-O imports, explicit ABI profiles, fishhook and inline hooks";
        cell.imageView.image = [UIImage systemImageNamed:objc ? @"curlybraces" : @"function"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (indexPath.section == FLEXHookCenterSectionSettings) {
        FLEXHookFlag *flag = self.flags[indexPath.row];
        cell.textLabel.text = flag.title;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@",
            flag.detail, flag.identifier];
        UISwitch *toggle = [UISwitch new];
        toggle.on = [FLEXHookPersistence.sharedManager boolForFlag:flag.identifier];
        objc_setAssociatedObject(toggle,
                                 kFLEXHookCenterIdentifierKey,
                                 flag.identifier,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        [toggle addTarget:self
                   action:@selector(featureToggleChanged:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (indexPath.row == 0) {
        cell.textLabel.text = registry.safeMode ? @"Safe mode active" : @"Safe mode";
        cell.detailTextLabel.text = registry.safeMode
            ? [NSString stringWithFormat:@"Blocked target: %@",
                registry.safeModeEntryIdentifier ?: @"unknown"]
            : @"No interrupted hook transaction detected.";
        cell.imageView.image = [UIImage systemImageNamed:
            registry.safeMode ? @"shield.lefthalf.filled.badge.checkmark" : @"shield.checkered"];
        cell.accessoryType = registry.safeMode
            ? UITableViewCellAccessoryDisclosureIndicator
            : UITableViewCellAccessoryNone;
        cell.selectionStyle = registry.safeMode
            ? UITableViewCellSelectionStyleDefault
            : UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = @"Errors and stale targets";
        cell.detailTextLabel.text = self.failedEntries.count
            ? [NSString stringWithFormat:@"%lu entries need attention",
                (unsigned long)self.failedEntries.count]
            : @"No runtime errors.";
        cell.imageView.image = [UIImage systemImageNamed:self.failedEntries.count
            ? @"exclamationmark.triangle.fill" : @"checkmark.seal.fill"];
        cell.imageView.tintColor = self.failedEntries.count
            ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
        cell.accessoryType = self.failedEntries.count
            ? UITableViewCellAccessoryDisclosureIndicator
            : UITableViewCellAccessoryNone;
        cell.selectionStyle = self.failedEntries.count
            ? UITableViewCellSelectionStyleDefault
            : UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)configureEntryCell:(UITableViewCell *)cell entry:(FLEXHookEntry *)entry {
    cell.textLabel.text = entry.title;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@",
        entry.detail, entry.statusSummary];
    cell.imageView.image = [UIImage systemImageNamed:
        entry.effectiveEnabled ? @"bolt.circle.fill" : @"circle.dashed"];
    cell.imageView.tintColor = entry.effectiveEnabled
        ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
    toggle.accessibilityLabel = [NSString stringWithFormat:@"Runtime hook for %@",
        entry.title];
    toggle.accessibilityValue = entry.statusSummary;
    objc_setAssociatedObject(toggle,
                             kFLEXHookCenterIdentifierKey,
                             entry.identifier,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self
               action:@selector(hookToggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.accessoryType = UITableViewCellAccessoryNone;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case FLEXHookCenterSectionStatus: return @"Runtime";
        case FLEXHookCenterSectionPending: return @"Pending";
        case FLEXHookCenterSectionActive: return @"Installed";
        case FLEXHookCenterSectionBrowsers: return @"Runtime Browsers";
        case FLEXHookCenterSectionSettings: return @"AllFLEXing UI and diagnostics";
        case FLEXHookCenterSectionDiagnostics: return @"Recovery";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == FLEXHookCenterSectionPending) {
        return @"Runtime switches apply one target immediately. Apply commits any remaining batch edits after revalidating target, ABI and provider.";
    }
    if (section == FLEXHookCenterSectionActive) {
        return @"An OFF installed hook forwards to the original implementation; physical unhooking is intentionally avoided at runtime.";
    }
    if (section == FLEXHookCenterSectionSettings) {
        return [NSString stringWithFormat:@"Feature preferences persist in the signed host sandbox: %@.",
            FLEXHookPersistence.sharedManager.storageDomainDescription];
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == FLEXHookCenterSectionPending && self.pendingEntries.count) {
        [self showEntry:self.pendingEntries[indexPath.row]];
    } else if (indexPath.section == FLEXHookCenterSectionActive && self.activeEntries.count) {
        [self showEntry:self.activeEntries[indexPath.row]];
    } else if (indexPath.section == FLEXHookCenterSectionBrowsers) {
        FLEXRuntimeBrowserKind kind = indexPath.row == 0
            ? FLEXRuntimeBrowserKindObjectiveC : FLEXRuntimeBrowserKindC;
        FLEXRuntimeBrowserController *browser =
            [[FLEXRuntimeBrowserController alloc] initWithKind:kind];
        [self.navigationController pushViewController:browser animated:YES];
    } else if (indexPath.section == FLEXHookCenterSectionDiagnostics && indexPath.row == 0 &&
               FLEXHookRegistry.sharedRegistry.safeMode) {
        [self confirmClearSafeMode];
    } else if (indexPath.section == FLEXHookCenterSectionDiagnostics && indexPath.row == 1 &&
               self.failedEntries.count) {
        [self presentErrorSummary];
    }
}

- (void)showEntry:(FLEXHookEntry *)entry {
    FLEXHookEntryDetailController *detail =
        [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)featureToggleChanged:(UISwitch *)toggle {
    NSString *identifier = objc_getAssociatedObject(toggle, kFLEXHookCenterIdentifierKey);
    if (identifier.length == 0) {
        return;
    }
    [FLEXHookPersistence.sharedManager setBool:toggle.isOn forFlag:identifier];
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}

- (void)hookToggleChanged:(UISwitch *)toggle {
    NSString *identifier = objc_getAssociatedObject(toggle, kFLEXHookCenterIdentifierKey);
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL requestedState = toggle.isOn;
    [registry stageEnabled:requestedState forEntryIdentifier:identifier];
    FLEXHookEntry *entry = [registry entryForIdentifier:identifier];
    if (!entry || entry.pendingEnabled != requestedState) {
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeError];
        [self reloadState];
        return;
    }

    UISelectionFeedbackGenerator *selection = [UISelectionFeedbackGenerator new];
    [selection selectionChanged];
    __weak typeof(self) weakSelf = self;
    [registry applyEntryIdentifier:identifier completion:^(
        __unused NSArray<FLEXHookEntry *> *applied,
        NSArray<FLEXHookEntry *> *failed
    ) {
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:failed.count
            ? UINotificationFeedbackTypeError
            : UINotificationFeedbackTypeSuccess];
        [weakSelf reloadState];
    }];
}

- (void)discardPending {
    [FLEXHookRegistry.sharedRegistry discardPendingChanges];
    UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
    [feedback notificationOccurred:UINotificationFeedbackTypeWarning];
}

- (void)applyPending {
    [self applyPendingWithRestart:NO];
}

- (void)applyAndRestart {
    [self applyPendingWithRestart:YES];
}

- (void)applyPendingWithRestart:(BOOL)restart {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    if (!registry.hasPendingChanges) {
        if (restart) {
            [self confirmCloseAndReopen];
        }
        return;
    }
    [registry applyPendingWithCompletion:^(NSArray<FLEXHookEntry *> *applied,
                                           NSArray<FLEXHookEntry *> *failed) {
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:failed.count
            ? UINotificationFeedbackTypeError : UINotificationFeedbackTypeSuccess];
        if (failed.count) {
            NSString *message = [NSString stringWithFormat:
                @"Applied %lu change(s). %lu target(s) failed validation and were not persisted as active.",
                (unsigned long)applied.count, (unsigned long)failed.count];
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"Apply completed with errors"
                                 message:message
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Review"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
                [self presentErrorSummary];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Close"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
        if (restart) {
            [self confirmCloseAndReopen];
        }
    }];
}

- (void)confirmCloseAndReopen {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Apply & Restart"
                         message:@"iOS does not allow a jailed app to relaunch itself. All settings will be saved, the app will close, and you can open it again manually."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close App"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            exit(0);
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearSafeMode {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Leave safe mode?"
                         message:@"The blocked target remains disabled. Leaving safe mode only unlocks normal apply operations."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Leave Safe Mode"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [FLEXHookRegistry.sharedRegistry clearSafeMode];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentErrorSummary {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (FLEXHookEntry *entry in self.failedEntries) {
        [lines addObject:[NSString stringWithFormat:@"• %@ — %@",
            entry.title, entry.lastError ?: @"Unknown error"]];
        if (lines.count >= 12) {
            [lines addObject:@"• More entries are available in their Runtime Browser."];
            break;
        }
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Runtime diagnostics"
                         message:[lines componentsJoinedByString:@"\n\n"]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = [lines componentsJoinedByString:@"\n"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
