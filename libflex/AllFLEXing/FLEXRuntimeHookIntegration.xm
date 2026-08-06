#import "FLEXRuntimeHookActions.h"
#import "FLEXMetadataSection.h"
#import "FLEXTableViewCell.h"

// Static, known integration points belong in Logos. Targets selected from the
// rows themselves are still installed dynamically through the shared registry
// and MSHookMessageEx after exact ABI validation.
%group AllFLEXingRuntimeRows

%hook FLEXMetadataSection

- (void)configureCell:(FLEXTableViewCell *)cell forRow:(NSInteger)row {
    %orig;
    [FLEXRuntimeHookActions configureCell:cell inSection:self row:row];
}

- (NSArray *)menuItemsForRow:(NSInteger)row
                       sender:(UIViewController *)sender {
    NSArray *existing = %orig;
    return [FLEXRuntimeHookActions
        menuItemsForSection:self
                        row:row
                     sender:sender
              existingItems:existing ?: @[]];
}

%end

%end

%ctor {
    %init(AllFLEXingRuntimeRows);
}
