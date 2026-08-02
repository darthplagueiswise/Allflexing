#import "FLEXCompactRuntimeUI.h"

#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXHookToggles.h"
#import "FLEXHooking.h"
#import "FLEXRuntimeBrowserController.h"
#import "FLEXSymbolRebind.h"

#import <objc/runtime.h>

static const void *kFLEXCompactEntryIdentifierKey = &kFLEXCompactEntryIdentifierKey;

static void FLEXCompactExchangeInstanceMethods(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

@interface FLEXRuntimeBrowserController (AllFLEXingCompactPrivate)
- (void)reloadEntries;
@end

@implementation FLEXRuntimeBrowserController (AllFLEXingCompactGroups)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FLEXRuntimeBrowserController.class;
        FLEXCompactExchangeInstanceMethods(cls, @selector(initWithKind:),
                                            @selector(af_compact_initWithKind:));
        FLEXCompactExchangeInstanceMethods(cls, @selector(viewDidLoad),
                                            @selector(af_compact_viewDidLoad));
        FLEXCompactExchangeInstanceMethods(cls, @selector(numberOfSectionsInTableView:),
                                            @selector(af_compact_numberOfSectionsInTableView:));
        FLEXCompactExchangeInstanceMethods(cls, @selector(tableView:numberOfRowsInSection:),
                                            @selector(af_compact_tableView:numberOfRowsInSection:));
        FLEXCompactExchangeInstanceMethods(cls, @selector(tableView:cellForRowAtIndexPath:),
                                            @selector(af_compact_tableView:cellForRowAtIndexPath:));
        FLEXCompactExchangeInstanceMethods(cls, @selector(tableView:didSelectRowAtIndexPath:),
                                            @selector(af_compact_tableView:didSelectRowAtIndexPath:));
    });
}

- (instancetype)af_compact_initWithKind:(FLEXRuntimeBrowserKind)kind {
    FLEXRuntimeBrowserController *controller =
        (FLEXRuntimeBrowserController *)[super initWithStyle:UITableViewStylePlain];
    if (controller) {
        [controller setValue:@(kind) forKey:@"kind"];
    }
    return controller;
}

- (void)af_compact_viewDidLoad {
    [self af_compact_viewDidLoad];
    FLEXConfigureCompactRuntimeTable(self.tableView);
    [self.tableView registerClass:FLEXRuntimeGroupHeaderView.class
           forHeaderFooterViewReuseIdentifier:@"AllFLEXingRuntimeGroupHeader"];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.searchController.searchBar.searchTextField.font =
        [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
            scaledFontForFont:[UIFont systemFontOfSize:13.5]
              maximumPointSize:16.0];
}

- (NSArray<FLEXRuntimeEntryGroup *> *)af_compact_runtimeGroups {
    NSArray<FLEXHookEntry *> *entries = nil;
    @try {
        entries = [self valueForKey:@"filteredEntries"];
    } @catch (__unused NSException *exception) {
        entries = @[];
    }
    return FLEXRuntimeGroupEntries(entries ?: @[]);
}

- (NSInteger)af_compact_numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.af_compact_runtimeGroups.count;
}

- (NSInteger)af_compact_tableView:(UITableView *)tableView
            numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    NSArray<FLEXRuntimeEntryGroup *> *groups = self.af_compact_runtimeGroups;
    return section >= 0 && section < (NSInteger)groups.count
        ? groups[section].entries.count : 0;
}

