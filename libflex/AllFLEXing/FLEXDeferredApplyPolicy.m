#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXHookToggles.h"
#import "FLEXRuntimeBrowserController.h"
#import "FLEXRuntimeHookActions.h"

#import <objc/runtime.h>

const char *FLEXDeferredApplyPolicyABIVersion =
    "AllFLEXing staged toggles explicit-Apply-only ABI 1";

typedef void (*FLEXSwitchActionIMP)(id object, SEL selector, UISwitch *toggle);
typedef BOOL (*FLEXSetOverrideIMP)(id object,
                                   SEL selector,
                                   NSNumber *state,
                                   FLEXHookEntry *entry);
typedef NSString *(*FLEXFooterIMP)(id object,
                                   SEL selector,
                                   UITableView *tableView,
                                   NSInteger section);

static FLEXFooterIMP FLEXOriginalHookCenterFooter = NULL;

static UITableViewCell *FLEXCellContainingControl(UIControl *control) {
    UIView *view = control;
    while (view && ![view isKindOfClass:UITableViewCell.class]) {
        view = view.superview;
    }
    return (UITableViewCell *)view;
}

static FLEXHookEntry *FLEXEntryAtToggle(UISwitch *toggle,
                                        UITableViewController *controller,
                                        NSArray<FLEXHookEntry *> *entries) {
    UITableViewCell *cell = FLEXCellContainingControl(toggle);
    NSIndexPath *indexPath = cell
        ? [controller.tableView indexPathForCell:cell] : nil;
    if (!indexPath || indexPath.row >= (NSInteger)entries.count) {
        return nil;
    }
    return entries[(NSUInteger)indexPath.row];
}

static FLEXHookEntry *FLEXEnsurePersistentConfigurationEntry(FLEXHookEntry *entry) {
    if (!entry.identifier.length) {
        return nil;
    }
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    FLEXHookEntry *current = [registry entryForIdentifier:entry.identifier];
    if (current) {
        return current;
    }

    // Snapshot rows remain transient while browsing. The first actual user
    // configuration promotes only that row; opening a detail screen does not.
    FLEXHookEntry *promoted = [entry copy];
    promoted.userConfigured = YES;
    return [registry upsertDiscoveredEntry:promoted] ?: promoted;
}

static FLEXHookEntry *FLEXStageRuntimeState(FLEXHookEntry *entry,
                                            BOOL enabled,
                                            NSNumber *forceValue) {
    FLEXHookEntry *current = FLEXEnsurePersistentConfigurationEntry(entry);
    if (!current) {
        return nil;
    }

    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    if (forceValue) {
        [registry stageForceValue:forceValue.boolValue
               forEntryIdentifier:current.identifier];
    } else if (enabled && !current.userConfigured) {
        [registry stageForceValue:YES
               forEntryIdentifier:current.identifier];
    }
    [registry stageEnabled:enabled forEntryIdentifier:current.identifier];
    return [registry entryForIdentifier:current.identifier] ?: current;
}

static void FLEXProvideStagedFeedback(BOOL accepted) {
    if (accepted) {
        [UISelectionFeedbackGenerator.new selectionChanged];
    } else {
        [UINotificationFeedbackGenerator.new
            notificationOccurred:UINotificationFeedbackTypeError];
    }
}

static void FLEXHookCenterToggleChanged(id object,
                                        SEL selector,
                                        UISwitch *toggle) {
    (void)selector;
    FLEXHookToggles *controller = object;
    UITableViewCell *cell = FLEXCellContainingControl(toggle);
    NSIndexPath *indexPath = cell
        ? [controller.tableView indexPathForCell:cell] : nil;
    FLEXHookEntry *entry = nil;
    @try {
        if (indexPath.section == 1) {
            NSArray *pending = [controller valueForKey:@"pendingEntries"];
            if (indexPath.row < (NSInteger)pending.count) {
                entry = pending[(NSUInteger)indexPath.row];
            }
        } else if (indexPath.section == 2) {
            NSArray *active = [controller valueForKey:@"activeEntries"];
            if (indexPath.row < (NSInteger)active.count) {
                entry = active[(NSUInteger)indexPath.row];
            }
        }
    } @catch (__unused NSException *exception) {
    }

    BOOL requested = toggle.isOn;
    NSNumber *defaultForce = requested && entry && !entry.userConfigured
        ? @YES : nil;
    FLEXHookEntry *staged = FLEXStageRuntimeState(
        entry,
        requested,
        defaultForce
    );
    BOOL accepted = staged && staged.pendingEnabled == requested;
    [toggle setOn:staged ? staged.pendingEnabled : !requested animated:YES];
    FLEXProvideStagedFeedback(accepted);
    @try {
        [controller performSelector:NSSelectorFromString(@"reloadState")];
    } @catch (__unused NSException *exception) {
    }
}

