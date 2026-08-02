#import "FLEXCompactRuntimeUI.h"

#import "FLEXHookRegistry.h"
#import "FLEXLiquidGlass.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static const void *kFLEXCompactBackgroundKey = &kFLEXCompactBackgroundKey;
static const void *kFLEXCompactSelectionKey = &kFLEXCompactSelectionKey;

static UIFont *FLEXCompactScaledFont(CGFloat size,
                                     UIFontWeight weight,
                                     UIFontTextStyle style,
                                     CGFloat maximum) {
    UIFont *base = [UIFont systemFontOfSize:size weight:weight];
    return [[UIFontMetrics metricsForTextStyle:style]
        scaledFontForFont:base maximumPointSize:maximum];
}

static UIColor *FLEXCompactCanvasColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? UIColor.blackColor : UIColor.systemBackgroundColor;
    }];
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
        ? FLEXCompactCanvasColor() : UIColor.systemGroupedBackgroundColor;
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

FLEXCompactCellPosition FLEXCompactPositionForRow(NSUInteger row,
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