- (UITableViewCell *)af_compact_tableView:(UITableView *)tableView
                    cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"AllFLEXingCompactRuntimeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    NSArray<FLEXRuntimeEntryGroup *> *groups = self.af_compact_runtimeGroups;
    FLEXRuntimeEntryGroup *group = groups[indexPath.section];
    FLEXHookEntry *entry = group.entries[indexPath.row];

    NSString *icon = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0 ? @"checkmark.circle.fill" : @"bolt.circle.fill")
        : (entry.hookable ? @"circle.dashed" : @"eye");
    UIColor *tint = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0 ? UIColor.systemGreenColor : UIColor.systemBlueColor)
        : (entry.hookable ? self.view.tintColor : UIColor.secondaryLabelColor);
    FLEXConfigureCompactRuntimeContent(
        cell,
        FLEXRuntimeMemberTitleForEntry(entry),
        FLEXRuntimeCompactSummaryForEntry(entry),
        icon,
        tint
    );
    FLEXStyleCompactRuntimeCell(
        cell,
        FLEXCompactPositionForRow(indexPath.row, group.entries.count)
    );

    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
    [toggle sizeToFit];
    toggle.accessibilityLabel = [NSString stringWithFormat:@"Runtime hook for %@",
        entry.title];
    toggle.accessibilityValue = entry.statusSummary;
    objc_setAssociatedObject(toggle,
                             kFLEXCompactEntryIdentifierKey,
                             entry.identifier,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self
               action:@selector(af_compactRuntimeToggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = FLEXCompactAccessoryContainer(toggle, 0.82);
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    FLEXRuntimeGroupHeaderView *header = [tableView
        dequeueReusableHeaderFooterViewWithIdentifier:@"AllFLEXingRuntimeGroupHeader"];
    NSArray<FLEXRuntimeEntryGroup *> *groups = self.af_compact_runtimeGroups;
    FLEXRuntimeEntryGroup *group = groups[section];
    [header configureWithTitle:group.title
                       detail:[NSString stringWithFormat:@"%lu",
                           (unsigned long)group.entries.count]];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 30.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 4.0;
}

- (void)af_compact_tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<FLEXRuntimeEntryGroup *> *groups = self.af_compact_runtimeGroups;
    FLEXHookEntry *entry = groups[indexPath.section].entries[indexPath.row];
    FLEXHookEntryDetailController *detail =
        [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)af_compactRuntimeToggleChanged:(UISwitch *)toggle {
    NSString *identifier = objc_getAssociatedObject(toggle, kFLEXCompactEntryIdentifierKey);
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL requestedState = toggle.isOn;
    FLEXHookEntry *entry = [registry entryForIdentifier:identifier];
    if (requestedState && entry && !entry.userConfigured) {
        [registry stageForceValue:YES forEntryIdentifier:identifier];
    }
    [registry stageEnabled:requestedState forEntryIdentifier:identifier];
    entry = [registry entryForIdentifier:identifier];
    if (!entry || entry.pendingEnabled != requestedState) {
        [UINotificationFeedbackGenerator.new
            notificationOccurred:UINotificationFeedbackTypeError];
        [self reloadEntries];
        return;
    }
    [UISelectionFeedbackGenerator.new selectionChanged];
    __weak typeof(self) weakSelf = self;
    [registry applyEntryIdentifier:identifier completion:^(
        __unused NSArray<FLEXHookEntry *> *applied,
        NSArray<FLEXHookEntry *> *failed
    ) {
        FLEXHookEntry *resolved = [registry entryForIdentifier:identifier];
        UINotificationFeedbackType type = failed.count
            ? UINotificationFeedbackTypeError
            : (resolved.overrideHitCount > 0
                ? UINotificationFeedbackTypeSuccess
                : UINotificationFeedbackTypeWarning);
        [UINotificationFeedbackGenerator.new notificationOccurred:type];
        [weakSelf reloadEntries];
    }];
}

@end

typedef NS_ENUM(NSInteger, FLEXCompactHookSectionKind) {
    FLEXCompactHookSectionEngines = 0,
    FLEXCompactHookSectionPendingEmpty,
    FLEXCompactHookSectionPendingGroup,
    FLEXCompactHookSectionActiveEmpty,
    FLEXCompactHookSectionActiveGroup,
    FLEXCompactHookSectionRecovery,
};

@interface FLEXCompactHookSection : NSObject
@property (nonatomic) FLEXCompactHookSectionKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *entries;
@end
@implementation FLEXCompactHookSection
@end

@interface FLEXHookToggles (AllFLEXingCompactPrivate)
- (void)reloadState;
- (void)confirmClearSafeMode;
- (void)presentErrorSummary;
@end

static NSArray<FLEXCompactHookSection *> *FLEXCompactHookSections(FLEXHookToggles *controller) {
    NSArray<FLEXHookEntry *> *pending = @[];
    NSArray<FLEXHookEntry *> *active = @[];
    @try {
        pending = [controller valueForKey:@"pendingEntries"] ?: @[];
        active = [controller valueForKey:@"activeEntries"] ?: @[];
    } @catch (__unused NSException *exception) {
    }

    NSMutableArray<FLEXCompactHookSection *> *sections = [NSMutableArray array];
    FLEXCompactHookSection *engines = [FLEXCompactHookSection new];
    engines.kind = FLEXCompactHookSectionEngines;
    engines.title = @"Runtime engines";
    engines.detail = @"3";
    engines.entries = @[];
    [sections addObject:engines];

    if (!pending.count) {
        FLEXCompactHookSection *empty = [FLEXCompactHookSection new];
        empty.kind = FLEXCompactHookSectionPendingEmpty;
        empty.title = @"Pending";
        empty.entries = @[];
        [sections addObject:empty];
    } else {
        for (FLEXRuntimeEntryGroup *group in FLEXRuntimeGroupEntries(pending)) {
            FLEXCompactHookSection *section = [FLEXCompactHookSection new];
            section.kind = FLEXCompactHookSectionPendingGroup;
            section.title = group.title;
            section.detail = [NSString stringWithFormat:@"Pending · %lu",
                (unsigned long)group.entries.count];
            section.entries = group.entries;
            [sections addObject:section];
        }
    }

    if (!active.count) {
        FLEXCompactHookSection *empty = [FLEXCompactHookSection new];
        empty.kind = FLEXCompactHookSectionActiveEmpty;
        empty.title = @"Installed";
        empty.entries = @[];
        [sections addObject:empty];
    } else {
        for (FLEXRuntimeEntryGroup *group in FLEXRuntimeGroupEntries(active)) {
            FLEXCompactHookSection *section = [FLEXCompactHookSection new];
            section.kind = FLEXCompactHookSectionActiveGroup;
            section.title = group.title;
            section.detail = [NSString stringWithFormat:@"Installed · %lu",
                (unsigned long)group.entries.count];
            section.entries = group.entries;
            [sections addObject:section];
        }
    }

    FLEXCompactHookSection *recovery = [FLEXCompactHookSection new];
    recovery.kind = FLEXCompactHookSectionRecovery;
    recovery.title = @"Health";
    recovery.detail = @"2";
    recovery.entries = @[];
    [sections addObject:recovery];
    return sections.copy;
}

@implementation FLEXHookToggles (AllFLEXingCompactGroups)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FLEXHookToggles.class;
        FLEXCompactExchangeInstanceMethods(cls, @selector(init),
                                            @selector(af_compact_init));
        FLEXCompactExchangeInstanceMethods(cls, @selector(viewDidLoad),
                                            @selector(af_compact_viewDidLoad));
        FLEXCompactExchangeInstanceMethods(cls, @selector(numberOfSectionsInTableView:),
                                            @selector(af_compact_numberOfSectionsInTableView:));
        FLEXCompactExchangeInstanceMethods(cls, @selector(tableView:numberOfRowsInSection:),
                                            @selector(af_compact_tableView:numberOfRowsInSection:));
        FLEXCompactExchangeInstanceMethods(cls, @selector(tableView:cellForRowAtIndexPath:),
                                            @selector(af_compact_tableView:cellForRowAtIndexPath:));
        FLEXCompactExchangeInstanceMethods(cls, @selector(tableView:didSelectRowAtIndexPath:),
                                            @selector(af_compact_tableView:didSelectRowAtIndexPath:));
    });
}