static void FLEXRuntimeBrowserToggleChanged(id object,
                                             SEL selector,
                                             UISwitch *toggle) {
    (void)selector;
    FLEXRuntimeBrowserController *controller = object;
    NSArray<FLEXHookEntry *> *entries = nil;
    @try {
        entries = [controller valueForKey:@"filteredEntries"];
    } @catch (__unused NSException *exception) {
        entries = @[];
    }
    FLEXHookEntry *entry = FLEXEntryAtToggle(toggle, controller, entries ?: @[]);
    BOOL requested = toggle.isOn;
    NSNumber *defaultForce = requested && entry && !entry.userConfigured
        ? @YES : nil;
    FLEXHookEntry *staged = FLEXStageRuntimeState(
        entry,
        requested,
        defaultForce
    );
    BOOL accepted = staged && staged.pendingEnabled == requested;
    [toggle setOn:staged ? staged.pendingEnabled : !requested animated:YES];
    FLEXProvideStagedFeedback(accepted);
}

static void FLEXDetailEnabledChanged(id object,
                                     SEL selector,
                                     UISwitch *toggle) {
    (void)selector;
    FLEXHookEntryDetailController *controller = object;
    FLEXHookEntry *entry = nil;
    @try {
        entry = [controller valueForKey:@"entry"];
    } @catch (__unused NSException *exception) {
    }
    BOOL requested = toggle.isOn;
    NSNumber *defaultForce = requested && entry && !entry.userConfigured
        ? @YES : nil;
    FLEXHookEntry *staged = FLEXStageRuntimeState(
        entry,
        requested,
        defaultForce
    );
    BOOL accepted = staged && staged.pendingEnabled == requested;
    [toggle setOn:staged ? staged.pendingEnabled : !requested animated:YES];
    FLEXProvideStagedFeedback(accepted);
    if (staged) {
        @try {
            [controller setValue:staged forKey:@"entry"];
            [controller performSelector:NSSelectorFromString(@"updateNavigationState")];
        } @catch (__unused NSException *exception) {
        }
    }
    [controller.tableView reloadData];
}

static void FLEXDetailForceChanged(id object,
                                   SEL selector,
                                   UISwitch *toggle) {
    (void)selector;
    FLEXHookEntryDetailController *controller = object;
    FLEXHookEntry *entry = nil;
    @try {
        entry = [controller valueForKey:@"entry"];
    } @catch (__unused NSException *exception) {
    }
    FLEXHookEntry *current = FLEXEnsurePersistentConfigurationEntry(entry);
    if (current) {
        [FLEXHookRegistry.sharedRegistry
            stageForceValue:toggle.isOn
         forEntryIdentifier:current.identifier];
        current = [FLEXHookRegistry.sharedRegistry
            entryForIdentifier:current.identifier] ?: current;
        @try {
            [controller setValue:current forKey:@"entry"];
            [controller performSelector:NSSelectorFromString(@"updateNavigationState")];
        } @catch (__unused NSException *exception) {
        }
    }
    FLEXProvideStagedFeedback(current != nil);
    [controller.tableView reloadData];
}

