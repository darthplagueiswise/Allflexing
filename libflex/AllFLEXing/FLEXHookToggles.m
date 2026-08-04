#import "FLEXHookToggles.h"

#import "FLEXCompactRuntimeUI.h"
#import "FLEXHookEntryDetailController.h"
#import "FLEXHookPersistence.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"
#import "FLEXLiquidGlass.h"
#import "FLEXSymbolRebind.h"

#import <math.h>
#import <objc/runtime.h>
#import <stdlib.h>

const char *FLEXDeferredApplyPolicyABIVersion =
    "AllFLEXing staged toggles explicit-Apply-only ABI 2";
const char *FLEXCompactRuntimeControllersABIVersion =
    "AllFLEXing owner-native compact runtime controllers ABI 1";

static const void *kFLEXHookCenterIdentifierKey =
    &kFLEXHookCenterIdentifierKey;

typedef NS_ENUM(NSInteger, FLEXHookCenterSectionKind) {
    FLEXHookCenterSectionEngines = 0,
    FLEXHookCenterSectionPendingEmpty,
    FLEXHookCenterSectionPendingGroup,
    FLEXHookCenterSectionActiveEmpty,
    FLEXHookCenterSectionActiveGroup,
    FLEXHookCenterSectionRecovery,
};

@interface FLEXHookCenterSection : NSObject
@property (nonatomic) FLEXHookCenterSectionKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *entries;
@end
@implementation FLEXHookCenterSection
@end

@interface FLEXHookMetricView : UIView
@property (nonatomic) UILabel *valueLabel;
@property (nonatomic) UILabel *captionLabel;
- (void)setValue:(NSString *)value
         caption:(NSString *)caption
            tint:(UIColor *)tint;
@end

@implementation FLEXHookMetricView

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    [FLEXLiquidGlass stylePanelView:self interactive:NO radius:18.0];
    _valueLabel = [UILabel new];
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:22.0
                                                       weight:UIFontWeightSemibold];
    _valueLabel.adjustsFontForContentSizeCategory = YES;
    _captionLabel = [UILabel new];
    _captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _captionLabel.textColor = UIColor.secondaryLabelColor;
    _captionLabel.adjustsFontForContentSizeCategory = YES;

    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[_valueLabel, _captionLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14.0],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14.0],
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:12.0],
        [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12.0],
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:68.0],
    ]];
    return self;
}

- (void)setValue:(NSString *)value
         caption:(NSString *)caption
            tint:(UIColor *)tint {
    [FLEXLiquidGlass stylePanelView:self interactive:NO radius:18.0];
    self.valueLabel.text = value;
    self.valueLabel.textColor = tint;
    self.captionLabel.text = caption;
}

@end

@interface FLEXHookCenterHeaderView : UIView
@property (nonatomic) UILabel *providerLabel;
@property (nonatomic) UILabel *summaryLabel;
@property (nonatomic) UIStackView *metricsStack;
@property (nonatomic) FLEXHookMetricView *armedMetric;
@property (nonatomic) FLEXHookMetricView *observedMetric;
@property (nonatomic) FLEXHookMetricView *errorMetric;
- (void)updateWithRegistry:(FLEXHookRegistry *)registry;
@end

