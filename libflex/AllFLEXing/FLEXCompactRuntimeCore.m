#import "FLEXCompactRuntimeUI.h"

#import "FLEXHookRegistry.h"

__attribute__((used)) static const char kFLEXNativeGroupedTableMarker[] =
    "AllFLEXing native grouped UIKit table ABI 1";

@implementation FLEXRuntimeEntryGroup
@end

@implementation FLEXRuntimeGroupHeaderView

- (void)configureWithTitle:(NSString *)title detail:(NSString *)detail {
    UIListContentConfiguration *content = [self defaultContentConfiguration];
    content.text = title;
    content.secondaryText = detail;
    content.textProperties.numberOfLines = 1;
    content.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    content.secondaryTextProperties.numberOfLines = 1;
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
    tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    tableView.opaque = YES;
    tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    tableView.separatorColor = UIColor.separatorColor;
    tableView.cellLayoutMarginsFollowReadableWidth = YES;
    tableView.estimatedRowHeight = 54.0;
    tableView.rowHeight = UITableViewAutomaticDimension;
    tableView.sectionHeaderTopPadding = 8.0;
    tableView.contentInset = UIEdgeInsetsZero;
    tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
    tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

void FLEXStyleCompactRuntimeCell(UITableViewCell *cell,
                                 FLEXCompactCellPosition position) {
    (void)position;
    cell.backgroundView = nil;
    cell.selectedBackgroundView = nil;
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.contentView.backgroundColor = UIColor.clearColor;
    cell.preservesSuperviewLayoutMargins = YES;
}

void FLEXConfigureCompactRuntimeContent(UITableViewCell *cell,
                                        NSString *title,
                                        NSString *secondary,
                                        NSString *symbolName,
                                        UIColor *tint) {
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = title;
    content.secondaryText = secondary;
    content.textProperties.numberOfLines = 1;
    content.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
    content.secondaryTextProperties.numberOfLines = 1;
    content.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingTail;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;

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