- (instancetype)af_compact_init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)af_compact_viewDidLoad {
    [self af_compact_viewDidLoad];
    FLEXConfigureCompactRuntimeTable(self.tableView);
    [self.tableView registerClass:FLEXRuntimeGroupHeaderView.class
           forHeaderFooterViewReuseIdentifier:@"AllFLEXingHookGroupHeader"];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

- (NSInteger)af_compact_numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return FLEXCompactHookSections(self).count;
}

- (NSInteger)af_compact_tableView:(UITableView *)tableView
            numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    FLEXCompactHookSection *descriptor = FLEXCompactHookSections(self)[section];
    switch (descriptor.kind) {
        case FLEXCompactHookSectionEngines: return 3;
        case FLEXCompactHookSectionPendingEmpty:
        case FLEXCompactHookSectionActiveEmpty: return 1;
        case FLEXCompactHookSectionPendingGroup:
        case FLEXCompactHookSectionActiveGroup: return descriptor.entries.count;
        case FLEXCompactHookSectionRecovery: return 2;
    }
}

- (UITableViewCell *)af_compact_baseCell:(UITableView *)tableView {
    static NSString *identifier = @"AllFLEXingCompactHookCenterCell";
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

- (void)af_compact_configureEntryCell:(UITableViewCell *)cell
                                entry:(FLEXHookEntry *)entry
                             position:(FLEXCompactCellPosition)position {
    NSString *icon = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0 ? @"checkmark.circle.fill" : @"bolt.circle.fill")
        : @"circle.dashed";
    UIColor *tint = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0 ? UIColor.systemGreenColor : UIColor.systemBlueColor)
        : UIColor.secondaryLabelColor;
    FLEXConfigureCompactRuntimeContent(
        cell,
        FLEXRuntimeMemberTitleForEntry(entry),
        FLEXRuntimeCompactSummaryForEntry(entry),
        icon,
        tint
    );
    FLEXStyleCompactRuntimeCell(cell, position);

    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
    [toggle sizeToFit];
    toggle.accessibilityLabel = [NSString stringWithFormat:@"Runtime hook for %@",
        entry.title];
    toggle.accessibilityValue = entry.statusSummary;
    objc_setAssociatedObject(toggle,
                             kFLEXCompactEntryIdentifierKey,
                             entry.identifier,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self
               action:@selector(af_compactHookToggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = FLEXCompactAccessoryContainer(toggle, 0.82);
}

- (UITableViewCell *)af_compact_tableView:(UITableView *)tableView
                    cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self af_compact_baseCell:tableView];
    NSArray<FLEXCompactHookSection *> *sections = FLEXCompactHookSections(self);
    FLEXCompactHookSection *descriptor = sections[indexPath.section];
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;

    if (descriptor.kind == FLEXCompactHookSectionEngines) {
        NSArray<NSString *> *titles = @[@"Objective-C methods", @"Imported C symbols", @"Inline C functions"];
        NSArray<NSString *> *images = @[@"curlybraces", @"link", @"function"];
        NSArray<NSString *> *details = @[
            FLEXMSHookMessageProviderAvailable()
                ? [NSString stringWithFormat:@"%@ · MSHookMessageEx", registry.providerName]
                : @"Objective-C provider unavailable",
            FLEXSymbolRebind.backendDescription,
            FLEXMSHookFunctionProviderAvailable()
                ? [NSString stringWithFormat:@"%@ · MSHookFunction", registry.providerName]
                : @"Inline provider unavailable",
        ];
        BOOL ready = indexPath.row == 0
            ? FLEXMSHookMessageProviderAvailable()
            : (indexPath.row == 1
                ? FLEXEmbeddedFishhookAvailable()
                : FLEXMSHookFunctionProviderAvailable());
        FLEXConfigureCompactRuntimeContent(cell,
                                           titles[indexPath.row],
                                           details[indexPath.row],
                                           images[indexPath.row],
                                           ready ? UIColor.systemGreenColor : UIColor.systemOrangeColor);
        FLEXStyleCompactRuntimeCell(cell, FLEXCompactPositionForRow(indexPath.row, 3));
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (descriptor.kind == FLEXCompactHookSectionPendingEmpty) {
        FLEXConfigureCompactRuntimeContent(cell,
                                           @"Nothing waiting",
                                           @"Intent and runtime gates are synchronized",
                                           @"checkmark.circle.fill",
                                           UIColor.systemGreenColor);
        FLEXStyleCompactRuntimeCell(cell, FLEXCompactCellPositionSingle);
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (descriptor.kind == FLEXCompactHookSectionActiveEmpty) {
        FLEXConfigureCompactRuntimeContent(cell,
                                           @"No installed hooks",
                                           @"Choose a validated Runtime target",
                                           @"power",
                                           UIColor.secondaryLabelColor);
        FLEXStyleCompactRuntimeCell(cell, FLEXCompactCellPositionSingle);
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (descriptor.kind == FLEXCompactHookSectionPendingGroup ||
        descriptor.kind == FLEXCompactHookSectionActiveGroup) {
        FLEXHookEntry *entry = descriptor.entries[indexPath.row];
        [self af_compact_configureEntryCell:cell
                                      entry:entry
                                   position:FLEXCompactPositionForRow(indexPath.row,
                                                                      descriptor.entries.count)];
        return cell;
    }

    NSArray<FLEXHookEntry *> *failed = @[];
    @try {
        failed = [self valueForKey:@"failedEntries"] ?: @[];
    } @catch (__unused NSException *exception) {
    }
    if (indexPath.row == 0) {
        FLEXConfigureCompactRuntimeContent(
            cell,
            registry.safeMode ? @"Safe mode active" : @"Safe mode ready",
            registry.safeMode
                ? [NSString stringWithFormat:@"Blocked: %@",
                    registry.safeModeEntryIdentifier ?: @"unknown"]
                : @"No interrupted transaction detected",
            registry.safeMode ? @"shield.lefthalf.filled" : @"shield.checkered",
            registry.safeMode ? UIColor.systemOrangeColor : UIColor.systemGreenColor
        );
        cell.selectionStyle = registry.safeMode
            ? UITableViewCellSelectionStyleDefault
            : UITableViewCellSelectionStyleNone;
        cell.accessoryType = registry.safeMode
            ? UITableViewCellAccessoryDisclosureIndicator
            : UITableViewCellAccessoryNone;
    } else {
        FLEXConfigureCompactRuntimeContent(
            cell,
            @"Errors and stale targets",
            failed.count
                ? [NSString stringWithFormat:@"%lu target(s) need attention",
                    (unsigned long)failed.count]
                : @"No runtime hook errors",
            failed.count ? @"exclamationmark.triangle.fill" : @"checkmark.seal.fill",
            failed.count ? UIColor.systemOrangeColor : UIColor.systemGreenColor
        );
        cell.selectionStyle = failed.count
            ? UITableViewCellSelectionStyleDefault
            : UITableViewCellSelectionStyleNone;
        cell.accessoryType = failed.count
            ? UITableViewCellAccessoryDisclosureIndicator
            : UITableViewCellAccessoryNone;
    }
    FLEXStyleCompactRuntimeCell(cell, FLEXCompactPositionForRow(indexPath.row, 2));
    return cell;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    FLEXRuntimeGroupHeaderView *header = [tableView
        dequeueReusableHeaderFooterViewWithIdentifier:@"AllFLEXingHookGroupHeader"];
    FLEXCompactHookSection *descriptor = FLEXCompactHookSections(self)[section];
    [header configureWithTitle:descriptor.title detail:descriptor.detail];
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 30.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 4.0;
}

- (void)af_compact_tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FLEXCompactHookSection *descriptor = FLEXCompactHookSections(self)[indexPath.section];
    if (descriptor.kind == FLEXCompactHookSectionPendingGroup ||
        descriptor.kind == FLEXCompactHookSectionActiveGroup) {
        FLEXHookEntry *entry = descriptor.entries[indexPath.row];
        FLEXHookEntryDetailController *detail =
            [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }
    if (descriptor.kind == FLEXCompactHookSectionRecovery) {
        NSArray *failed = @[];
        @try {
            failed = [self valueForKey:@"failedEntries"] ?: @[];
        } @catch (__unused NSException *exception) {
        }
        if (indexPath.row == 0 && FLEXHookRegistry.sharedRegistry.safeMode) {
            [self confirmClearSafeMode];
        } else if (indexPath.row == 1 && failed.count) {
            [self presentErrorSummary];
        }
    }
}

- (void)af_compactHookToggleChanged:(UISwitch *)toggle {
    NSString *identifier = objc_getAssociatedObject(toggle, kFLEXCompactEntryIdentifierKey);
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL requestedState = toggle.isOn;
    FLEXHookEntry *entry = [registry entryForIdentifier:identifier];
    if (requestedState && entry && !entry.userConfigured) {
        [registry stageForceValue:YES forEntryIdentifier:identifier];
    }
    [registry stageEnabled:requestedState forEntryIdentifier:identifier];
    entry = [registry entryForIdentifier:identifier];
    if (!entry || entry.pendingEnabled != requestedState) {
        [UINotificationFeedbackGenerator.new
            notificationOccurred:UINotificationFeedbackTypeError];
        [self reloadState];
        return;
    }
    [UISelectionFeedbackGenerator.new selectionChanged];
    __weak typeof(self) weakSelf = self;
    [registry applyEntryIdentifier:identifier completion:^(
        __unused NSArray<FLEXHookEntry *> *applied,
        NSArray<FLEXHookEntry *> *failed
    ) {
        FLEXHookEntry *resolved = [registry entryForIdentifier:identifier];
        UINotificationFeedbackType type = failed.count
            ? UINotificationFeedbackTypeError
            : (resolved.overrideHitCount > 0
                ? UINotificationFeedbackTypeSuccess
                : UINotificationFeedbackTypeWarning);
        [UINotificationFeedbackGenerator.new notificationOccurred:type];
        [weakSelf reloadState];
    }];
}

@end
