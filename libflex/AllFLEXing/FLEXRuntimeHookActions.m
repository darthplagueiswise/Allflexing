#import "FLEXRuntimeHookActions.h"

#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXRuntimeScanner.h"
#import "FLEXMetadataSection.h"
#import "FLEXMethod.h"
#import "FLEXObjectExplorer.h"
#import "FLEXProperty.h"
#import "FLEXTableViewCell.h"

#import <objc/message.h>
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
+ (nullable NSNumber *)probeNoArgumentGetterForEntry:(FLEXHookEntry *)entry
                                               target:(nullable id)target;
@end

@interface FLEXRuntimeHookToggleTarget : NSObject
@property (nonatomic, weak) FLEXMetadataSection *section;
@property (nonatomic, weak) id probeTarget;
@property (nonatomic, copy) NSString *entryIdentifier;
- (void)switchChanged:(UISwitch *)toggle;
@end

@implementation FLEXRuntimeHookToggleTarget

- (void)switchChanged:(UISwitch *)toggle {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL requestedState = toggle.isOn;
    FLEXHookEntry *entry = [registry entryForIdentifier:self.entryIdentifier];
    if (requestedState && entry && !entry.userConfigured) {
        // A bare switch has one deterministic meaning: force TRUE. The menu
        // remains the explicit place to select FALSE or forwarding-original.
        [registry stageForceValue:YES forEntryIdentifier:self.entryIdentifier];
    }
    [registry stageEnabled:requestedState forEntryIdentifier:self.entryIdentifier];
    entry = [registry entryForIdentifier:self.entryIdentifier];
    if (!entry || entry.pendingEnabled != requestedState) {
        [toggle setOn:entry.pendingEnabled animated:YES];
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeError];
        [self.section reloadData:YES];
        return;
    }

    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
    toggle.enabled = NO;
    __weak typeof(self) weakSelf = self;
    [registry applyEntryIdentifier:self.entryIdentifier completion:^(
        NSArray<FLEXHookEntry *> *applied,
        NSArray<FLEXHookEntry *> *failed
    ) {
        FLEXRuntimeHookToggleTarget *strongSelf = weakSelf;
        FLEXHookEntry *resolved = [registry entryForIdentifier:strongSelf.entryIdentifier];
        NSNumber *probeResult = nil;
        if (!failed.count && requestedState) {
            probeResult = [FLEXRuntimeHookActions
                probeNoArgumentGetterForEntry:resolved
                                       target:strongSelf.probeTarget];
            if (probeResult && !probeResult.boolValue) {
                [registry failClosedEntryIdentifier:strongSelf.entryIdentifier
                                             reason:@"Provider installed a replacement, but a direct Objective-C dispatch probe did not cross it"];
                resolved = [registry entryForIdentifier:strongSelf.entryIdentifier];
            }
        }
        [toggle setOn:resolved.pendingEnabled animated:YES];
        toggle.enabled = (resolved.available && resolved.hookable) || resolved.pendingEnabled;
        UINotificationFeedbackGenerator *resultFeedback = [UINotificationFeedbackGenerator new];
        BOOL verificationFailed = probeResult && !probeResult.boolValue;
        UINotificationFeedbackType feedbackType = failed.count || verificationFailed
            ? UINotificationFeedbackTypeError
            : (resolved.overrideHitCount > 0
                ? UINotificationFeedbackTypeSuccess
                : UINotificationFeedbackTypeWarning);
        [resultFeedback notificationOccurred:feedbackType];
        (void)applied;
        [strongSelf.section reloadData:YES];
    }];
}

@end

@implementation FLEXRuntimeHookActions

+ (BOOL)selectorLooksLikeSideEffectFreeGetter:(NSString *)selectorName {
    if (selectorName.length == 0 || [selectorName containsString:@":"]) {
        return NO;
    }
    NSArray<NSString *> *prefixes = @[@"is", @"has", @"can", @"should", @"allows", @"supports"];
    for (NSString *prefix in prefixes) {
        if ([selectorName hasPrefix:prefix]) {
            return YES;
        }
    }
    return [selectorName hasSuffix:@"Value"];
}

+ (NSNumber *)probeNoArgumentGetterForEntry:(FLEXHookEntry *)entry target:(id)target {
    if (!entry || entry.abi != FLEXHookABIObjCBoolNoArguments || !target) {
        return nil;
    }
    NSString *selectorName = [entry.locator[@"selector"] isKindOfClass:NSString.class]
        ? entry.locator[@"selector"] : nil;
    if (![self selectorLooksLikeSideEffectFreeGetter:selectorName]) {
        return nil;
    }
    SEL selector = NSSelectorFromString(selectorName);
    id receiver = [entry.locator[@"classMethod"] boolValue]
        ? (id)NSClassFromString(entry.locator[@"class"])
        : target;
    if (!receiver || ![receiver respondsToSelector:selector]) {
        return nil;
    }

    NSUInteger before = entry.overrideHitCount;
    @try {
        BOOL (*sendBool)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        (void)sendBool(receiver, selector);
    } @catch (__unused NSException *exception) {
        return @NO;
    }
    return @(entry.overrideHitCount > before);
}

