#import "FLEXHookSettingsController.h"

#import "FLEXHookPersistence.h"
#import "FLEXHookRegistry.h"
#import "FLEXLiquidGlass.h"
#import <objc/runtime.h>

static const void *kFLEXSettingsFlagIdentifierKey = &kFLEXSettingsFlagIdentifierKey;

typedef NS_ENUM(NSInteger, FLEXHookSettingsSection) {
    FLEXHookSettingsSectionInterface = 0,
    FLEXHookSettingsSectionEngines,
    FLEXHookSettingsSectionStorage,
    FLEXHookSettingsSectionRecovery,
    FLEXHookSettingsSectionCount,
};

@interface FLEXHookSettingsController ()
@property (nonatomic, copy) NSArray<FLEXHookFlag *> *interfaceFlags;
@property (nonatomic, copy) NSArray<FLEXHookFlag *> *engineFlags;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *failedEntries;
@end

@implementation FLEXHookSettingsController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
    [FLEXLiquidGlass applyToViewController:self];
    [self setContentScrollView:self.tableView
                      forEdge:(NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom)];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(stateChanged:)
               name:FLEXHookRegistryDidChangeNotification
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(stateChanged:)
               name:FLEXHookFlagsDidChangeNotification
             object:nil];
    [self reloadState];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)stateChanged:(NSNotification *)notification {
    (void)notification;
    [self reloadState];
}

- (void)reloadState {
    NSMutableArray<FLEXHookFlag *> *interfaceFlags = [NSMutableArray array];
    NSMutableArray<FLEXHookFlag *> *engineFlags = [NSMutableArray array];
    for (FLEXHookFlag *flag in FLEXHookPersistence.sharedManager.registeredFlags) {
        if ([flag.identifier hasPrefix:@"engine."]) {
            [engineFlags addObject:flag];
        } else {
            [interfaceFlags addObject:flag];
        }
    }
    NSMutableArray<FLEXHookEntry *> *failed = [NSMutableArray array];
    for (FLEXHookEntry *entry in FLEXHookRegistry.sharedRegistry.entries) {
        if (entry.lastError.length) {
            [failed addObject:entry];
        }
    }
    self.interfaceFlags = interfaceFlags.copy;
    self.engineFlags = engineFlags.copy;
    self.failedEntries = failed.copy;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return FLEXHookSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case FLEXHookSettingsSectionInterface: return self.interfaceFlags.count;
        case FLEXHookSettingsSectionEngines: return self.engineFlags.count;
        case FLEXHookSettingsSectionStorage: return 1;
        case FLEXHookSettingsSectionRecovery: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)baseCellForTableView:(UITableView *)tableView {
    static NSString *identifier = @"AllFLEXingSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
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
    content.secondaryText = secondary;
    content.secondaryTextProperties.numberOfLines = 0;
    content.image = [UIImage systemImageNamed:image];
    content.imageProperties.tintColor = tint;
    cell.contentConfiguration = content;
}

