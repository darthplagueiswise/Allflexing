#import "FLEXHookableObjectExplorerViewController.h"

#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXLiquidGlass.h"
#import "FLEXObjCHookResolver.h"

#import "FLEXObjectExplorer.h"
#import "FLEXObjectExplorerFactory.h"
#import "FLEXMetadataSection.h"
#import "FLEXMutableListSection.h"
#import "FLEXTableView.h"
#import "FLEXMethod.h"

#import <objc/runtime.h>

static const void *kFLEXHookableExplorerEntryIDKey = &kFLEXHookableExplorerEntryIDKey;

@implementation FLEXHookableObjectExplorerViewController

+ (instancetype)exploringHookableClass:(Class)cls {
    // Build on FLEX's own explorer for the class; the custom section is added in
    // makeSections so it can see the resolved metadata.
    return [self exploringObject:cls customSections:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [FLEXLiquidGlass applyToViewController:self];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryChanged:)
               name:FLEXHookRegistryDidChangeNotification
             object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)registryChanged:(NSNotification *)notification {
    (void)notification;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
        });
        return;
    }
    [self.tableView reloadData];
}

- (Class)hookableTargetClass {
    id object = self.object;
    if (object_isClass(object)) {
        return (Class)object;
    }
    return object_getClass(object);
}

/// The class's instance + class methods that resolve to a concrete ABI.
- (NSArray<FLEXMethod *> *)hookableMethodsForClass:(Class)targetClass {
    NSString *className = NSStringFromClass(targetClass);
    NSMutableArray<FLEXMethod *> *result = [NSMutableArray array];
    for (FLEXMethod *method in self.explorer.methods) {
        if ([FLEXObjCHookResolver canRepresentMethod:method inClassNamed:className]) {
            [result addObject:method];
        }
    }
    for (FLEXMethod *method in self.explorer.classMethods) {
        if ([FLEXObjCHookResolver canRepresentMethod:method inClassNamed:className]) {
            [result addObject:method];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(FLEXMethod *a, FLEXMethod *b) {
        if (a.isInstanceMethod != b.isInstanceMethod) {
            return a.isInstanceMethod ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.selectorString localizedCaseInsensitiveCompare:b.selectorString];
    }];
    return result;
}

/// Names of the methods that are NOT hookable, so FLEX's own method sections
/// hide them. Excluding structurally inconsistent methods here is also what
/// keeps FLEX from decoding their arguments and raising a range exception.
- (NSSet<NSString *> *)excludedMethodNamesForClass:(Class)targetClass
                                          instance:(BOOL)instance {
    NSString *className = NSStringFromClass(targetClass);
    NSArray<FLEXMethod *> *source = instance
        ? self.explorer.methods
        : self.explorer.classMethods;
    NSMutableSet<NSString *> *excluded = [NSMutableSet set];
    for (FLEXMethod *method in source) {
        if (![FLEXObjCHookResolver canRepresentMethod:method inClassNamed:className]) {
            NSString *name = method.selectorString;
            if (name.length) {
                [excluded addObject:name];
            }
        }
    }
    return excluded;
}

- (FLEXMetadataSection *)filteredMethodSectionOfKind:(FLEXMetadataKind)kind
                                            instance:(BOOL)instance
                                         targetClass:(Class)targetClass {
    FLEXMetadataSection *section = [FLEXMetadataSection explorer:self.explorer
                                                            kind:kind];
    section.excludedMetadata = [self excludedMethodNamesForClass:targetClass
                                                        instance:instance];
    return section;
}

- (void)toggleHookForMethod:(FLEXMethod *)method
                targetClass:(Class)targetClass
                     enable:(BOOL)enable
                     toggle:(UISwitch *)toggle {
    FLEXHookEntry *entry = [FLEXObjCHookResolver entryForMethod:method
                                                   targetClass:targetClass];
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    if (entry) {
        [registry mergeDiscoveredEntries:@[entry]
                                 surface:FLEXHookSurfaceObjectiveC];
    }
    FLEXHookEntry *tracked = entry
        ? [registry entryForIdentifier:entry.identifier]
        : nil;

    if (!tracked || (enable && (!tracked.available || !tracked.hookable))) {
        toggle.on = tracked ? tracked.pendingEnabled : NO;
        UINotificationFeedbackGenerator *feedback =
            [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeError];
        return;
    }

    toggle.enabled = NO;
    if (enable && !tracked.userConfigured) {
        [registry stageForceValue:YES forEntryIdentifier:tracked.identifier];
    }
    [registry stageEnabled:enable forEntryIdentifier:tracked.identifier];

    NSString *identifier = tracked.identifier;
    [registry applyEntryIdentifier:identifier
                        completion:^(NSArray<FLEXHookEntry *> *applied,
                                     NSArray<FLEXHookEntry *> *failed) {
        (void)applied;
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL didFail = NO;
            for (FLEXHookEntry *failedEntry in failed) {
                if ([failedEntry.identifier isEqualToString:identifier]) {
                    didFail = YES;
                    break;
                }
            }
            FLEXHookEntry *current = [registry entryForIdentifier:identifier];
            UINotificationFeedbackGenerator *feedback =
                [UINotificationFeedbackGenerator new];
            [feedback notificationOccurred:(didFail || !current)
                ? UINotificationFeedbackTypeError
                : UINotificationFeedbackTypeSuccess];
            toggle.enabled = YES;
            toggle.on = current ? current.pendingEnabled : NO;
        });
    }];
}