@implementation FLEXHookCenterHeaderView

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;

    self.backgroundColor = UIColor.clearColor;
    UIImageView *icon = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"bolt.shield.fill"]];
    icon.tintColor = UIColor.systemBlueColor;
    icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration
        configurationWithTextStyle:UIFontTextStyleTitle1];
    [icon setContentHuggingPriority:UILayoutPriorityRequired
                           forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *title = [UILabel new];
    title.text = @"Runtime control plane";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    title.adjustsFontForContentSizeCategory = YES;

    _providerLabel = [UILabel new];
    _providerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _providerLabel.textColor = UIColor.secondaryLabelColor;
    _providerLabel.adjustsFontForContentSizeCategory = YES;

    UIStackView *labels = [[UIStackView alloc]
        initWithArrangedSubviews:@[title, _providerLabel]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 2.0;

    UIStackView *heading = [[UIStackView alloc]
        initWithArrangedSubviews:@[icon, labels]];
    heading.axis = UILayoutConstraintAxisHorizontal;
    heading.alignment = UIStackViewAlignmentCenter;
    heading.spacing = 12.0;

    _summaryLabel = [UILabel new];
    _summaryLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _summaryLabel.textColor = UIColor.secondaryLabelColor;
    _summaryLabel.adjustsFontForContentSizeCategory = YES;
    _summaryLabel.numberOfLines = 0;

    _armedMetric = [FLEXHookMetricView new];
    _observedMetric = [FLEXHookMetricView new];
    _errorMetric = [FLEXHookMetricView new];
    _metricsStack = [[UIStackView alloc]
        initWithArrangedSubviews:@[_armedMetric, _observedMetric, _errorMetric]];
    _metricsStack.axis = UILayoutConstraintAxisHorizontal;
    _metricsStack.distribution = UIStackViewDistributionFillEqually;
    _metricsStack.spacing = 10.0;

    UIStackView *content = [[UIStackView alloc]
        initWithArrangedSubviews:@[heading, _summaryLabel, _metricsStack]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 14.0;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20.0],
        [content.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20.0],
        [content.topAnchor constraintEqualToAnchor:self.topAnchor constant:16.0],
        [content.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-18.0],
    ]];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    BOOL accessibility = UIContentSizeCategoryIsAccessibilityCategory(
        self.traitCollection.preferredContentSizeCategory
    );
    self.metricsStack.axis = CGRectGetWidth(self.bounds) >= 540.0 && !accessibility
        ? UILayoutConstraintAxisHorizontal
        : UILayoutConstraintAxisVertical;
}

- (void)updateWithRegistry:(FLEXHookRegistry *)registry {
    BOOL providerReady = FLEXMSHookProviderAvailable();
    self.providerLabel.text = [NSString stringWithFormat:@"Provider: %@",
        registry.providerName ?: @"Unavailable"];
    self.providerLabel.textColor = providerReady
        ? UIColor.systemGreenColor
        : UIColor.systemOrangeColor;
    self.summaryLabel.text = registry.safeMode
        ? @"Safe mode is active. Review the blocked target before applying another batch."
        : @"Switches only stage intent. Apply revalidates the current host, image, ABI and provider before installing anything.";
    [self.armedMetric setValue:[NSString stringWithFormat:@"%lu",
        (unsigned long)registry.armedCount]
                        caption:@"Armed"
                           tint:UIColor.systemBlueColor];
    [self.observedMetric setValue:[NSString stringWithFormat:@"%lu",
        (unsigned long)registry.observedCount]
                           caption:@"Observed"
                              tint:registry.observedCount
                                ? UIColor.systemGreenColor
                                : UIColor.secondaryLabelColor];
    [self.errorMetric setValue:[NSString stringWithFormat:@"%lu",
        (unsigned long)registry.failureCount]
                        caption:@"Errors"
                           tint:registry.failureCount
                                ? UIColor.systemOrangeColor
                                : UIColor.secondaryLabelColor];
    [self setNeedsLayout];
}

@end

@interface FLEXHookToggles ()
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *pendingEntries;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *activeEntries;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *failedEntries;
@property (nonatomic, copy) NSArray<FLEXHookCenterSection *> *sections;
@property (nonatomic) UIBarButtonItem *applyItem;
@property (nonatomic) UIBarButtonItem *moreItem;
@property (nonatomic) FLEXHookCenterHeaderView *statusHeader;
@end

@implementation FLEXHookToggles

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hook Center";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    FLEXConfigureCompactRuntimeTable(self.tableView);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
    [self setContentScrollView:self.tableView
                      forEdge:(NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom)];

    self.statusHeader = [FLEXHookCenterHeaderView new];
    self.tableView.tableHeaderView = self.statusHeader;

    self.applyItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Apply"
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(applyPending)];
    if (@available(iOS 26.0, *)) {
        self.applyItem.style = UIBarButtonItemStyleProminent;
    }
    self.moreItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                 menu:[UIMenu menuWithChildren:@[]]];
    self.moreItem.accessibilityLabel = @"Hook Center actions";

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryChanged:)
               name:FLEXHookRegistryDidChangeNotification
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryChanged:)
               name:FLEXHookFlagsDidChangeNotification
             object:nil];
    [FLEXLiquidGlass applyToViewController:self];
    [self reloadState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadState];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutStatusHeader];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)registryChanged:(NSNotification *)notification {
    (void)notification;
    [self reloadState];
}

