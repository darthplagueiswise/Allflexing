#import "FLEXCompactRuntimeUI.h"

#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXHookToggles.h"
#import "FLEXHooking.h"
#import "FLEXLiquidGlass.h"
#import "FLEXRuntimeBrowserController.h"
#import "FLEXSymbolRebind.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static const void *kFLEXCompactBackgroundKey = &kFLEXCompactBackgroundKey;
static const void *kFLEXCompactSelectionKey = &kFLEXCompactSelectionKey;
static const void *kFLEXCompactEntryIdentifierKey = &kFLEXCompactEntryIdentifierKey;

static UIFont *FLEXCompactScaledFont(CGFloat size,
                                     UIFontWeight weight,
                                     UIFontTextStyle style,
                                     CGFloat maximum) {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    return [[UIFontMetrics metricsForTextStyle:style]
        scaledFontForFont:base maximumPointSize:maximum];
}

static UIColor *FLEXCompactPanelFill(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.072]
            : [UIColor colorWithWhite:0.0 alpha:0.034];
    }];
}

static UIColor *FLEXCompactBorderColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1.0 alpha:0.12]
            : [UIColor colorWithWhite:0.0 alpha:0.09];
    }];
}

@interface FLEXCompactGroupBackgroundView : UIView
@property (nonatomic) UIView *surface;
@property (nonatomic) UIView *separator;
@property (nonatomic) BOOL selectedPresentation;
@property (nonatomic) FLEXCompactCellPosition position;
- (instancetype)initSelectedPresentation:(BOOL)selectedPresentation;
@end

@implementation FLEXCompactGroupBackgroundView

- (instancetype)initSelectedPresentation:(BOOL)selectedPresentation {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _selectedPresentation = selectedPresentation;
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        [self rebuildSurface];

        _separator = [UIView new];
        _separator.backgroundColor = [UIColor.separatorColor colorWithAlphaComponent:0.42];
        _separator.userInteractionEnabled = NO;
        [self addSubview:_separator];
    }
    return self;
}

