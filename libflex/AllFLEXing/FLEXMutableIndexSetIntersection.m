#import "FLEXCHookEngine.h"

@implementation NSMutableIndexSet (AllFLEXingIntersection)

- (void)intersectIndexes:(NSIndexSet *)indexes {
    if (!indexes.count) {
        [self removeAllIndexes];
        return;
    }
    if (!self.count) {
        return;
    }

    // Compute self - indexes, then remove that difference from self. This uses
    // Foundation's native index-set range implementation and avoids per-symbol
    // work during each Runtime Browser keystroke.
    NSMutableIndexSet *outsideIntersection = self.mutableCopy;
    [outsideIntersection removeIndexes:indexes];
    [self removeIndexes:outsideIntersection];
}

@end