- (void)layoutStatusHeader {
    FLEXHookCenterHeaderView *header = self.statusHeader;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if (!header || width <= 0.0) return;

    CGRect frame = header.frame;
    frame.size.width = width;
    header.frame = frame;
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGSize size = [header systemLayoutSizeFittingSize:
        CGSizeMake(width, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired
        verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (fabs(CGRectGetHeight(frame) - size.height) > 0.5) {
        frame.size.height = size.height;
        header.frame = frame;
        self.tableView.tableHeaderView = header;
    }
}

- (NSArray<FLEXHookCenterSection *> *)buildSections {
    NSMutableArray<FLEXHookCenterSection *> *sections = [NSMutableArray array];

    FLEXHookCenterSection *engines = [FLEXHookCenterSection new];
    engines.kind = FLEXHookCenterSectionEngines;
    engines.title = @"Runtime engines";
    engines.entries = @[];
    [sections addObject:engines];

    if (!self.pendingEntries.count) {
        FLEXHookCenterSection *empty = [FLEXHookCenterSection new];
        empty.kind = FLEXHookCenterSectionPendingEmpty;
        empty.title = @"Pending";
        empty.entries = @[];
        [sections addObject:empty];
    } else {
        for (FLEXRuntimeEntryGroup *group in
             FLEXRuntimeGroupEntries(self.pendingEntries)) {
            FLEXHookCenterSection *section = [FLEXHookCenterSection new];
            section.kind = FLEXHookCenterSectionPendingGroup;
            section.title = group.title;
            section.entries = group.entries;
            [sections addObject:section];
        }
    }

    if (!self.activeEntries.count) {
        FLEXHookCenterSection *empty = [FLEXHookCenterSection new];
        empty.kind = FLEXHookCenterSectionActiveEmpty;
        empty.title = @"Installed";
        empty.entries = @[];
        [sections addObject:empty];
    } else {
        for (FLEXRuntimeEntryGroup *group in
             FLEXRuntimeGroupEntries(self.activeEntries)) {
            FLEXHookCenterSection *section = [FLEXHookCenterSection new];
            section.kind = FLEXHookCenterSectionActiveGroup;
            section.title = group.title;
            section.entries = group.entries;
            [sections addObject:section];
        }
    }

    FLEXHookCenterSection *recovery = [FLEXHookCenterSection new];
    recovery.kind = FLEXHookCenterSectionRecovery;
    recovery.title = @"Health";
    recovery.entries = @[];
    [sections addObject:recovery];
    return sections.copy;
}

- (void)reloadState {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    NSMutableArray<FLEXHookEntry *> *pending = [NSMutableArray array];
    NSMutableArray<FLEXHookEntry *> *active = [NSMutableArray array];
    NSMutableArray<FLEXHookEntry *> *failed = [NSMutableArray array];
    for (FLEXHookEntry *entry in registry.entries) {
        if (entry.pendingEnabled != entry.desiredEnabled ||
            (entry.desiredEnabled && !entry.installed)) {
            [pending addObject:entry];
        }
        if (entry.installed) [active addObject:entry];
        if (entry.lastError.length) [failed addObject:entry];
    }
    self.pendingEntries = pending.copy;
    self.activeEntries = active.copy;
    self.failedEntries = failed.copy;
    self.sections = [self buildSections];
    [self.statusHeader updateWithRegistry:registry];
    [self.tableView reloadData];
    [self updateNavigationActions];
    [self layoutStatusHeader];
}

- (void)updateNavigationActions {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL hasPending = registry.hasPendingChanges;
    BOOL applying = registry.isApplying;
    self.applyItem.enabled = hasPending && !applying;
    self.applyItem.title = applying ? @"Applying…" : @"Apply";

    __weak typeof(self) weakSelf = self;
    UIAction *discard = [UIAction
        actionWithTitle:@"Discard pending changes"
                  image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        [weakSelf discardPending];
    }];
    if (!hasPending || applying) {
        discard.attributes = UIMenuElementAttributesDisabled;
    }

    UIAction *restart = [UIAction
        actionWithTitle:@"Apply and close app"
                  image:[UIImage systemImageNamed:@"arrow.clockwise.circle"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        [weakSelf applyAndRestart];
    }];
    if (applying) restart.attributes = UIMenuElementAttributesDisabled;

    UIAction *diagnostics = [UIAction
        actionWithTitle:@"Copy diagnostics"
                  image:[UIImage systemImageNamed:@"doc.on.doc"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        [weakSelf presentErrorSummary];
    }];
    if (!self.failedEntries.count) {
        diagnostics.attributes = UIMenuElementAttributesDisabled;
    }

    UIAction *safeMode = [UIAction
        actionWithTitle:@"Leave safe mode"
                  image:[UIImage systemImageNamed:@"shield.checkered"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        [weakSelf confirmClearSafeMode];
    }];
    if (!registry.safeMode) {
        safeMode.attributes = UIMenuElementAttributesDisabled;
    }

    self.moreItem.menu = [UIMenu menuWithTitle:@"Runtime actions"
                                     children:@[
        discard,
        restart,
        diagnostics,
        safeMode,
    ]];

    UIBarButtonItem *separator = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace
                             target:nil
                             action:nil];
    separator.width = 8.0;
    if (@available(iOS 26.0, *)) separator.hidesSharedBackground = YES;
    self.navigationItem.rightBarButtonItems = @[
        self.applyItem,
        separator,
        self.moreItem,
    ];
    if (@available(iOS 26.0, *)) {
        self.navigationItem.subtitle = [NSString stringWithFormat:
            @"%lu armed · %lu observed · %lu pending",
            (unsigned long)registry.armedCount,
            (unsigned long)registry.observedCount,
            (unsigned long)registry.pendingCount];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section < 0 || section >= (NSInteger)self.sections.count) return 0;
    FLEXHookCenterSection *descriptor = self.sections[(NSUInteger)section];
    switch (descriptor.kind) {
        case FLEXHookCenterSectionEngines: return 3;
        case FLEXHookCenterSectionPendingEmpty:
        case FLEXHookCenterSectionActiveEmpty: return 1;
        case FLEXHookCenterSectionPendingGroup:
        case FLEXHookCenterSectionActiveGroup: return descriptor.entries.count;
        case FLEXHookCenterSectionRecovery: return 2;
    }
}