- (FLEXMutableListSection *)hookableMethodsSectionForClass:(Class)targetClass {
    NSArray<FLEXMethod *> *methods = [self hookableMethodsForClass:targetClass];
    __weak typeof(self) weakSelf = self;

    FLEXMutableListSection *section = [FLEXMutableListSection
        list:methods
        cellConfiguration:^(__kindof UITableViewCell *cell,
                            FLEXMethod *method, NSInteger row) {
            (void)row;
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) {
                return;
            }

            FLEXHookEntry *entry = [FLEXObjCHookResolver entryForMethod:method
                                                           targetClass:targetClass];
            FLEXHookEntry *tracked = entry
                ? [FLEXHookRegistry.sharedRegistry entryForIdentifier:entry.identifier]
                : nil;
            FLEXHookEntry *display = tracked ?: entry;

            NSString *prefix = method.isInstanceMethod ? @"-" : @"+";
            UIListContentConfiguration *content =
                [UIListContentConfiguration subtitleCellConfiguration];
            content.text = [NSString stringWithFormat:@"%@%@",
                prefix, method.selectorString];
            content.textProperties.font =
                [UIFont monospacedSystemFontOfSize:13.0 weight:UIFontWeightSemibold];
            content.secondaryText = display
                ? [NSString stringWithFormat:@"ABI: %@\n%@",
                    FLEXHookABIName(display.abi), display.statusSummary]
                : @"ABI: resolving";
            content.secondaryTextProperties.numberOfLines = 0;
            content.secondaryTextProperties.font = [UIFont systemFontOfSize:11.0];
            cell.contentConfiguration = content;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType = UITableViewCellAccessoryDetailButton;

            UISwitch *toggle = [UISwitch new];
            toggle.on = display ? display.pendingEnabled : NO;
            toggle.enabled = display
                ? (((display.available && display.hookable) || display.pendingEnabled) &&
                   !FLEXHookRegistry.sharedRegistry.isApplying)
                : NO;
            [toggle sizeToFit];
            objc_setAssociatedObject(toggle, kFLEXHookableExplorerEntryIDKey,
                method, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [toggle addTarget:self
                       action:@selector(sectionToggleChanged:)
             forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            [FLEXLiquidGlass styleTableCell:cell];
        }
        filterMatcher:^BOOL(NSString *filterText, FLEXMethod *method) {
            return [method.selectorString
                rangeOfString:filterText
                      options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];

    section.customTitle = methods.count
        ? [NSString stringWithFormat:@"Hookable methods (%lu)",
            (unsigned long)methods.count]
        : @"Hookable methods";

    section.selectionHandler = ^(__kindof UIViewController *host, FLEXMethod *method) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        FLEXHookEntry *entry = [FLEXObjCHookResolver entryForMethod:method
                                                       targetClass:targetClass];
        if (!entry) {
            return;
        }
        [FLEXHookRegistry.sharedRegistry mergeDiscoveredEntries:@[entry]
                                                        surface:FLEXHookSurfaceObjectiveC];
        FLEXHookEntry *tracked =
            [FLEXHookRegistry.sharedRegistry entryForIdentifier:entry.identifier] ?: entry;
        FLEXHookEntryDetailController *detail =
            [[FLEXHookEntryDetailController alloc] initWithEntry:tracked];
        [host.navigationController pushViewController:detail animated:YES];
    };

    return section;
}

- (void)sectionToggleChanged:(UISwitch *)toggle {
    FLEXMethod *method = objc_getAssociatedObject(toggle,
        kFLEXHookableExplorerEntryIDKey);
    if (!method) {
        return;
    }
    [self toggleHookForMethod:method
                  targetClass:[self hookableTargetClass]
                       enable:toggle.isOn
                       toggle:toggle];
}

- (NSArray<FLEXTableViewSection *> *)makeSections {
    Class targetClass = [self hookableTargetClass];
    if (!targetClass) {
        return [super makeSections];
    }

    // Our hookable-methods section on top, then FLEX's standard sections with
    // the non-hookable methods excluded. Everything else FLEX renders (ivars,
    // properties, protocols, hierarchy) is preserved untouched.
    NSMutableArray<FLEXTableViewSection *> *sections = [NSMutableArray array];
    [sections addObject:[self hookableMethodsSectionForClass:targetClass]];
    [sections addObject:[self filteredMethodSectionOfKind:FLEXMetadataKindMethods
                                                 instance:YES
                                              targetClass:targetClass]];
    [sections addObject:[self filteredMethodSectionOfKind:FLEXMetadataKindClassMethods
                                                 instance:NO
                                              targetClass:targetClass]];
    return sections;
}

@end