- (void)rebuildSurface {
    [self.surface removeFromSuperview];
    BOOL usesGlass = FLEXLiquidGlass.isEnabled && FLEXLiquidGlass.isGlassAvailable;
    if (self.selectedPresentation) {
        UIView *surface = [UIView new];
        surface.backgroundColor = [UIColor.systemBlueColor colorWithAlphaComponent:0.17];
        self.surface = surface;
    } else if (usesGlass) {
        UIVisualEffectView *surface = [FLEXLiquidGlass glassViewInteractive:YES tint:nil];
        surface.userInteractionEnabled = NO;
        surface.contentView.backgroundColor = FLEXCompactPanelFill();
        self.surface = surface;
    } else {
        UIView *surface = [UIView new];
        surface.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        self.surface = surface;
    }
    self.surface.userInteractionEnabled = NO;
    self.surface.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    self.surface.layer.borderColor = [FLEXCompactBorderColor()
        resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    [self insertSubview:self.surface atIndex:0];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.surface.layer.borderColor = [FLEXCompactBorderColor()
        resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    if ([self.surface isKindOfClass:UIVisualEffectView.class]) {
        ((UIVisualEffectView *)self.surface).contentView.backgroundColor =
            FLEXCompactPanelFill();
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect surfaceFrame = UIEdgeInsetsInsetRect(
        self.bounds,
        UIEdgeInsetsMake(0.0, 8.0, 0.0, 8.0)
    );
    self.surface.frame = surfaceFrame;

    CGFloat radius = 15.0;
    self.surface.layer.cornerCurve = kCACornerCurveContinuous;
    self.surface.layer.masksToBounds = YES;
    switch (self.position) {
        case FLEXCompactCellPositionSingle:
            self.surface.layer.cornerRadius = radius;
            self.surface.layer.maskedCorners = kCALayerMinXMinYCorner |
                                               kCALayerMaxXMinYCorner |
                                               kCALayerMinXMaxYCorner |
                                               kCALayerMaxXMaxYCorner;
            break;
        case FLEXCompactCellPositionFirst:
            self.surface.layer.cornerRadius = radius;
            self.surface.layer.maskedCorners = kCALayerMinXMinYCorner |
                                               kCALayerMaxXMinYCorner;
            break;
        case FLEXCompactCellPositionLast:
            self.surface.layer.cornerRadius = radius;
            self.surface.layer.maskedCorners = kCALayerMinXMaxYCorner |
                                               kCALayerMaxXMaxYCorner;
            break;
        case FLEXCompactCellPositionMiddle:
            self.surface.layer.cornerRadius = 0.0;
            self.surface.layer.maskedCorners = 0;
            break;
    }

    BOOL showsSeparator = self.position == FLEXCompactCellPositionFirst ||
                          self.position == FLEXCompactCellPositionMiddle;
    self.separator.hidden = !showsSeparator || self.selectedPresentation;
    CGFloat pixel = 1.0 / UIScreen.mainScreen.scale;
    self.separator.frame = CGRectMake(
        CGRectGetMinX(surfaceFrame) + 44.0,
        CGRectGetMaxY(surfaceFrame) - pixel,
        MAX(CGRectGetWidth(surfaceFrame) - 58.0, 0.0),
        pixel
    );
}

@end

@implementation FLEXRuntimeEntryGroup
@end

@interface FLEXRuntimeGroupHeaderView ()
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) UILabel *detailLabel;
@end

@implementation FLEXRuntimeGroupHeaderView

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithReuseIdentifier:reuseIdentifier];
    if (self) {
        self.contentView.backgroundColor = UIColor.clearColor;

        _titleLabel = [UILabel new];
        _titleLabel.font = FLEXCompactScaledFont(
            12.5,
            UIFontWeightSemibold,
            UIFontTextStyleSubheadline,
            15.0
        );
        _titleLabel.textColor = UIColor.secondaryLabelColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        _detailLabel = [UILabel new];
        _detailLabel.font = FLEXCompactScaledFont(
            10.5,
            UIFontWeightMedium,
            UIFontTextStyleCaption2,
            12.5
        );
        _detailLabel.textColor = UIColor.tertiaryLabelColor;
        _detailLabel.textAlignment = NSTextAlignmentRight;
        [_detailLabel setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisHorizontal];
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;

        [self.contentView addSubview:_titleLabel];
        [self.contentView addSubview:_detailLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                      constant:14.0],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor
                                                      constant:2.0],
            [_detailLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor
                                                                    constant:8.0],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                         constant:-14.0],
            [_detailLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
            [self.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:28.0],
        ]];
    }
    return self;
}

- (void)configureWithTitle:(NSString *)title detail:(NSString *)detail {
    self.titleLabel.text = title;
    self.detailLabel.text = detail;
    self.detailLabel.hidden = detail.length == 0;
}

@end

