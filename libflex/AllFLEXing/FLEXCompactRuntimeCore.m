#import "FLEXCompactRuntimeUI.h"

#import "FLEXHookRegistry.h"
#import "FLEXLiquidGlass.h"

__attribute__((used)) static const char kFLEXNativeGroupedTableMarker[] =
    "AllFLEXing native grouped UIKit table ABI 3 live-class-hierarchy";

@implementation FLEXRuntimeEntryGroup
@end

@implementation FLEXRuntimeGroupHeaderView

- (void)configureWithTitle:(NSString *)title detail:(NSString *)detail {
    UIListContentConfiguration *content = [self defaultContentConfiguration];
    content.text = title;
    content.secondaryText = detail;
    content.textProperties.numberOfLines = 0;
    content.textProperties.lineBreakMode = NSLineBreakByCharWrapping;
    content.secondaryTextProperties.numberOfLines = 0;
    content.secondaryTextProperties.lineBreakMode = NSLineBreakByWordWrapping;
    self.contentConfiguration = content;
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
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    if (methodPrefix) {
        *methodPrefix = [trimmed hasPrefix:@"+"] ? @"+" : @"-";
    }
    return YES;
}

static NSString *FLEXRuntimeLocatorString(FLEXHookEntry *entry,
                                          NSString *key) {
    id value = [entry.locator isKindOfClass:NSDictionary.class]
        ? entry.locator[key] : nil;
    return [value isKindOfClass:NSString.class] ? value : nil;
}

NSString *FLEXRuntimeGroupTitleForEntry(FLEXHookEntry *entry) {
    if (entry.surface == FLEXHookSurfaceObjectiveC) {
        // Runtime identity lives in the locator. Do not reconstruct hierarchy
        // from a display string: registry canonicalization may legitimately
        // rewrite titles while the class/selector locator remains stable.
        NSString *className = FLEXRuntimeLocatorString(entry, @"class");
        if (className.length) return className;

        if (FLEXParseObjectiveCTitle(entry.title, &className, NULL, NULL) &&
            className.length) {
            return className;
        }
        return @"Objective-C runtime";
    }

    if (entry.surface == FLEXHookSurfaceCImport) {
        return @"Imported C symbols";
    }
    if (entry.surface == FLEXHookSurfaceCInline) {
        return @"Mach-O functions";
    }
    if (entry.imageName.length) {
        return entry.imageName.lastPathComponent;
    }
    return @"Runtime";
}

