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
- (void)configureWithTitle:(NSString *)title count:(NSUInteger)count;
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
    nullable NSString *secondary,
    nullable NSString *symbolName,
    UIColor *tint
);
FOUNDATION_EXPORT UIView *FLEXCompactAccessoryContainer(
    UIView *accessory,
    CGFloat visualScale
);

NS_ASSUME_NONNULL_END
