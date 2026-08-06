#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class FLEXHookableObjCSearchController;

/// Minimal delegate: the search controller owns the table's data source and
/// search bar, and calls back when a class row is chosen.
@protocol FLEXHookableObjCSearchControllerDelegate <NSObject>
@property (nonatomic, readonly) UITableView *tableView;
@property (nonatomic, readonly) UISearchController *searchController;
- (void)hookableSearchDidSelectClass:(Class)cls;
@end

/// Drop-in replacement for FLEXKeyPathSearchController used by the AllFLEXing
/// Objective-C browser.
///
/// It reuses FLEX's optimized data layer (FLEXRuntimeClient's cached class and
/// method enumeration) and the same background-filter-then-reload pattern, but
/// replaces the key-path grammar entirely. There is no `*`, `+`, `-`, no
/// `Bundle.Class.-method` syntax and no hard-coded semantics: the user types
/// natural words in any order and classes are matched on a normalized form
/// (camelCase / snake_case / compact are all equivalent) across the class name,
/// its methods and its image. Only classes exposing at least one hookable
/// method are ever listed.
@interface FLEXHookableObjCSearchController : NSObject
    <UISearchResultsUpdating, UITableViewDataSource, UITableViewDelegate>

+ (instancetype)delegate:(id<FLEXHookableObjCSearchControllerDelegate>)delegate;

/// Kicks off the one-time background discovery if it hasn't happened yet.
- (void)loadIfNeeded;

@end

NS_ASSUME_NONNULL_END