static BOOL FLEXParseObjectiveCTitle(NSString *title,
                                    NSString **className,
                                    NSString **memberName,
                                    NSString **methodPrefix) {
    NSString *trimmed = [title stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSRange open = [trimmed rangeOfString:@"["];
    NSRange close = [trimmed rangeOfString:@"]" options:NSBackwardsSearch];
    if (open.location == NSNotFound || close.location == NSNotFound ||
        close.location <= open.location + 1) {
        return NO;
    }
    NSString *inside = [trimmed substringWithRange:NSMakeRange(
        NSMaxRange(open), close.location - NSMaxRange(open))];
    NSRange split = [inside rangeOfCharacterFromSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (split.location == NSNotFound || split.location == 0 ||
        NSMaxRange(split) >= inside.length) {
        return NO;
    }
    if (className) {
        *className = [inside substringToIndex:split.location];
    }
    if (memberName) {
        *memberName = [[inside substringFromIndex:NSMaxRange(split)]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (methodPrefix) {
        *methodPrefix = [trimmed hasPrefix:@"+"] ? @"+" : @"-";
    }
    return YES;
}

NSString *FLEXRuntimeGroupTitleForEntry(FLEXHookEntry *entry) {
    NSString *className = nil;
    if (entry.surface == FLEXHookSurfaceObjectiveC &&
        FLEXParseObjectiveCTitle(entry.title, &className, NULL, NULL)) {
        return className;
    }
    if (entry.imageName.length) {
        return entry.imageName.lastPathComponent;
    }
    return entry.surface == FLEXHookSurfaceCInline
        ? @"Inline C functions" : @"Imported C symbols";
}

NSString *FLEXRuntimeMemberTitleForEntry(FLEXHookEntry *entry) {
    NSString *member = nil;
    NSString *prefix = nil;
    if (entry.surface == FLEXHookSurfaceObjectiveC &&
        FLEXParseObjectiveCTitle(entry.title, NULL, &member, &prefix)) {
        return [NSString stringWithFormat:@"%@ %@", prefix, member];
    }
    return entry.title.length ? entry.title : entry.identifier;
}

NSString *FLEXRuntimeCompactSummaryForEntry(FLEXHookEntry *entry) {
    NSString *abi = entry.detail.length
        ? [entry.detail componentsSeparatedByString:@" · "].firstObject
        : FLEXHookABIName(entry.abi);
    NSString *state = nil;
    if (entry.lastError.length) {
        state = @"Error";
    } else if (entry.effectiveEnabled && entry.overrideHitCount > 0) {
        state = @"Observed";
    } else if (entry.effectiveEnabled || entry.installed) {
        state = @"Armed";
    } else if (entry.available && entry.hookable) {
        state = @"Ready";
    } else {
        state = @"Inspect only";
    }
    if (entry.pendingEnabled || entry.effectiveEnabled) {
        return [NSString stringWithFormat:@"%@ · %@ · %@",
            abi, state, entry.forceValue ? @"TRUE" : @"FALSE"];
    }
    return [NSString stringWithFormat:@"%@ · %@", abi, state];
}

NSArray<FLEXRuntimeEntryGroup *> *FLEXRuntimeGroupEntries(
    NSArray<FLEXHookEntry *> *entries
) {
    NSMutableArray<FLEXRuntimeEntryGroup *> *groups = [NSMutableArray array];
    NSMutableDictionary<NSString *, FLEXRuntimeEntryGroup *> *lookup =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<FLEXHookEntry *> *> *members =
        [NSMutableDictionary dictionary];

    for (FLEXHookEntry *entry in entries) {
        NSString *title = FLEXRuntimeGroupTitleForEntry(entry);
        FLEXRuntimeEntryGroup *group = lookup[title];
        if (!group) {
            group = [FLEXRuntimeEntryGroup new];
            group.title = title;
            lookup[title] = group;
            members[title] = [NSMutableArray array];
            [groups addObject:group];
        }
        [members[title] addObject:entry];
    }
    for (FLEXRuntimeEntryGroup *group in groups) {
        group.entries = members[group.title].copy;
    }
    return groups.copy;
}

void FLEXConfigureCompactRuntimeTable(UITableView *tableView) {
    tableView.backgroundColor = FLEXLiquidGlass.isEnabled && FLEXLiquidGlass.isGlassAvailable
        ? UIColor.blackColor : UIColor.systemGroupedBackgroundColor;
    tableView.opaque = YES;
    tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.cellLayoutMarginsFollowReadableWidth = NO;
    tableView.layoutMargins = UIEdgeInsetsZero;
    tableView.directionalLayoutMargins = NSDirectionalEdgeInsetsZero;
    tableView.estimatedRowHeight = 56.0;
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.sectionHeaderTopPadding = 2.0;
    tableView.contentInset = UIEdgeInsetsMake(2.0, 0.0, 12.0, 0.0);
    tableView.scrollIndicatorInsets = UIEdgeInsetsMake(2.0, 0.0, 12.0, 0.0);
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

void FLEXStyleCompactRuntimeCell(UITableViewCell *cell,
                                 FLEXCompactCellPosition position) {
    FLEXCompactGroupBackgroundView *background = objc_getAssociatedObject(
        cell, kFLEXCompactBackgroundKey);
    if (!background) {
        background = [[FLEXCompactGroupBackgroundView alloc]
            initSelectedPresentation:NO];
        objc_setAssociatedObject(cell,
                                 kFLEXCompactBackgroundKey,
                                 background,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    FLEXCompactGroupBackgroundView *selection = objc_getAssociatedObject(
        cell, kFLEXCompactSelectionKey);
    if (!selection) {
        selection = [[FLEXCompactGroupBackgroundView alloc]
            initSelectedPresentation:YES];
        objc_setAssociatedObject(cell,
                                 kFLEXCompactSelectionKey,
                                 selection,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    background.position = position;
    selection.position = position;
    [background setNeedsLayout];
    [selection setNeedsLayout];

    cell.backgroundColor = UIColor.clearColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.backgroundView = background;
    cell.selectedBackgroundView = selection;
    cell.preservesSuperviewLayoutMargins = NO;
    cell.layoutMargins = UIEdgeInsetsMake(4.0, 14.0, 4.0, 12.0);
    cell.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(4.0, 14.0, 4.0, 12.0);
}

void FLEXConfigureCompactRuntimeContent(UITableViewCell *cell,
                                        NSString *title,
                                        NSString *secondary,
                                        NSString *symbolName,
                                        UIColor *tint) {
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = title;
    content.secondaryText = secondary;
    content.textProperties.font = FLEXCompactScaledFont(
        13.5,
        UIFontWeightSemibold,
        UIFontTextStyleBody,
        17.0
    );
    content.textProperties.numberOfLines = 2;
    content.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    content.secondaryTextProperties.font = FLEXCompactScaledFont(
        10.5,
        UIFontWeightRegular,
        UIFontTextStyleCaption1,
        13.0
    );
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.numberOfLines = 1;
    content.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingTail;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(7.0, 14.0, 7.0, 12.0);
    if (symbolName.length) {
        content.image = [UIImage systemImageNamed:symbolName];
        content.imageProperties.tintColor = tint;
        content.imageProperties.maximumSize = CGSizeMake(21.0, 21.0);
        content.imageToTextPadding = 10.0;
    } else {
        content.image = nil;
    }
    cell.contentConfiguration = content;
}

UIView *FLEXCompactAccessoryContainer(UIView *accessory, CGFloat visualScale) {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 48.0, 44.0)];
    container.backgroundColor = UIColor.clearColor;
    accessory.center = CGPointMake(CGRectGetMidX(container.bounds), CGRectGetMidY(container.bounds));
    accessory.transform = CGAffineTransformMakeScale(visualScale, visualScale);
    accessory.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                 UIViewAutoresizingFlexibleRightMargin |
                                 UIViewAutoresizingFlexibleTopMargin |
                                 UIViewAutoresizingFlexibleBottomMargin;
    [container addSubview:accessory];
    return container;
}

static FLEXCompactCellPosition FLEXCompactPosition(NSUInteger row,
                                                    NSUInteger count) {
    if (count <= 1) {
        return FLEXCompactCellPositionSingle;
    }
    if (row == 0) {
        return FLEXCompactCellPositionFirst;
    }
    if (row + 1 == count) {
        return FLEXCompactCellPositionLast;
    }
    return FLEXCompactCellPositionMiddle;
}

static void FLEXExchangeInstanceMethods(Class cls, SEL original, SEL replacement) {
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
        FLEXExchangeInstanceMethods(cls, @selector(initWithKind:),
                                     @selector(af_compact_initWithKind:));
        FLEXExchangeInstanceMethods(cls, @selector(viewDidLoad),
                                     @selector(af_compact_viewDidLoad));
        FLEXExchangeInstanceMethods(cls, @selector(numberOfSectionsInTableView:),
                                     @selector(af_compact_numberOfSectionsInTableView:));
        FLEXExchangeInstanceMethods(cls, @selector(tableView:numberOfRowsInSection:),
                                     @selector(af_compact_tableView:numberOfRowsInSection:));
        FLEXExchangeInstanceMethods(cls, @selector(tableView:cellForRowAtIndexPath:),
                                     @selector(af_compact_tableView:cellForRowAtIndexPath:));
        FLEXExchangeInstanceMethods(cls, @selector(tableView:didSelectRowAtIndexPath:),
                                     @selector(af_compact_tableView:didSelectRowAtIndexPath:));
    });
}

- (instancetype)af_compact_initWithKind:(FLEXRuntimeBrowserKind)kind {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) {
        [self setValue:@(kind) forKey:@"kind"];
    }
    return self;
}

- (void)af_compact_viewDidLoad {
    [self af_compact_viewDidLoad];
    FLEXConfigureCompactRuntimeTable(self.tableView);
    [self.tableView registerClass:FLEXRuntimeGroupHeaderView.class
           forHeaderFooterViewReuseIdentifier:@"AllFLEXingRuntimeGroupHeader"];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.searchController.searchBar.searchTextField.font = FLEXCompactScaledFont(
        13.5,
        UIFontWeightRegular,
        UIFontTextStyleBody,
        16.0
    );
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
        FLEXCompactPosition(indexPath.row, group.entries.count)
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
        FLEXExchangeInstanceMethods(cls, @selector(init),
                                     @selector(af_compact_init));
        FLEXExchangeInstanceMethods(cls, @selector(viewDidLoad),
                                     @selector(af_compact_viewDidLoad));
        FLEXExchangeInstanceMethods(cls, @selector(numberOfSectionsInTableView:),
                                     @selector(af_compact_numberOfSectionsInTableView:));
        FLEXExchangeInstanceMethods(cls, @selector(tableView:numberOfRowsInSection:),
                                     @selector(af_compact_tableView:numberOfRowsInSection:));
        FLEXExchangeInstanceMethods(cls, @selector(tableView:cellForRowAtIndexPath:),
                                     @selector(af_compact_tableView:cellForRowAtIndexPath:));
        FLEXExchangeInstanceMethods(cls, @selector(tableView:didSelectRowAtIndexPath:),
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
        FLEXStyleCompactRuntimeCell(cell, FLEXCompactPosition(indexPath.row, 3));
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
                                   position:FLEXCompactPosition(indexPath.row,
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
    FLEXStyleCompactRuntimeCell(cell, FLEXCompactPosition(indexPath.row, 2));
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

static void (*FLEXBaseTableViewDidLoad)(id, SEL) = NULL;
static void (*FLEXBaseTableViewWillAppear)(id, SEL, BOOL) = NULL;
static void (*FLEXBaseTableViewDidLayoutSubviews)(id, SEL) = NULL;

static void FLEXStyleVisibleInternalCells(UITableViewController *controller) {
    UITableView *tableView = controller.tableView;
    if (!tableView) {
        return;
    }
    FLEXConfigureCompactRuntimeTable(tableView);
    for (UITableViewCell *cell in tableView.visibleCells) {
        NSIndexPath *indexPath = [tableView indexPathForCell:cell];
        if (!indexPath) {
            continue;
        }
        NSInteger count = [tableView.dataSource tableView:tableView
                                     numberOfRowsInSection:indexPath.section];
        FLEXStyleCompactRuntimeCell(
            cell,
            FLEXCompactPosition(indexPath.row, MAX(count, 1))
        );
        UIListContentConfiguration *content = [cell.contentConfiguration
            isKindOfClass:UIListContentConfiguration.class]
            ? [cell.contentConfiguration copy]
            : nil;
        if (content) {
            content.textProperties.font = FLEXCompactScaledFont(
                13.5,
                UIFontWeightMedium,
                UIFontTextStyleBody,
                17.0
            );
            content.secondaryTextProperties.font = FLEXCompactScaledFont(
                10.5,
                UIFontWeightRegular,
                UIFontTextStyleCaption1,
                13.0
            );
            content.secondaryTextProperties.numberOfLines = 2;
            content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(
                7.0, 14.0, 7.0, 12.0);
            cell.contentConfiguration = content;
        } else {
            cell.textLabel.font = FLEXCompactScaledFont(
                13.5,
                UIFontWeightMedium,
                UIFontTextStyleBody,
                17.0
            );
            cell.detailTextLabel.font = FLEXCompactScaledFont(
                10.5,
                UIFontWeightRegular,
                UIFontTextStyleCaption1,
                13.0
            );
        }
    }
    NSInteger sections = [tableView.dataSource numberOfSectionsInTableView:tableView];
    for (NSInteger section = 0; section < sections; section++) {
        UITableViewHeaderFooterView *header = [tableView headerViewForSection:section];
        header.textLabel.font = FLEXCompactScaledFont(
            12.0,
            UIFontWeightSemibold,
            UIFontTextStyleSubheadline,
            14.5
        );
        header.textLabel.textColor = UIColor.secondaryLabelColor;
        UITableViewHeaderFooterView *footer = [tableView footerViewForSection:section];
        footer.textLabel.font = FLEXCompactScaledFont(
            10.5,
            UIFontWeightRegular,
            UIFontTextStyleCaption1,
            13.0
        );
    }
    UISearchController *search = controller.navigationItem.searchController;
    if (search) {
        search.searchBar.searchTextField.font = FLEXCompactScaledFont(
            13.5,
            UIFontWeightRegular,
            UIFontTextStyleBody,
            16.0
        );
        [FLEXLiquidGlass styleSearchBar:search.searchBar];
    }
}

static void FLEXBaseStyledViewDidLoad(id self, SEL _cmd) {
    if (FLEXBaseTableViewDidLoad) {
        FLEXBaseTableViewDidLoad(self, _cmd);
    }
    UITableViewController *controller = self;
    controller.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    [FLEXLiquidGlass applyToViewController:controller];
    FLEXStyleVisibleInternalCells(controller);
}

static void FLEXBaseStyledViewWillAppear(id self, SEL _cmd, BOOL animated) {
    if (FLEXBaseTableViewWillAppear) {
        FLEXBaseTableViewWillAppear(self, _cmd, animated);
    }
    UITableViewController *controller = self;
    [FLEXLiquidGlass applyToViewController:controller];
    FLEXStyleVisibleInternalCells(controller);
}

static void FLEXBaseStyledViewDidLayoutSubviews(id self, SEL _cmd) {
    if (FLEXBaseTableViewDidLayoutSubviews) {
        FLEXBaseTableViewDidLayoutSubviews(self, _cmd);
    }
    FLEXStyleVisibleInternalCells((UITableViewController *)self);
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

@interface FLEXCompactRuntimeUIBootstrap : NSObject
@end

@implementation FLEXCompactRuntimeUIBootstrap

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
        FLEXInstallClassOverride(
            base,
            @selector(viewWillAppear:),
            (IMP)FLEXBaseStyledViewWillAppear,
            (IMP *)&FLEXBaseTableViewWillAppear
        );
        FLEXInstallClassOverride(
            base,
            @selector(viewDidLayoutSubviews),
            (IMP)FLEXBaseStyledViewDidLayoutSubviews,
            (IMP *)&FLEXBaseTableViewDidLayoutSubviews
        );
    });
}

@end