- (void)configureFlagCell:(UITableViewCell *)cell flag:(FLEXHookFlag *)flag {
    NSString *symbol = [flag.identifier hasPrefix:@"engine."]
        ? @"cpu" : ([flag.identifier isEqualToString:@"glass.enabled"] ? @"circle.hexagongrid.fill" : @"switch.2");
    [self configureCell:cell
                   text:flag.title
              secondary:flag.detail
                  image:symbol
                   tint:self.view.tintColor];
    UISwitch *toggle = [UISwitch new];
    toggle.on = [FLEXHookPersistence.sharedManager boolForFlag:flag.identifier];
    [toggle sizeToFit];
    objc_setAssociatedObject(toggle,
                             kFLEXSettingsFlagIdentifierKey,
                             flag.identifier,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self
               action:@selector(flagChanged:)
     forControlEvents:UIControlEventValueChanged];
    toggle.accessibilityLabel = flag.title;
    toggle.accessibilityHint = flag.detail;
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self baseCellForTableView:tableView];
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    if (indexPath.section == FLEXHookSettingsSectionInterface) {
        [self configureFlagCell:cell flag:self.interfaceFlags[indexPath.row]];
        return cell;
    }
    if (indexPath.section == FLEXHookSettingsSectionEngines) {
        [self configureFlagCell:cell flag:self.engineFlags[indexPath.row]];
        return cell;
    }
    if (indexPath.section == FLEXHookSettingsSectionStorage) {
        [self configureCell:cell
                       text:@"Jailed host storage"
                  secondary:FLEXHookPersistence.sharedManager.storageDomainDescription
                      image:@"internaldrive.fill"
                       tint:UIColor.systemIndigoColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.row == 0) {
        NSString *secondary = registry.safeMode
            ? [NSString stringWithFormat:@"Blocked target: %@",
                registry.safeModeEntryIdentifier ?: @"unknown"]
            : @"No interrupted hook transaction was detected.";
        NSString *image = registry.safeMode
            ? @"shield.lefthalf.filled" : @"shield.checkered";
        [self configureCell:cell
                       text:registry.safeMode ? @"Leave safe mode" : @"Safe mode ready"
                  secondary:secondary
                      image:image
                       tint:registry.safeMode ? UIColor.systemOrangeColor : UIColor.systemGreenColor];
        cell.accessoryType = registry.safeMode
            ? UITableViewCellAccessoryDisclosureIndicator
            : UITableViewCellAccessoryNone;
        cell.selectionStyle = registry.safeMode
            ? UITableViewCellSelectionStyleDefault
            : UITableViewCellSelectionStyleNone;
    } else {
        NSString *secondary = self.failedEntries.count
            ? [NSString stringWithFormat:@"%lu target(s) require attention.",
                (unsigned long)self.failedEntries.count]
            : @"No runtime hook errors.";
        NSString *image = self.failedEntries.count
            ? @"exclamationmark.triangle.fill" : @"checkmark.seal.fill";
        [self configureCell:cell
                       text:@"Runtime diagnostics"
                  secondary:secondary
                      image:image
                       tint:self.failedEntries.count ? UIColor.systemOrangeColor : UIColor.systemGreenColor];
        cell.accessoryType = self.failedEntries.count
            ? UITableViewCellAccessoryDisclosureIndicator
            : UITableViewCellAccessoryNone;
        cell.selectionStyle = self.failedEntries.count
            ? UITableViewCellSelectionStyleDefault
            : UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case FLEXHookSettingsSectionInterface: return @"Interface and access";
        case FLEXHookSettingsSectionEngines: return @"Hook engines";
        case FLEXHookSettingsSectionStorage: return @"Persistence";
        case FLEXHookSettingsSectionRecovery: return @"Recovery";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == FLEXHookSettingsSectionEngines) {
        return @"A backend is offered only when the provider, ABI and locator all validate in the current process.";
    }
    if (section == FLEXHookSettingsSectionStorage) {
        return @"Only versioned locators and desired state persist. Pointers and trampolines never leave process memory.";
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != FLEXHookSettingsSectionRecovery) {
        return;
    }
    if (indexPath.row == 0 && FLEXHookRegistry.sharedRegistry.safeMode) {
        [self confirmClearSafeMode];
    } else if (indexPath.row == 1 && self.failedEntries.count) {
        [self presentDiagnostics];
    }
}

- (void)flagChanged:(UISwitch *)toggle {
    NSString *identifier = objc_getAssociatedObject(toggle, kFLEXSettingsFlagIdentifierKey);
    if (!identifier.length) {
        return;
    }
    [FLEXHookPersistence.sharedManager setBool:toggle.isOn forFlag:identifier];
    if ([identifier hasPrefix:@"engine."]) {
        [FLEXHookRegistry.sharedRegistry refreshCapabilities];
    }
    if ([identifier isEqualToString:@"glass.enabled"]) {
        [FLEXLiquidGlass refreshVisibleFLEXViewControllers];
    }
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}

- (void)confirmClearSafeMode {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Leave safe mode?"
                         message:@"The suspected target stays disabled. This only unlocks normal apply operations."
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

- (void)presentDiagnostics {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (FLEXHookEntry *entry in self.failedEntries) {
        [lines addObject:[NSString stringWithFormat:@"• %@ — %@",
            entry.title, entry.lastError ?: @"Unknown error"]];
        if (lines.count == 12) {
            [lines addObject:@"• Additional entries are available in their runtime browser."];
            break;
        }
    }
    NSString *report = [lines componentsJoinedByString:@"\n\n"];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Runtime diagnostics"
                         message:report
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = report;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
