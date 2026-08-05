#import "FLEXObjectExplorerViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// Hook-aware object explorer for a single class.
///
/// It subclasses FLEX's own object explorer, so the class's properties, ivars,
/// methods, protocols and hierarchy all render exactly as FLEX renders them,
/// with FLEX's own search and navigation. AllFLEXing layers two things on top:
///  1. A custom section at the very top listing the class's hookable methods
///     (those with a concrete supported ABI), each with a runtime-hook toggle
///     and a tap-through to the hook detail screen.
///  2. Exclusion of non-hookable methods whose selector/encoding disagree, which
///     both declutters the list and avoids FLEX's argument-decoding exception on
///     structurally inconsistent runtime methods.
@interface FLEXHookableObjectExplorerViewController : FLEXObjectExplorerViewController

+ (instancetype)exploringHookableClass:(Class)cls;

@end

NS_ASSUME_NONNULL_END
