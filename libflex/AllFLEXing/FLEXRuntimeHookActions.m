#import "FLEXRuntimeHookActions.h"

#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXRuntimeScanner.h"
#import "FLEXMetadataSection.h"
#import "FLEXMethod.h"
#import "FLEXObjectExplorer.h"
#import "FLEXProperty.h"
#import "FLEXTableViewCell.h"

#import <objc/runtime.h>

static const void *kFLEXRuntimeHookToggleTargetKey =
    &kFLEXRuntimeHookToggleTargetKey;

@interface FLEXMetadataSection (AllFLEXingRuntimePrivate)
@property (nonatomic, readonly) FLEXObjectExplorer *explorer;
@property (nonatomic, copy) NSArray *metadata;
@end

@interface FLEXRuntimeHookActions ()
+ (nullable FLEXHookEntry *)entryForMethod:(FLEXMethod *)method target:(id)target;
+ (nullable FLEXHookEntry *)entryForBoolProperty:(FLEXProperty *)property
                                          target:(id)target;
+ (BOOL)setOverrideState:(nullable NSNumber *)state
                 forEntry:(nullable FLEXHookEntry *)entry;
+ (NSArray<UIMenuElement *> *)actionsForEntry:(nullable FLEXHookEntry *)entry
                                        sender:(nullable UIViewController *)sender
                                       refresh:(nullable dispatch_block_t)refresh;
@end

@interface FLEXRuntimeHookToggleTarget : NSObject
@property (nonatomic, weak) FLEXMetadataSection *section;
@property (nonatomic, copy) NSString *entryIdentifier;
- (void)switchChanged:(UISwitch *)toggle;
@end

@implementation FLEXRuntimeHookToggleTarget

- (void)switchChanged:(UISwitch *)toggle {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL requested = toggle.isOn;
    FLEXHookEntry *entry = [registry entryForIdentifier:self.entryIdentifier];

    // A transient metadata row is promoted only when the user stages an actual
    // configuration. The bare switch has one deterministic force value: TRUE.
    if (requested && (!entry || !entry.userConfigured)) {
        [registry stageForceValue:YES forEntryIdentifier:self.entryIdentifier];
    }
    [registry stageEnabled:requested forEntryIdentifier:self.entryIdentifier];
    entry = [registry entryForIdentifier:self.entryIdentifier];

    BOOL accepted = requested ? (entry && entry.pendingEnabled)
                              : (!entry || !entry.pendingEnabled);
    [toggle setOn:accepted ? requested : !requested animated:YES];
    toggle.enabled = entry
        ? ((entry.available && entry.hookable) || entry.pendingEnabled)
        : YES;
    if (accepted) {
        [UISelectionFeedbackGenerator.new selectionChanged];
    } else {
        [UINotificationFeedbackGenerator.new
            notificationOccurred:UINotificationFeedbackTypeError];
    }
    [self.section reloadData:YES];
}

@end

@implementation FLEXRuntimeHookActions

#pragma mark - Target resolution

+ (Class)baseClassForTarget:(id)target {
    if (!target) return Nil;
    return object_isClass(target) ? (Class)target : object_getClass(target);
}

+ (FLEXHookEntry *)registeredEntryForClass:(Class)targetClass
                                  selector:(SEL)selector
                               classMethod:(BOOL)classMethod {
    FLEXHookEntry *candidate = [FLEXRuntimeScanner
        objectiveCEntryForClass:targetClass
                      selector:selector
                   classMethod:classMethod];
    if (!candidate) return nil;
    return [FLEXHookRegistry.sharedRegistry upsertDiscoveredEntry:candidate];
}

+ (FLEXHookEntry *)entryForMethod:(FLEXMethod *)method target:(id)target {
    if (![method isKindOfClass:FLEXMethod.class]) return nil;
    return [self registeredEntryForClass:[self baseClassForTarget:target]
                                selector:method.selector
                             classMethod:!method.isInstanceMethod];
}

+ (FLEXHookEntry *)entryForBoolProperty:(FLEXProperty *)property target:(id)target {
    if (![property isKindOfClass:FLEXProperty.class] || !property.likelyGetter) {
        return nil;
    }
    return [self registeredEntryForClass:[self baseClassForTarget:target]
                                selector:property.likelyGetter
                             classMethod:property.isClassProperty];
}

+ (FLEXHookEntry *)entryForMetadata:(id)metadata target:(id)target {
    if ([metadata isKindOfClass:FLEXMethod.class]) {
        return [self entryForMethod:metadata target:target];
    }
    if ([metadata isKindOfClass:FLEXProperty.class]) {
        return [self entryForBoolProperty:metadata target:target];
    }
    return nil;
}

+ (id)metadataForSection:(FLEXMetadataSection *)section row:(NSInteger)row {
    NSArray *metadata = section.metadata;
    if (row < 0 || row >= (NSInteger)metadata.count) return nil;
    return metadata[(NSUInteger)row];
}

#pragma mark - Reference-compatible action API

+ (BOOL)canHookMethod:(FLEXMethod *)method target:(id)target {
    FLEXHookEntry *entry = [self entryForMethod:method target:target];
    return entry.available && entry.hookable;
}