#pragma mark - Target resolution

+ (Class)baseClassForTarget:(id)target {
    if (!target) {
        return Nil;
    }
    return object_isClass(target) ? (Class)target : object_getClass(target);
}

+ (FLEXHookEntry *)registeredEntryForClass:(Class)targetClass
                                  selector:(SEL)selector
                               classMethod:(BOOL)classMethod {
    FLEXHookEntry *candidate = [FLEXRuntimeScanner
        objectiveCEntryForClass:targetClass
                      selector:selector
                   classMethod:classMethod];
    if (!candidate) {
        return nil;
    }
    return [FLEXHookRegistry.sharedRegistry upsertDiscoveredEntry:candidate];
}

+ (FLEXHookEntry *)entryForMethod:(FLEXMethod *)method target:(id)target {
    if (![method isKindOfClass:FLEXMethod.class]) {
        return nil;
    }
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
    if (row < 0 || row >= (NSInteger)metadata.count) {
        return nil;
    }
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
    FLEXHookEntry *entry = [self entryForMethod:method target:target];
    return [self actionsForEntry:entry sender:sender refresh:nil];
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
    FLEXHookEntry *entry = [self entryForBoolProperty:property target:target];
    return [self actionsForEntry:entry sender:sender refresh:nil];
}

+ (BOOL)setOverrideState:(NSNumber *)state forEntry:(FLEXHookEntry *)entry {
    if (!entry) {
        return NO;
    }

    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    if (!state) {
        [registry stageEnabled:NO forEntryIdentifier:entry.identifier];
        BOOL accepted = !entry.pendingEnabled;
        if (accepted) {
            [registry applyEntryIdentifier:entry.identifier completion:nil];
        }
        return accepted;
    }
    if (!entry.available || !entry.hookable) {
        return NO;
    }

    [registry stageForceValue:state.boolValue forEntryIdentifier:entry.identifier];
    [registry stageEnabled:YES forEntryIdentifier:entry.identifier];
    BOOL accepted = entry.pendingEnabled && entry.forceValue == state.boolValue;
    if (accepted) {
        [registry applyEntryIdentifier:entry.identifier completion:nil];
    }
    return accepted;
}

#pragma mark - Context menu