static void FLEXMetadataRuntimeToggleChanged(id object,
                                              SEL selector,
                                              UISwitch *toggle) {
    (void)selector;
    NSString *identifier = nil;
    id section = nil;
    @try {
        identifier = [object valueForKey:@"entryIdentifier"];
        section = [object valueForKey:@"section"];
    } @catch (__unused NSException *exception) {
    }
    FLEXHookEntry *entry = [FLEXHookRegistry.sharedRegistry
        entryForIdentifier:identifier];
    BOOL requested = toggle.isOn;
    NSNumber *defaultForce = requested && entry && !entry.userConfigured
        ? @YES : nil;
    FLEXHookEntry *staged = FLEXStageRuntimeState(
        entry,
        requested,
        defaultForce
    );
    BOOL accepted = staged && staged.pendingEnabled == requested;
    [toggle setOn:staged ? staged.pendingEnabled : !requested animated:YES];
    toggle.enabled = staged
        ? ((staged.available && staged.hookable) || staged.pendingEnabled)
        : NO;
    FLEXProvideStagedFeedback(accepted);
    if ([section respondsToSelector:NSSelectorFromString(@"reloadData:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(
            section,
            NSSelectorFromString(@"reloadData:"),
            YES
        );
    }
}

static BOOL FLEXRuntimeActionsSetOverrideState(id object,
                                                SEL selector,
                                                NSNumber *state,
                                                FLEXHookEntry *entry) {
    (void)object;
    (void)selector;
    if (!entry) {
        return NO;
    }
    if (state && (!entry.available || !entry.hookable)) {
        return NO;
    }

    FLEXHookEntry *staged = FLEXStageRuntimeState(
        entry,
        state != nil,
        state
    );
    if (!staged) {
        return NO;
    }
    return state
        ? (staged.pendingEnabled && staged.forceValue == state.boolValue)
        : !staged.pendingEnabled;
}

static NSString *FLEXHookCenterFooter(id object,
                                      SEL selector,
                                      UITableView *tableView,
                                      NSInteger section) {
    if (section == 1) {
        return @"Switches only stage changes. No patch, swizzle or hook is installed until Apply is pressed.";
    }
    return FLEXOriginalHookCenterFooter
        ? FLEXOriginalHookCenterFooter(object, selector, tableView, section)
        : nil;
}

static void FLEXReplaceInstanceMethod(Class cls,
                                      SEL selector,
                                      IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (method) {
        method_setImplementation(method, replacement);
    }
}

static void FLEXInstallDeferredApplyPolicy(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLEXReplaceInstanceMethod(
            FLEXHookToggles.class,
            NSSelectorFromString(@"hookToggleChanged:"),
            (IMP)FLEXHookCenterToggleChanged
        );
        FLEXReplaceInstanceMethod(
            FLEXRuntimeBrowserController.class,
            NSSelectorFromString(@"toggleChanged:"),
            (IMP)FLEXRuntimeBrowserToggleChanged
        );
        FLEXReplaceInstanceMethod(
            FLEXHookEntryDetailController.class,
            NSSelectorFromString(@"enabledChanged:"),
            (IMP)FLEXDetailEnabledChanged
        );
        FLEXReplaceInstanceMethod(
            FLEXHookEntryDetailController.class,
            NSSelectorFromString(@"forceChanged:"),
            (IMP)FLEXDetailForceChanged
        );

        Class metadataToggleClass = NSClassFromString(
            @"FLEXRuntimeHookToggleTarget"
        );
        FLEXReplaceInstanceMethod(
            metadataToggleClass,
            NSSelectorFromString(@"switchChanged:"),
            (IMP)FLEXMetadataRuntimeToggleChanged
        );

        Class actionsMetaClass = object_getClass(FLEXRuntimeHookActions.class);
        FLEXReplaceInstanceMethod(
            actionsMetaClass,
            NSSelectorFromString(@"setOverrideState:forEntry:"),
            (IMP)FLEXRuntimeActionsSetOverrideState
        );

        Method footer = class_getInstanceMethod(
            FLEXHookToggles.class,
            @selector(tableView:titleForFooterInSection:)
        );
        if (footer) {
            FLEXOriginalHookCenterFooter = (FLEXFooterIMP)
                method_getImplementation(footer);
            method_setImplementation(footer, (IMP)FLEXHookCenterFooter);
        }
    });
}

__attribute__((constructor))
static void FLEXDeferredApplyPolicyBootstrap(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        FLEXInstallDeferredApplyPolicy();
    });
}