+ (NSNumber *)overrideStateForMethod:(FLEXMethod *)method target:(id)target {
    FLEXHookEntry *entry = [self entryForMethod:method target:target];
    return entry.pendingEnabled ? @(entry.forceValue) : nil;
}

+ (BOOL)setOverrideState:(NSNumber *)state
                forMethod:(FLEXMethod *)method
                   target:(id)target {
    return [self setOverrideState:state
                         forEntry:[self entryForMethod:method target:target]];
}

+ (NSArray<UIMenuElement *> *)actionsForMethod:(FLEXMethod *)method
                                        target:(id)target
                                        sender:(UIViewController *)sender {
    return [self actionsForEntry:[self entryForMethod:method target:target]
                          sender:sender
                         refresh:nil];
}

+ (BOOL)canHookBoolProperty:(FLEXProperty *)property target:(id)target {
    FLEXHookEntry *entry = [self entryForBoolProperty:property target:target];
    return entry.available && entry.hookable;
}

+ (NSNumber *)overrideStateForBoolProperty:(FLEXProperty *)property
                                     target:(id)target {
    FLEXHookEntry *entry = [self entryForBoolProperty:property target:target];
    return entry.pendingEnabled ? @(entry.forceValue) : nil;
}

+ (BOOL)setOverrideState:(NSNumber *)state
          forBoolProperty:(FLEXProperty *)property
                   target:(id)target {
    return [self setOverrideState:state
                         forEntry:[self entryForBoolProperty:property target:target]];
}

+ (NSArray<UIMenuElement *> *)actionsForBoolProperty:(FLEXProperty *)property
                                              target:(id)target
                                              sender:(UIViewController *)sender {
    return [self actionsForEntry:
        [self entryForBoolProperty:property target:target]
                          sender:sender
                         refresh:nil];
}

+ (BOOL)setOverrideState:(NSNumber *)state forEntry:(FLEXHookEntry *)entry {
    if (!entry.identifier.length) return NO;

    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    if (!state) {
        [registry stageEnabled:NO forEntryIdentifier:entry.identifier];
        FLEXHookEntry *resolved = [registry entryForIdentifier:entry.identifier];
        return !resolved || !resolved.pendingEnabled;
    }
    if (!entry.available || !entry.hookable) return NO;

    [registry stageForceValue:state.boolValue
           forEntryIdentifier:entry.identifier];
    [registry stageEnabled:YES forEntryIdentifier:entry.identifier];
    FLEXHookEntry *resolved = [registry entryForIdentifier:entry.identifier];
    return resolved && resolved.pendingEnabled &&
        resolved.forceValue == state.boolValue;
}

#pragma mark - Context menu

