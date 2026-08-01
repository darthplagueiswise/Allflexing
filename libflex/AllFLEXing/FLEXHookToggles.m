#import "FLEXHookToggles.h"

#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"
#import "FLEXLiquidGlass.h"
#import "FLEXSymbolRebind.h"

#import <math.h>
#import <objc/runtime.h>
#import <stdlib.h>

static const void *kFLEXHookCenterIdentifierKey = &kFLEXHookCenterIdentifierKey;

typedef NS_ENUM(NSInteger, FLEXHookCenterSection) {
    FLEXHookCenterSectionEngines = 0,
    FLEXHookCenterSectionPending,
    FLEXHookCenterSectionActive,
    FLEXHookCenterSectionRecovery,
    FLEXHookCenterSectionCount,
};

@interface FLEXHookMetricView : UIView
@property (nonatomic) UILabel *valueLabel;
@property (nonatomic) UILabel *captionLabel;
- (void)setValue:(NSString *)value caption:(NSString *)caption tint:(UIColor *)tint;
@end

@implementation FLEXHookMetricView

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        [FLEXLiquidGlass configureCornersForView:self radius:18.0 capsule:NO];

        _valueLabel = [UILabel new];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:22.0
                                                           weight:UIFontWeightSemibold];
        _valueLabel.adjustsFontForContentSizeCategory = YES;
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _captionLabel = [UILabel new];
        _captionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _captionLabel.textColor = UIColor.secondaryLabelColor;
        _captionLabel.adjustsFontForContentSizeCategory = YES;
        _captionLabel.translatesAutoresizingMaskIntoConstraints = NO;

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
    }
    return self;
}

- (void)setValue:(NSString *)value caption:(NSString *)caption tint:(UIColor *)tint {
    self.valueLabel.text = value;
    self.valueLabel.textColor = tint;
    self.captionLabel.text = caption;
}

@end

@interface FLEXHookCenterHeaderView : UIView
@property (nonatomic) UILabel *providerLabel;
@property (nonatomic) UILabel *summaryLabel;
@property (nonatomic) UIStackView *metricsStack;
@property (nonatomic) FLEXHookMetricView *activeMetric;
@property (nonatomic) FLEXHookMetricView *pendingMetric;
@property (nonatomic) FLEXHookMetricView *errorMetric;
- (void)updateWithRegistry:(FLEXHookRegistry *)registry;
@end

@implementation FLEXHookCenterHeaderView

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
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

        UIStackView *headingLabels = [[UIStackView alloc]
            initWithArrangedSubviews:@[title, _providerLabel]];
        headingLabels.axis = UILayoutConstraintAxisVertical;
        headingLabels.spacing = 2.0;

        UIStackView *heading = [[UIStackView alloc]
            initWithArrangedSubviews:@[icon, headingLabels]];
        heading.axis = UILayoutConstraintAxisHorizontal;
        heading.alignment = UIStackViewAlignmentCenter;
        heading.spacing = 12.0;

        _summaryLabel = [UILabel new];
        _summaryLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _summaryLabel.textColor = UIColor.secondaryLabelColor;
        _summaryLabel.adjustsFontForContentSizeCategory = YES;
        _summaryLabel.numberOfLines = 0;

        _activeMetric = [FLEXHookMetricView new];
        _pendingMetric = [FLEXHookMetricView new];
        _errorMetric = [FLEXHookMetricView new];
        _metricsStack = [[UIStackView alloc]
            initWithArrangedSubviews:@[_activeMetric, _pendingMetric, _errorMetric]];
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
    }
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
        ? UIColor.systemGreenColor : UIColor.systemOrangeColor;
    self.summaryLabel.text = registry.safeMode
        ? @"Safe mode is active. Review the blocked target before applying another batch."
        : @"Validated Objective-C and C targets share one registry, live gates, persistence and diagnostics.";
    [self.activeMetric setValue:[NSString stringWithFormat:@"%lu", (unsigned long)registry.activeCount]
                         caption:@"Effective"
                            tint:UIColor.systemGreenColor];
    [self.pendingMetric setValue:[NSString stringWithFormat:@"%lu", (unsigned long)registry.pendingCount]
                          caption:@"Pending"
                             tint:UIColor.systemBlueColor];
    [self.errorMetric setValue:[NSString stringWithFormat:@"%lu", (unsigned long)registry.failureCount]
                        caption:@"Errors"
                           tint:registry.failureCount ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor];
    [self setNeedsLayout];
}

