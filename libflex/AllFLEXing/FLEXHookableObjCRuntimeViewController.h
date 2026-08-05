#import "FLEXTableViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// AllFLEXing Objective-C browser.
///
/// This reuses FLEX's own table/search infrastructure (FLEXTableViewController
/// provides the search bar, debounced query events, styling and navigation) and
/// FLEX's cached runtime data layer for class/method enumeration. What it does
/// NOT reuse is FLEX's key-path search grammar: the `*` / `+` / `-` operators
/// and the `Bundle.Class.-method` syntax are replaced by a natural-text
/// semantic search (see FLEXHookableObjCSearchController). Selecting a class
/// pushes a hook-aware explorer that keeps FLEX's sections but shows only
/// methods with a concrete supported ABI, each with a runtime-hook toggle.
@interface FLEXHookableObjCRuntimeViewController : FLEXTableViewController
@end

NS_ASSUME_NONNULL_END