+ (void)openDetailForEntry:(FLEXHookEntry *)entry sender:(UIViewController *)sender {
    if (!entry || !sender) return;
    FLEXHookEntryDetailController *detail =
        [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
    if (sender.navigationController) {
        [sender.navigationController pushViewController:detail animated:YES];
    } else {
        UINavigationController *navigation = [[UINavigationController alloc]
            initWithRootViewController:detail];
        [sender presentViewController:navigation animated:YES completion:nil];
    }
}

+ (void)presentApplyResultFrom:(UIViewController *)sender
                       applied:(NSArray<FLEXHookEntry *> *)applied
                        failed:(NSArray<FLEXHookEntry *> *)failed {
    if (!sender.viewIfLoaded.window) return;
    NSString *title = failed.count ? @"Hook Errors" : @"Hook Armed";
    NSString *message = [NSString stringWithFormat:
        @"%lu armed · %lu failed. A hook becomes Observed only after a real target call crosses its replacement.",
        (unsigned long)applied.count,
        (unsigned long)failed.count];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:title
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [sender presentViewController:alert animated:YES completion:nil];
}

+ (NSArray<UIMenuElement *> *)actionsForEntry:(FLEXHookEntry *)entry
                                        sender:(UIViewController *)sender
                                       refresh:(dispatch_block_t)refresh {
    if (!entry) return @[];

    __weak UIViewController *weakSender = sender;
    void (^stage)(NSNumber *) = ^(NSNumber *state) {
        BOOL accepted = [self setOverrideState:state forEntry:entry];
        if (refresh) refresh();
        if (accepted) {
            [UISelectionFeedbackGenerator.new selectionChanged];
        } else {
            [UINotificationFeedbackGenerator.new
                notificationOccurred:UINotificationFeedbackTypeError];
        }
    };

    UIAction *forceTrue = [UIAction
        actionWithTitle:@"Stage Force TRUE"
                  image:[UIImage systemImageNamed:@"checkmark.circle.fill"]
             identifier:nil
                handler:^(__unused UIAction *action) { stage(@YES); }];
    forceTrue.state = entry.pendingEnabled && entry.forceValue
        ? UIMenuElementStateOn
        : UIMenuElementStateOff;

    UIAction *forceFalse = [UIAction
        actionWithTitle:@"Stage Force FALSE"
                  image:[UIImage systemImageNamed:@"xmark.circle.fill"]
             identifier:nil
                handler:^(__unused UIAction *action) { stage(@NO); }];
    forceFalse.state = entry.pendingEnabled && !entry.forceValue
        ? UIMenuElementStateOn
        : UIMenuElementStateOff;

    if (!entry.available || !entry.hookable) {
        forceTrue.attributes = UIMenuElementAttributesDisabled;
        forceFalse.attributes = UIMenuElementAttributesDisabled;
    }

    UIMenu *forcedResult = [UIMenu
        menuWithTitle:@"Staged Result"
                image:[UIImage systemImageNamed:@"switch.2"]
           identifier:nil
              options:UIMenuOptionsDisplayInline
             children:@[forceTrue, forceFalse]];

    UIAction *disable = [UIAction
        actionWithTitle:@"Stage Forward Original"
                  image:[UIImage systemImageNamed:@"arrow.triangle.branch"]
             identifier:nil
                handler:^(__unused UIAction *action) { stage(nil); }];
    disable.state = entry.pendingEnabled
        ? UIMenuElementStateOff
        : UIMenuElementStateOn;

    UIAction *apply = [UIAction
        actionWithTitle:@"Apply This Hook"
                  image:[UIImage systemImageNamed:@"checkmark.seal"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        [FLEXHookRegistry.sharedRegistry
            applyEntryIdentifier:entry.identifier
                      completion:^(
                NSArray<FLEXHookEntry *> *applied,
                NSArray<FLEXHookEntry *> *failed
            ) {
                if (refresh) refresh();
                [self presentApplyResultFrom:weakSender
                                     applied:applied
                                      failed:failed];
            }];
    }];
    apply.attributes = entry.available && entry.hookable
        ? 0
        : UIMenuElementAttributesDisabled;

    UIAction *details = [UIAction
        actionWithTitle:@"Hook Details"
                  image:[UIImage systemImageNamed:@"info.circle"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        [self openDetailForEntry:entry sender:weakSender];
    }];

    UIAction *copyIdentifier = [UIAction
        actionWithTitle:@"Copy Hook ID"
                  image:[UIImage systemImageNamed:@"doc.on.doc"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        UIPasteboard.generalPasteboard.string = entry.identifier;
    }];

    UIMenu *menu = [UIMenu
        menuWithTitle:[NSString stringWithFormat:@"Runtime Hook · %@",
            entry.statusSummary]
                image:[UIImage systemImageNamed:@"waveform.path.ecg"]
           identifier:nil
              options:0
             children:@[
        forcedResult,
        disable,
        apply,
        details,
        copyIdentifier,
    ]];
    return @[menu];
}

#pragma mark - FLEX row integration

+ (void)configureCell:(FLEXTableViewCell *)cell
             inSection:(FLEXMetadataSection *)section
                   row:(NSInteger)row {
    cell.accessoryView = nil;

    id metadata = [self metadataForSection:section row:row];
    FLEXHookEntry *entry = [self entryForMetadata:metadata
                                          target:section.explorer.object];
    if (!entry) return;

    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
    [toggle sizeToFit];
    toggle.accessibilityLabel = [NSString stringWithFormat:
        @"Stage runtime hook for %@", entry.title];
    toggle.accessibilityValue = entry.statusSummary;

    FLEXRuntimeHookToggleTarget *target = [FLEXRuntimeHookToggleTarget new];
    target.section = section;
    target.entryIdentifier = entry.identifier;
    [toggle addTarget:target
               action:@selector(switchChanged:)
     forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(
        toggle,
        kFLEXRuntimeHookToggleTargetKey,
        target,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = toggle;
    NSString *baseSubtitle = cell.subtitleLabel.text ?: @"";
    NSString *hookSubtitle = [NSString stringWithFormat:
        @"Runtime hook: %@ · staged until Apply",
        entry.statusSummary];
    cell.subtitleLabel.text = baseSubtitle.length
        ? [NSString stringWithFormat:@"%@\n%@", baseSubtitle, hookSubtitle]
        : hookSubtitle;
    cell.subtitleLabel.numberOfLines = 0;
}

+ (NSArray<UIMenuElement *> *)menuItemsForSection:(FLEXMetadataSection *)section
                                              row:(NSInteger)row
                                           sender:(UIViewController *)sender
                                    existingItems:(NSArray<UIMenuElement *> *)existingItems {
    id metadata = [self metadataForSection:section row:row];
    FLEXHookEntry *entry = [self entryForMetadata:metadata
                                          target:section.explorer.object];
    if (!entry) return existingItems ?: @[];

    __weak FLEXMetadataSection *weakSection = section;
    NSArray<UIMenuElement *> *hookItems = [self
        actionsForEntry:entry
                 sender:sender
                refresh:^{ [weakSection reloadData:YES]; }];
    if (!hookItems.count) return existingItems ?: @[];

    NSMutableArray<UIMenuElement *> *combined =
        [NSMutableArray arrayWithArray:hookItems];
    [combined addObjectsFromArray:existingItems ?: @[]];
    return combined.copy;
}

@end