NSString *FLEXRuntimeMemberTitleForEntry(FLEXHookEntry *entry) {
    if (entry.surface == FLEXHookSurfaceObjectiveC) {
        NSString *selector = FLEXRuntimeLocatorString(entry, @"selector");
        if (selector.length) {
            BOOL classMethod = [entry.locator[@"classMethod"] boolValue];
            return [NSString stringWithFormat:@"%@ %@",
                classMethod ? @"+" : @"-", selector];
        }
    }

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
    NSMutableDictionary<NSString *, NSMutableArray<FLEXHookEntry *> *> *members =
        [NSMutableDictionary dictionary];

    for (FLEXHookEntry *entry in entries ?: @[]) {
        NSString *title = FLEXRuntimeGroupTitleForEntry(entry) ?: @"Runtime";
        NSMutableArray<FLEXHookEntry *> *group = members[title];
        if (!group) {
            group = [NSMutableArray array];
            members[title] = group;
        }
        [group addObject:entry];
    }

    NSArray<NSString *> *titles = [members.allKeys
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray<FLEXRuntimeEntryGroup *> *groups =
        [NSMutableArray arrayWithCapacity:titles.count];
    for (NSString *title in titles) {
        FLEXRuntimeEntryGroup *group = [FLEXRuntimeEntryGroup new];
        group.title = title;
        group.entries = [members[title] sortedArrayUsingComparator:^NSComparisonResult(
            FLEXHookEntry *left,
            FLEXHookEntry *right
        ) {
            return [FLEXRuntimeMemberTitleForEntry(left)
                localizedCaseInsensitiveCompare:FLEXRuntimeMemberTitleForEntry(right)];
        }];
        [groups addObject:group];
    }
    return groups.copy;
}

void FLEXConfigureCompactRuntimeTable(UITableView *tableView) {
    BOOL glass = FLEXLiquidGlass.isGlassAvailable && FLEXLiquidGlass.isEnabled;
    tableView.backgroundColor = glass ? UIColor.clearColor : UIColor.systemGroupedBackgroundColor;
    tableView.opaque = !glass;
    tableView.separatorStyle = glass
        ? UITableViewCellSeparatorStyleNone
        : UITableViewCellSeparatorStyleSingleLine;
    tableView.separatorColor = UIColor.separatorColor;
    tableView.cellLayoutMarginsFollowReadableWidth = NO;
    tableView.estimatedRowHeight = 72.0;
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.sectionHeaderTopPadding = 8.0;
    tableView.contentInset = UIEdgeInsetsZero;
    tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

void FLEXStyleCompactRuntimeCell(UITableViewCell *cell,
                                 FLEXCompactCellPosition position) {
    BOOL glass = FLEXLiquidGlass.isGlassAvailable && FLEXLiquidGlass.isEnabled;
    cell.preservesSuperviewLayoutMargins = YES;
    cell.contentView.backgroundColor = UIColor.clearColor;

    if (!glass) {
        cell.backgroundView = nil;
        cell.selectedBackgroundView = nil;
        cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        [FLEXLiquidGlass styleTableCell:cell];
        return;
    }

    UIView *panel = cell.backgroundView;
    if (![panel isKindOfClass:UIVisualEffectView.class]) {
        panel = [FLEXLiquidGlass glassViewInteractive:YES tint:nil];
        panel.userInteractionEnabled = NO;
        cell.backgroundView = panel;
    }
    cell.backgroundColor = UIColor.clearColor;

    CGFloat radius = 17.0;
    BOOL single = position == FLEXCompactCellPositionSingle;
    [FLEXLiquidGlass configureCornersForView:panel radius:radius capsule:single];

    UIView *selection = cell.selectedBackgroundView;
    if (!selection) {
        selection = [UIView new];
        cell.selectedBackgroundView = selection;
    }
    selection.backgroundColor = UIColor.tertiarySystemFillColor;
    [FLEXLiquidGlass configureCornersForView:selection radius:radius capsule:single];
}

void FLEXConfigureCompactRuntimeContent(UITableViewCell *cell,
                                        NSString *title,
                                        NSString *secondary,
                                        NSString *symbolName,
                                        UIColor *tint) {
    UIListContentConfiguration *content =
        [UIListContentConfiguration subtitleCellConfiguration];
    content.text = title;
    content.secondaryText = secondary;
    content.textProperties.numberOfLines = 0;
    content.textProperties.lineBreakMode = NSLineBreakByCharWrapping;
    content.secondaryTextProperties.numberOfLines = 2;
    content.secondaryTextProperties.lineBreakMode = NSLineBreakByWordWrapping;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.directionalLayoutMargins =
        NSDirectionalEdgeInsetsMake(8.0, 8.0, 8.0, 8.0);

    if (symbolName.length) {
        content.image = [UIImage systemImageNamed:symbolName];
        content.imageProperties.tintColor = tint;
        content.imageProperties.maximumSize = CGSizeMake(20.0, 20.0);
    }
    cell.contentConfiguration = content;
}

UIView *FLEXCompactAccessoryContainer(UIView *accessory, CGFloat visualScale) {
    (void)visualScale;
    return accessory;
}

FLEXCompactCellPosition FLEXCompactPositionForRow(NSUInteger row,
                                                   NSUInteger count) {
    if (count <= 1) return FLEXCompactCellPositionSingle;
    if (row == 0) return FLEXCompactCellPositionFirst;
    if (row + 1 == count) return FLEXCompactCellPositionLast;
    return FLEXCompactCellPositionMiddle;
}
