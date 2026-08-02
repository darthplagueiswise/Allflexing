#import <UIKit/UIKit.h>

@class FLEXHookEntry;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FLEXCompactCellPosition) {
    FLEXCompactCellPositionSingle = 0,
    FLEXCompactCellPositionFirst,
    FLEXCompactCellPositionMiddle,
    FLEXCompactCellPositionLast,
};

@interface FLEXRuntimeEntryGroup : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *entries;
@end

@interface FLEXRuntimeGroupHeaderView : UITableViewHeaderFooterView
- (void)configureWithTitle:(NSString *)title detail:(nullable NSString *)detail;
@end

FOUNDATION_EXPORT NSArray<FLEXRuntimeEntryGroup *> *FLEXRuntimeGroupEntries(
    NSArray<FLEXHookEntry *> *entries
);
FOUNDATION_EXPORT NSString *FLEXRuntimeGroupTitleForEntry(FLEXHookEntry *entry);
FOUNDATION_EXPORT NSString *FLEXRuntimeMemberTitleForEntry(FLEXHookEntry *entry);
FOUNDATION_EXPORT NSString *FLEXRuntimeCompactSummaryForEntry(FLEXHookEntry *entry);

FOUNDATION_EXPORT void FLEXConfigureCompactRuntimeTable(UITableView *tableView);
FOUNDATION_EXPORT void FLEXStyleCompactRuntimeCell(
    UITableViewCell *cell,
    FLEXCompactCellPosition position
);
FOUNDATION_EXPORT void FLEXConfigureCompactRuntimeContent(
    UITableViewCell *cell,
    NSString *title,
    NSString * _Nullable secondary,
    NSString * _Nullable symbolName,
    UIColor *tint
);
FOUNDATION_EXPORT UIView *FLEXCompactAccessoryContainer(
    UIView *accessory,
    CGFloat visualScale
);
FOUNDATION_EXPORT FLEXCompactCellPosition FLEXCompactPositionForRow(
    NSUInteger row,
    NSUInteger count
);

NS_ASSUME_NONNULL_END