@end

@interface FLEXHookToggles ()
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *pendingEntries;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *activeEntries;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *failedEntries;
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
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76.0;
    [FLEXLiquidGlass applyToViewController:self];
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
    [self updateNavigationActions];

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
    if (!header || width <= 0.0) {
        return;
    }
    CGRect frame = header.frame;
    frame.size.width = width;
    header.frame = frame;
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGSize size = [header systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                       withHorizontalFittingPriority:UILayoutPriorityRequired
                             verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (fabs(CGRectGetHeight(frame) - size.height) > 0.5) {
        frame.size.height = size.height;
        header.frame = frame;
        self.tableView.tableHeaderView = header;
    }
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
    if (applying) {
        restart.attributes = UIMenuElementAttributesDisabled;
    }
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
                                     children:@[discard, restart, diagnostics, safeMode]];

    UIBarButtonItem *separator = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace
                             target:nil
                             action:nil];
    separator.width = 8.0;
    if (@available(iOS 26.0, *)) {
        separator.hidesSharedBackground = YES;
    }
    self.navigationItem.rightBarButtonItems = @[self.applyItem, separator, self.moreItem];
    if (@available(iOS 26.0, *)) {
        self.navigationItem.subtitle = [NSString stringWithFormat:@"%lu effective · %lu pending",
            (unsigned long)registry.activeCount,
            (unsigned long)registry.pendingCount];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return FLEXHookCenterSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case FLEXHookCenterSectionEngines: return 3;
        case FLEXHookCenterSectionPending: return MAX((NSInteger)self.pendingEntries.count, 1);
        case FLEXHookCenterSectionActive: return MAX((NSInteger)self.activeEntries.count, 1);
        case FLEXHookCenterSectionRecovery: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)baseCellForTableView:(UITableView *)tableView {
    static NSString *identifier = @"AllFLEXingHookCenterCell";
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

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self baseCellForTableView:tableView];
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    if (indexPath.section == FLEXHookCenterSectionEngines) {
        NSArray<NSString *> *titles = @[@"Objective-C methods", @"Imported C symbols", @"Inline C functions"];
        NSArray<NSString *> *images = @[@"curlybraces", @"link", @"function"];
        NSArray<NSString *> *details = @[
            FLEXMSHookMessageProviderAvailable()
                ? [NSString stringWithFormat:@"%@ · MSHookMessageEx ready", registry.providerName]
                : @"Substrate-compatible Objective-C provider unavailable",
            FLEXSymbolRebind.backendDescription,
            FLEXMSHookFunctionProviderAvailable()
                ? [NSString stringWithFormat:@"%@ · MSHookFunction ready", registry.providerName]
                : @"Substrate-compatible inline provider unavailable",
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
                       tint:ready ? UIColor.systemGreenColor : UIColor.systemOrangeColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == FLEXHookCenterSectionPending) {
        if (!self.pendingEntries.count) {
            [self configureCell:cell
                           text:@"Nothing waiting"
                      secondary:@"Persisted intent and effective runtime state are synchronized."
                          image:@"checkmark.circle.fill"
                           tint:UIColor.systemGreenColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            [self configureEntryCell:cell entry:self.pendingEntries[indexPath.row]];
        }
        return cell;
    }
    if (indexPath.section == FLEXHookCenterSectionActive) {
        if (!self.activeEntries.count) {
            [self configureCell:cell
                           text:@"No installed runtime hooks"
                      secondary:@"Choose a validated target in either Runtime tab."
                          image:@"power"
                           tint:UIColor.secondaryLabelColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            [self configureEntryCell:cell entry:self.activeEntries[indexPath.row]];
        }
        return cell;
    }
    if (indexPath.row == 0) {
        NSString *secondary = registry.safeMode
            ? [NSString stringWithFormat:@"Blocked target: %@",
                registry.safeModeEntryIdentifier ?: @"unknown"]
            : @"No interrupted transaction detected.";
        NSString *image = registry.safeMode
            ? @"shield.lefthalf.filled" : @"shield.checkered";
        [self configureCell:cell
                       text:registry.safeMode ? @"Safe mode active" : @"Safe mode ready"
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
            ? [NSString stringWithFormat:@"%lu target(s) need attention.",
                (unsigned long)self.failedEntries.count]
            : @"No runtime hook errors.";
        NSString *image = self.failedEntries.count
            ? @"exclamationmark.triangle.fill" : @"checkmark.seal.fill";
        [self configureCell:cell
                       text:@"Errors and stale targets"
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

- (void)configureEntryCell:(UITableViewCell *)cell entry:(FLEXHookEntry *)entry {
    [self configureCell:cell
                   text:entry.title
              secondary:[NSString stringWithFormat:@"%@\n%@", entry.detail, entry.statusSummary]
                  image:entry.effectiveEnabled ? @"bolt.circle.fill" : @"circle.dashed"
                   tint:entry.effectiveEnabled ? UIColor.systemGreenColor : UIColor.secondaryLabelColor];
    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
    [toggle sizeToFit];
    toggle.accessibilityLabel = [NSString stringWithFormat:@"Runtime hook for %@", entry.title];
    toggle.accessibilityValue = entry.statusSummary;
    objc_setAssociatedObject(toggle,
                             kFLEXHookCenterIdentifierKey,
                             entry.identifier,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self
               action:@selector(hookToggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    switch (section) {
        case FLEXHookCenterSectionEngines: return @"Runtime engines";
        case FLEXHookCenterSectionPending: return @"Pending";
        case FLEXHookCenterSectionActive: return @"Installed";
        case FLEXHookCenterSectionRecovery: return @"Health";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == FLEXHookCenterSectionPending) {
        return @"Each switch applies only its own target. Apply commits any remaining batch after revalidating target, ABI and provider.";
    }
    if (section == FLEXHookCenterSectionActive) {
        return @"Turning an installed hook off forwards calls to its original implementation; unsafe physical unhooking is avoided.";
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == FLEXHookCenterSectionPending && self.pendingEntries.count) {
        [self showEntry:self.pendingEntries[indexPath.row]];
    } else if (indexPath.section == FLEXHookCenterSectionActive && self.activeEntries.count) {
        [self showEntry:self.activeEntries[indexPath.row]];
    } else if (indexPath.section == FLEXHookCenterSectionRecovery && indexPath.row == 0 &&
               FLEXHookRegistry.sharedRegistry.safeMode) {
        [self confirmClearSafeMode];
    } else if (indexPath.section == FLEXHookCenterSectionRecovery && indexPath.row == 1 &&
               self.failedEntries.count) {
        [self presentErrorSummary];
    }
}

- (void)showEntry:(FLEXHookEntry *)entry {
    FLEXHookEntryDetailController *detail =
        [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
    [self.navigationController pushViewController:detail animated:YES];
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
                         message:@"A jailed iOS app cannot relaunch itself. Settings will be synchronized, the app will close, and you must open it again manually."
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
        if (lines.count == 12) {
            [lines addObject:@"• More entries are available in their Runtime tab."];
            break;
        }
    }
    if (!lines.count) {
        [lines addObject:@"No runtime errors."];
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
