#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class FLEXHookEntry;
@class FLEXMetadataSection;
@class FLEXMethod;
@class FLEXProperty;
@class FLEXTableViewCell;

/// Contextual runtime-hook actions shared by FLEX metadata rows and the global
/// Hook Center. All state is owned by FLEXHookRegistry; this class never keeps
/// a second hook store.
@interface FLEXRuntimeHookActions : NSObject

+ (BOOL)canHookMethod:(FLEXMethod *)method target:(id)target;
+ (nullable NSNumber *)overrideStateForMethod:(FLEXMethod *)method target:(id)target;
+ (BOOL)setOverrideState:(nullable NSNumber *)state
                forMethod:(FLEXMethod *)method
                   target:(id)target;
+ (NSArray<UIMenuElement *> *)actionsForMethod:(FLEXMethod *)method
                                        target:(id)target
                                        sender:(UIViewController *)sender;

+ (BOOL)canHookBoolProperty:(FLEXProperty *)property target:(id)target;
+ (nullable NSNumber *)overrideStateForBoolProperty:(FLEXProperty *)property
                                             target:(id)target;
+ (BOOL)setOverrideState:(nullable NSNumber *)state
          forBoolProperty:(FLEXProperty *)property
                   target:(id)target;
+ (NSArray<UIMenuElement *> *)actionsForBoolProperty:(FLEXProperty *)property
                                              target:(id)target
                                              sender:(UIViewController *)sender;

/// Entry points used by the Logos integration layer. They are intentionally
/// section-oriented so filtering and cell reuse always resolve the current row.
+ (void)configureCell:(FLEXTableViewCell *)cell
             inSection:(FLEXMetadataSection *)section
                   row:(NSInteger)row;
+ (NSArray<UIMenuElement *> *)menuItemsForSection:(FLEXMetadataSection *)section
                                              row:(NSInteger)row
                                           sender:(UIViewController *)sender
                                    existingItems:(NSArray<UIMenuElement *> *)existingItems;

@end

NS_ASSUME_NONNULL_END