+ (void)openDetailForEntry:(FLEXHookEntry *)entry sender:(UIViewController *)sender {
    if (!entry || !sender) {
        return;
    }
    FLEXHookEntryDetailController *detail =
        [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
    if (sender.navigationController) {
        [sender.navigationController pushViewController:detail animated:YES];
    } else {
        UINavigationController *navigation =
            [[UINavigationController alloc] initWithRootViewController:detail];
        [sender presentViewController:navigation animated:YES completion:nil];
    }
}

+ (void)presentApplyResultFrom:(UIViewController *)sender
                       applied:(NSArray<FLEXHookEntry *> *)applied
                        failed:(NSArray<FLEXHookEntry *> *)failed {
    if (!sender.viewIfLoaded.window) {
        return;
    }
    NSString *title = failed.count ? @"Hook Errors" : @"Hook Armed";
    NSString *message = [NSString stringWithFormat:
        @"%lu armed · %lu failed. A hook becomes Observed after a real target call crosses its replacement.",
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
    if (!entry) {
        return @[];
    }

    __weak UIViewController *weakSender = sender;
    void (^stage)(NSNumber *) = ^(NSNumber *state) {
        [self setOverrideState:state forEntry:entry];
        if (refresh) {
            refresh();
        }
        UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
        [feedback selectionChanged];
    };

    UIAction *forceTrue = [UIAction
        actionWithTitle:@"Force TRUE"
                  image:[UIImage systemImageNamed:@"checkmark.circle.fill"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        stage(@YES);
    }];
    forceTrue.state = entry.pendingEnabled && entry.forceValue
        ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction *forceFalse = [UIAction
        actionWithTitle:@"Force FALSE"
                  image:[UIImage systemImageNamed:@"xmark.circle.fill"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        stage(@NO);
    }];
    forceFalse.state = entry.pendingEnabled && !entry.forceValue
        ? UIMenuElementStateOn : UIMenuElementStateOff;

    if (!entry.available || !entry.hookable) {
        forceTrue.attributes = UIMenuElementAttributesDisabled;
        forceFalse.attributes = UIMenuElementAttributesDisabled;
    }

    UIMenu *forcedResult = [UIMenu
        menuWithTitle:@"Forced Result"
                image:[UIImage systemImageNamed:@"switch.2"]
           identifier:nil
              options:UIMenuOptionsDisplayInline
             children:@[forceTrue, forceFalse]];

    UIAction *disable = [UIAction
        actionWithTitle:@"Forward Original"
                  image:[UIImage systemImageNamed:@"arrow.triangle.branch"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        stage(nil);
    }];
    disable.state = entry.pendingEnabled
        ? UIMenuElementStateOff : UIMenuElementStateOn;

    UIAction *apply = [UIAction
        actionWithTitle:@"Reapply This Hook"
                  image:[UIImage systemImageNamed:@"checkmark.seal"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        [FLEXHookRegistry.sharedRegistry applyEntryIdentifier:entry.identifier completion:^(
            NSArray<FLEXHookEntry *> *applied,
            NSArray<FLEXHookEntry *> *failed) {
            if (refresh) {
                refresh();
            }
            [self presentApplyResultFrom:weakSender applied:applied failed:failed];
        }];
    }];
    apply.attributes = entry.available && entry.hookable
        ? 0 : UIMenuElementAttributesDisabled;

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

    NSString *menuTitle = [NSString stringWithFormat:@"Runtime Hook · %@",
        entry.statusSummary];
    UIMenu *menu = [UIMenu
        menuWithTitle:menuTitle
                image:[UIImage systemImageNamed:@"waveform.path.ecg"]
           identifier:nil
              options:0
             children:@[forcedResult, disable, apply, details, copyIdentifier]];
    return @[menu];
}

#pragma mark - FLEX row integration

+ (UIImage *)statusImageForEntry:(FLEXHookEntry *)entry {
    NSString *name = @"circle";
    if (entry.lastError.length) {
        name = @"exclamationmark.triangle.fill";
    } else if (entry.pendingEnabled != entry.desiredEnabled) {
        name = @"clock.arrow.circlepath";
    } else if (entry.installed && entry.effectiveEnabled) {
        name = entry.overrideHitCount > 0 ? @"checkmark.circle.fill" : @"bolt.circle.fill";
    } else if (entry.installed) {
        name = @"arrow.triangle.branch";
    }
    return [UIImage systemImageNamed:name];
}

+ (UIColor *)statusColorForEntry:(FLEXHookEntry *)entry {
    if (entry.lastError.length) {
        return UIColor.systemRedColor;
    }
    if (entry.pendingEnabled != entry.desiredEnabled) {
        return UIColor.systemOrangeColor;
    }
    if (entry.installed && entry.effectiveEnabled) {
        return entry.overrideHitCount > 0 ? UIColor.systemGreenColor : UIColor.systemBlueColor;
    }
    return UIColor.tertiaryLabelColor;
}

+ (void)configureCell:(FLEXTableViewCell *)cell
             inSection:(FLEXMetadataSection *)section
                   row:(NSInteger)row {
    // FLEXMetadataSection cells are reused across metadata kinds. Its original
    // implementation resets accessoryType, but UIKit does not clear a custom
    // accessoryView for us; remove our previous switch before resolving this
    // row so an unsupported ABI can never inherit another target's toggle.
    cell.accessoryView = nil;

    id metadata = [self metadataForSection:section row:row];
    FLEXHookEntry *entry = [self entryForMetadata:metadata
                                          target:section.explorer.object];
    if (!entry) {
        return;
    }

    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
    [toggle sizeToFit];
    toggle.accessibilityLabel = [NSString stringWithFormat:@"Runtime hook for %@",
        entry.title];
    toggle.accessibilityValue = entry.statusSummary;

    FLEXRuntimeHookToggleTarget *target = [FLEXRuntimeHookToggleTarget new];
    target.section = section;
    target.probeTarget = section.explorer.object;
    target.entryIdentifier = entry.identifier;
    [toggle addTarget:target
               action:@selector(switchChanged:)
     forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(toggle,
                             kFLEXRuntimeHookToggleTargetKey,
                             target,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = toggle;

    NSString *baseSubtitle = cell.subtitleLabel.text ?: @"";
    NSString *hookSubtitle = [NSString stringWithFormat:@"Runtime hook: %@",
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
    if (!entry) {
        return existingItems ?: @[];
    }

    __weak FLEXMetadataSection *weakSection = section;
    NSArray<UIMenuElement *> *hookItems = [self
        actionsForEntry:entry
                 sender:sender
                refresh:^{
        [weakSection reloadData:YES];
    }];
    if (hookItems.count == 0) {
        return existingItems ?: @[];
    }

    NSMutableArray<UIMenuElement *> *combined = [NSMutableArray arrayWithArray:hookItems];
    [combined addObjectsFromArray:existingItems ?: @[]];
    return combined.copy;
}

@end