- (UITableViewCell *)baseCellForTableView:(UITableView *)tableView {
    static NSString *identifier = @"AllFLEXingNativeHookCenterCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
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
    FLEXConfigureCompactRuntimeContent(
        cell,
        text,
        secondary,
        image,
        tint
    );
}

- (void)configureEntryCell:(UITableViewCell *)cell
                     entry:(FLEXHookEntry *)entry
                  position:(FLEXCompactCellPosition)position {
    NSString *icon = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0
            ? @"checkmark.circle.fill"
            : @"bolt.circle.fill")
        : @"circle.dashed";
    UIColor *tint = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0
            ? UIColor.systemGreenColor
            : UIColor.systemBlueColor)
        : UIColor.secondaryLabelColor;
    [self configureCell:cell
                   text:FLEXRuntimeMemberTitleForEntry(entry)
              secondary:FLEXRuntimeCompactSummaryForEntry(entry)
                  image:icon
                   tint:tint];
    FLEXStyleCompactRuntimeCell(cell, position);

    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
    [toggle sizeToFit];
    toggle.accessibilityLabel = [NSString stringWithFormat:
        @"Stage runtime hook for %@", entry.title];
    toggle.accessibilityValue = entry.statusSummary;
    objc_setAssociatedObject(
        toggle,
        kFLEXHookCenterIdentifierKey,
        entry.identifier,
        OBJC_ASSOCIATION_COPY_NONATOMIC
    );
    [toggle addTarget:self
               action:@selector(hookToggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self baseCellForTableView:tableView];
    FLEXHookCenterSection *section = self.sections[indexPath.section];
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;

    if (section.kind == FLEXHookCenterSectionEngines) {
        NSArray<NSString *> *titles = @[
            @"Objective-C methods",
            @"Imported C symbols",
            @"Inline C functions",
        ];
        NSArray<NSString *> *images = @[@"curlybraces", @"link", @"function"];
        NSArray<NSString *> *details = @[
            FLEXMSHookMessageProviderAvailable()
                ? [NSString stringWithFormat:@"%@ · MSHookMessageEx",
                    registry.providerName]
                : @"Objective-C provider unavailable",
            FLEXSymbolRebind.backendDescription,
            FLEXMSHookFunctionProviderAvailable()
                ? [NSString stringWithFormat:@"%@ · MSHookFunction",
                    registry.providerName]
                : @"Inline provider unavailable",
        ];
        BOOL ready = indexPath.row == 0
            ? FLEXMSHookMessageProviderAvailable()
            : (indexPath.row == 1
                ? FLEXEmbeddedFishhookAvailable()
                : FLEXMSHookFunctionProviderAvailable());
        [self configureCell:cell
                       text:titles[indexPath.row]
                  secondary:details[indexPath.row]
                      image:images[indexPath.row]
                       tint:ready
                        ? UIColor.systemGreenColor
                        : UIColor.systemOrangeColor];
        FLEXStyleCompactRuntimeCell(
            cell,
            FLEXCompactPositionForRow(indexPath.row, 3)
        );
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (section.kind == FLEXHookCenterSectionPendingEmpty) {
        [self configureCell:cell
                       text:@"Nothing waiting"
                  secondary:@"All confirmed runtime gates match their persisted intent."
                      image:@"checkmark.circle.fill"
                       tint:UIColor.systemGreenColor];
        FLEXStyleCompactRuntimeCell(cell, FLEXCompactCellPositionSingle);
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (section.kind == FLEXHookCenterSectionActiveEmpty) {
        [self configureCell:cell
                       text:@"No installed runtime hooks"
                  secondary:@"Stage a validated target in either Runtime tab, then press Apply."
                      image:@"power"
                       tint:UIColor.secondaryLabelColor];
        FLEXStyleCompactRuntimeCell(cell, FLEXCompactCellPositionSingle);
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (section.kind == FLEXHookCenterSectionPendingGroup ||
        section.kind == FLEXHookCenterSectionActiveGroup) {
        FLEXHookEntry *entry = section.entries[indexPath.row];
        [self configureEntryCell:cell
                           entry:entry
                        position:FLEXCompactPositionForRow(
                            indexPath.row,
                            section.entries.count
                        )];
        return cell;
    }

    if (indexPath.row == 0) {
        [self configureCell:cell
                       text:registry.safeMode
                        ? @"Safe mode active"
                        : @"Safe mode ready"
                  secondary:registry.safeMode
                    ? [NSString stringWithFormat:@"Blocked: %@",
                        registry.safeModeEntryIdentifier ?: @"unknown"]
                    : @"No interrupted Apply transaction detected."
                      image:registry.safeMode
                        ? @"shield.lefthalf.filled"
                        : @"shield.checkered"
                       tint:registry.safeMode
                        ? UIColor.systemOrangeColor
                        : UIColor.systemGreenColor];
        cell.selectionStyle = registry.safeMode
            ? UITableViewCellSelectionStyleDefault
            : UITableViewCellSelectionStyleNone;
        cell.accessoryType = registry.safeMode
            ? UITableViewCellAccessoryDisclosureIndicator
            : UITableViewCellAccessoryNone;
    } else {
        [self configureCell:cell
                       text:@"Errors and stale targets"
                  secondary:self.failedEntries.count
                    ? [NSString stringWithFormat:@"%lu target(s) need attention",
                        (unsigned long)self.failedEntries.count]
                    : @"No runtime hook errors"
                      image:self.failedEntries.count
                        ? @"exclamationmark.triangle.fill"
                        : @"checkmark.seal.fill"
                       tint:self.failedEntries.count
                        ? UIColor.systemOrangeColor
                        : UIColor.systemGreenColor];
        cell.selectionStyle = self.failedEntries.count
            ? UITableViewCellSelectionStyleDefault
            : UITableViewCellSelectionStyleNone;
        cell.accessoryType = self.failedEntries.count
            ? UITableViewCellAccessoryDisclosureIndicator
            : UITableViewCellAccessoryNone;
    }
    FLEXStyleCompactRuntimeCell(
        cell,
        FLEXCompactPositionForRow(indexPath.row, 2)
    );
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section < 0 || section >= (NSInteger)self.sections.count) return nil;
    FLEXHookCenterSection *descriptor = self.sections[(NSUInteger)section];
    switch (descriptor.kind) {
        case FLEXHookCenterSectionPendingGroup:
            return [NSString stringWithFormat:@"Pending · %@", descriptor.title];
        case FLEXHookCenterSectionActiveGroup:
            return [NSString stringWithFormat:@"Installed · %@", descriptor.title];
        default:
            return descriptor.title;
    }
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section < 0 || section >= (NSInteger)self.sections.count) return nil;
    FLEXHookCenterSection *descriptor = self.sections[(NSUInteger)section];
    if (descriptor.kind == FLEXHookCenterSectionPendingEmpty ||
        descriptor.kind == FLEXHookCenterSectionPendingGroup) {
        return @"Switches only stage changes. No patch, swizzle or hook is installed until Apply is pressed.";
    }
    if (descriptor.kind == FLEXHookCenterSectionActiveEmpty ||
        descriptor.kind == FLEXHookCenterSectionActiveGroup) {
        return @"Staging OFF keeps the physical trampoline until Apply; after Apply it forwards directly to the original implementation.";
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FLEXHookCenterSection *section = self.sections[indexPath.section];
    if (section.kind == FLEXHookCenterSectionPendingGroup ||
        section.kind == FLEXHookCenterSectionActiveGroup) {
        FLEXHookEntryDetailController *detail =
            [[FLEXHookEntryDetailController alloc]
                initWithEntry:section.entries[indexPath.row]];
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }
    if (section.kind == FLEXHookCenterSectionRecovery) {
        if (indexPath.row == 0 && FLEXHookRegistry.sharedRegistry.safeMode) {
            [self confirmClearSafeMode];
        } else if (indexPath.row == 1 && self.failedEntries.count) {
            [self presentErrorSummary];
        }
    }
}

- (void)hookToggleChanged:(UISwitch *)toggle {
    NSString *identifier = objc_getAssociatedObject(
        toggle,
        kFLEXHookCenterIdentifierKey
    );
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL requested = toggle.isOn;
    FLEXHookEntry *entry = [registry entryForIdentifier:identifier];
    if (requested && entry && !entry.userConfigured) {
        [registry stageForceValue:YES forEntryIdentifier:identifier];
    }
    [registry stageEnabled:requested forEntryIdentifier:identifier];
    entry = [registry entryForIdentifier:identifier];
    BOOL accepted = entry && entry.pendingEnabled == requested;
    [toggle setOn:accepted ? requested : !requested animated:YES];
    if (accepted) {
        [UISelectionFeedbackGenerator.new selectionChanged];
    } else {
        [UINotificationFeedbackGenerator.new
            notificationOccurred:UINotificationFeedbackTypeError];
    }
    [self reloadState];
}

- (void)discardPending {
    [FLEXHookRegistry.sharedRegistry discardPendingChanges];
    [UINotificationFeedbackGenerator.new
        notificationOccurred:UINotificationFeedbackTypeWarning];
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
        if (restart) [self confirmCloseAndReopen];
        return;
    }

    [registry applyPendingWithCompletion:^(
        NSArray<FLEXHookEntry *> *applied,
        NSArray<FLEXHookEntry *> *failed
    ) {
        [UINotificationFeedbackGenerator.new
            notificationOccurred:failed.count
                ? UINotificationFeedbackTypeError
                : UINotificationFeedbackTypeSuccess];
        if (failed.count) {
            NSString *message = [NSString stringWithFormat:
                @"Applied %lu change(s). %lu target(s) failed current-host, image, ABI or provider validation.",
                (unsigned long)applied.count,
                (unsigned long)failed.count];
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
        } else if (restart) {
            [self confirmCloseAndReopen];
        }
    }];
}

- (void)confirmCloseAndReopen {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Apply & Restart"
                         message:@"A jailed iOS app cannot relaunch itself. Confirmed state will be synchronized, the app will close, and you must open it again manually."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close App"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults synchronize];
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{ exit(0); }
        );
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearSafeMode {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Leave safe mode?"
                         message:@"The blocked target remains disabled. Leaving safe mode only unlocks normal Apply operations."
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
            entry.title,
            entry.lastError ?: @"Unknown error"]];
        if (lines.count == 12) {
            [lines addObject:@"• More entries are available in their Runtime tab."];
            break;
        }
    }
    if (!lines.count) [lines addObject:@"No runtime errors."];
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
