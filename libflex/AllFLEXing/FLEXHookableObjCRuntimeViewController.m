#import "FLEXHookableObjCRuntimeViewController.h"

#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXLiquidGlass.h"
#import "FLEXMethod.h"
#import "FLEXObjCHookResolver.h"
#import "FLEXPersistenceStore.h"
#import "FLEXRuntimeClient.h"
#import "FLEXRuntimeHostIdentity.h"
#import "FLEXRuntimeScanner.h"
#import "FLEXSearchToken.h"

#import <objc/runtime.h>
#import <stdlib.h>

static const void *kFLEXObjCBrowserEntryIDKey = &kFLEXObjCBrowserEntryIDKey;

static NSString *FLEXObjCStringValue(NSDictionary<NSString *, id> *dictionary,
                                     NSString *key) {
    id value = dictionary[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static NSString *FLEXObjCEntryClassName(FLEXHookEntry *entry) {
    return FLEXObjCStringValue(entry.locator, @"class");
}

static NSString *FLEXObjCEntrySelector(FLEXHookEntry *entry) {
    return FLEXObjCStringValue(entry.locator, @"selector");
}

static NSString *FLEXObjCEntryEncoding(FLEXHookEntry *entry) {
    return FLEXObjCStringValue(entry.locator, @"encoding");
}

static NSString *FLEXObjCEntryImagePath(FLEXHookEntry *entry) {
    return FLEXObjCStringValue(entry.locator, @"image");
}

static BOOL FLEXObjCEntryIsClassMethod(FLEXHookEntry *entry) {
    id value = entry.locator[@"classMethod"];
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static NSString *FLEXObjCSemanticNormalizedText(NSString *input) {
    if (input.length == 0) {
        return @"";
    }

    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSCharacterSet *uppercase = NSCharacterSet.uppercaseLetterCharacterSet;
    NSCharacterSet *lowercase = NSCharacterSet.lowercaseLetterCharacterSet;
    NSMutableString *result = [NSMutableString stringWithCapacity:input.length + 8];

    for (NSUInteger index = 0; index < input.length; index++) {
        unichar character = [input characterAtIndex:index];
        BOOL isLetter = [letters characterIsMember:character];
        BOOL isDigit = [digits characterIsMember:character];
        if (!isLetter && !isDigit) {
            if (result.length && ![result hasSuffix:@" "]) {
                [result appendString:@" "];
            }
            continue;
        }

        BOOL boundary = NO;
        if (index > 0 && [uppercase characterIsMember:character]) {
            unichar previous = [input characterAtIndex:index - 1];
            BOOL previousLower = [lowercase characterIsMember:previous];
            BOOL previousDigit = [digits characterIsMember:previous];
            BOOL previousUpper = [uppercase characterIsMember:previous];
            BOOL nextLower = index + 1 < input.length &&
                [lowercase characterIsMember:[input characterAtIndex:index + 1]];
            boundary = previousLower || previousDigit || (previousUpper && nextLower);
        }
        if (boundary && result.length && ![result hasSuffix:@" "]) {
            [result appendString:@" "];
        }

        NSString *piece = [NSString stringWithCharacters:&character length:1];
        [result appendString:piece.lowercaseString];
    }

    NSArray<NSString *> *parts = [result componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *nonempty = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts) {
        if (part.length) {
            [nonempty addObject:part];
        }
    }
    return [nonempty componentsJoinedByString:@" "];
}

static NSString *FLEXObjCSemanticCompactText(NSString *input) {
    return [FLEXObjCSemanticNormalizedText(input)
        stringByReplacingOccurrencesOfString:@" " withString:@""];
}

static NSArray<NSString *> *FLEXObjCSemanticQueryTerms(NSString *query) {
    NSString *normalized = FLEXObjCSemanticNormalizedText(query);
    if (normalized.length == 0) {
        return @[];
    }

    NSMutableOrderedSet<NSString *> *terms = [NSMutableOrderedSet orderedSet];
    for (NSString *term in [normalized componentsSeparatedByString:@" "]) {
        if (term.length) {
            [terms addObject:term];
        }
    }
    return terms.array;
}

@interface FLEXObjCHookRow : NSObject
@property (nonatomic) FLEXHookEntry *entry;
@property (nonatomic, copy) NSString *className;
@property (nonatomic, copy) NSString *selectorName;
@property (nonatomic, copy) NSString *encoding;
@property (nonatomic, copy) NSString *imagePath;
@property (nonatomic, copy) NSString *imageName;
@property (nonatomic) BOOL classMethod;
@property (nonatomic, copy) NSArray<NSString *> *normalizedSearchFields;
@property (nonatomic, copy) NSArray<NSString *> *compactSearchFields;
@end

@implementation FLEXObjCHookRow
@end

@interface FLEXObjCHookGroup : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *className;
@property (nonatomic, copy) NSString *imageName;
@property (nonatomic, copy) NSArray<FLEXObjCHookRow *> *rows;
@end

@implementation FLEXObjCHookGroup
@end

static NSArray<NSString *> *FLEXObjCBuildSearchFields(FLEXHookEntry *entry,
                                                       NSString *className,
                                                       NSString *selectorName,
                                                       NSString *encoding,
                                                       NSString *imageName,
                                                       BOOL classMethod) {
    return @[
        entry.title ?: @"",
        entry.detail ?: @"",
        className ?: @"",
        selectorName ?: @"",
        encoding ?: @"",
        imageName ?: @"",
        FLEXHookABIName(entry.abi),
        FLEXHookBackendName(entry.backend),
        classMethod ? @"class method +" : @"instance method -",
    ];
}

static FLEXObjCHookRow *FLEXObjCRowForEntry(FLEXHookEntry *entry) {
    if (!entry || !entry.available || !entry.hookable ||
        entry.abi == FLEXHookABIUnknown || entry.identifier.length == 0) {
        return nil;
    }

    FLEXObjCHookRow *row = [FLEXObjCHookRow new];
    row.entry = entry;
    row.className = FLEXObjCEntryClassName(entry);
    row.selectorName = FLEXObjCEntrySelector(entry);
    row.encoding = FLEXObjCEntryEncoding(entry);
    row.imagePath = FLEXObjCEntryImagePath(entry);
    row.imageName = entry.imageName.length
        ? entry.imageName
        : (row.imagePath.lastPathComponent ?: @"Unknown image");
    row.classMethod = FLEXObjCEntryIsClassMethod(entry);

    NSArray<NSString *> *fields = FLEXObjCBuildSearchFields(
        entry,
        row.className,
        row.selectorName,
        row.encoding,
        row.imageName,
        row.classMethod
    );
    NSMutableArray<NSString *> *normalized =
        [NSMutableArray arrayWithCapacity:fields.count];
    NSMutableArray<NSString *> *compact =
        [NSMutableArray arrayWithCapacity:fields.count];
    for (NSString *field in fields) {
        [normalized addObject:FLEXObjCSemanticNormalizedText(field)];
        [compact addObject:FLEXObjCSemanticCompactText(field)];
    }
    row.normalizedSearchFields = normalized.copy;
    row.compactSearchFields = compact.copy;
    return row;
}

static BOOL FLEXObjCRowMatchesTerms(FLEXObjCHookRow *row,
                                    NSArray<NSString *> *terms) {
    if (terms.count == 0) {
        return YES;
    }

    for (NSString *term in terms) {
        NSString *compactTerm = FLEXObjCSemanticCompactText(term);
        BOOL matched = NO;
        NSUInteger fieldCount = MIN(row.normalizedSearchFields.count,
                                    row.compactSearchFields.count);
        for (NSUInteger index = 0; index < fieldCount; index++) {
            if ([row.normalizedSearchFields[index] rangeOfString:term].location != NSNotFound ||
                (compactTerm.length &&
                 [row.compactSearchFields[index] rangeOfString:compactTerm].location != NSNotFound)) {
                matched = YES;
                break;
            }
        }
        if (!matched) {
            return NO;
        }
    }
    return YES;
}

static NSComparisonResult FLEXCompareObjCRows(FLEXObjCHookRow *left,
                                               FLEXObjCHookRow *right) {
    NSComparisonResult imageResult = [left.imageName
        localizedCaseInsensitiveCompare:right.imageName];
    if (imageResult != NSOrderedSame) {
        return imageResult;
    }
    NSComparisonResult classResult = [left.className
        localizedCaseInsensitiveCompare:right.className];
    if (classResult != NSOrderedSame) {
        return classResult;
    }
    if (left.classMethod != right.classMethod) {
        return left.classMethod ? NSOrderedDescending : NSOrderedAscending;
    }
    return [left.selectorName localizedCaseInsensitiveCompare:right.selectorName];
}

@interface FLEXHookableObjCRuntimeViewController () <UISearchResultsUpdating>
@property (nonatomic) dispatch_queue_t discoveryQueue;
@property (nonatomic) dispatch_queue_t filterQueue;
@property (nonatomic) BOOL scanning;
@property (nonatomic) NSUInteger discoveryGeneration;
@property (nonatomic) NSUInteger filterGeneration;
@property (nonatomic) NSUInteger imageReloadGeneration;
@property (nonatomic) UISearchController *searchController;
@property (nonatomic) UIBarButtonItem *applyItem;
@property (nonatomic) UIBarButtonItem *moreItem;
@property (nonatomic, copy) NSArray<FLEXObjCHookRow *> *allRows;
@property (nonatomic, copy) NSArray<FLEXObjCHookGroup *> *visibleGroups;
@end

@implementation FLEXHookableObjCRuntimeViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _discoveryQueue = dispatch_queue_create(
            "com.allflexing.flex-objc-eligible-discovery",
            DISPATCH_QUEUE_SERIAL
        );
        _filterQueue = dispatch_queue_create(
            "com.allflexing.flex-objc-search-index",
            DISPATCH_QUEUE_SERIAL
        );
        _allRows = @[];
        _visibleGroups = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Objective-C Functions";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 54.0;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"Class, selector, ABI or image";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.applyItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Apply"
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(applyPending)];
    if (@available(iOS 26.0, *)) {
        self.applyItem.style = UIBarButtonItemStyleProminent;
    }

    self.moreItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
                 menu:[UIMenu menuWithChildren:@[]]];
    self.moreItem.accessibilityLabel = @"Objective-C function actions";
    self.navigationItem.rightBarButtonItems = @[self.applyItem, self.moreItem];

    [self setContentScrollView:self.tableView
                      forEdge:(NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom)];
    [FLEXRuntimeClient initializeWebKitLegacy];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryChanged:)
               name:FLEXHookRegistryDidChangeNotification
             object:nil];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(runtimeImagesChanged:)
               name:FLEXRuntimeImagesDidChangeNotification
             object:nil];

    [self updateNavigationActions];
    [self reloadEligibleMethods];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBar.prefersLargeTitles = NO;
    [self.tableView reloadData];
    [self updateNavigationActions];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Runtime discovery

- (void)runtimeImagesChanged:(NSNotification *)notification {
    (void)notification;
    if (!self.viewIfLoaded.window) {
        return;
    }

    NSUInteger generation = ++self.imageReloadGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.imageReloadGeneration || self.scanning) {
            return;
        }
        [self reloadEligibleMethods];
    });
}

- (void)reloadEligibleMethods {
    if (self.scanning) {
        return;
    }

    self.scanning = YES;
    NSUInteger generation = ++self.discoveryGeneration;
    [self updateNavigationActions];
    [self updateUnavailableConfiguration];

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.discoveryQueue, ^{
        @autoreleasepool {
            FLEXRuntimeClient *runtime = FLEXRuntimeClient.runtime;
            [runtime reloadLibrariesList];

            NSMutableArray<NSString *> *allowedPaths = [NSMutableArray array];
            for (NSString *shortName in runtime.imageDisplayNames) {
                NSString *path = [runtime imageNameForShortName:shortName];
                if (FLEXRuntimeImageIsAllowedHostImage(path)) {
                    [allowedPaths addObject:path];
                }
            }

            NSMutableArray<NSString *> *classes = [runtime
                classesForToken:FLEXSearchToken.any
                inBundles:allowedPaths];
            NSArray<NSMutableArray<FLEXMethod *> *> *methodLists = [runtime
                methodsForToken:FLEXSearchToken.any
                instance:nil
                inClasses:classes];

            NSMutableDictionary<NSString *, FLEXHookEntry *> *discoveredByIdentifier =
                [NSMutableDictionary dictionary];
            NSUInteger count = MIN(classes.count, methodLists.count);
            for (NSUInteger classIndex = 0; classIndex < count; classIndex++) {
                @autoreleasepool {
                    NSString *className = classes[classIndex];
                    Class targetClass = NSClassFromString(className);
                    if (!targetClass) {
                        continue;
                    }

                    for (FLEXMethod *method in methodLists[classIndex]) {
                        FLEXHookEntry *entry = [FLEXObjCHookResolver
                            entryForMethod:method
                              targetClass:targetClass];
                        if (entry && entry.available && entry.hookable &&
                            entry.abi != FLEXHookABIUnknown &&
                            entry.identifier.length) {
                            discoveredByIdentifier[entry.identifier] = entry;
                        }
                    }
                }
            }

            NSArray<FLEXHookEntry *> *discovered =
                discoveredByIdentifier.allValues.copy;
            FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
            [registry mergeDiscoveredEntries:discovered
                                      surface:FLEXHookSurfaceObjectiveC];

            NSMutableArray<FLEXObjCHookRow *> *rows =
                [NSMutableArray arrayWithCapacity:discovered.count];
            for (FLEXHookEntry *candidate in discovered) {
                FLEXHookEntry *current = [registry entryForIdentifier:candidate.identifier];
                FLEXObjCHookRow *row = FLEXObjCRowForEntry(current);
                if (row) {
                    [rows addObject:row];
                }
            }
            [rows sortUsingComparator:^NSComparisonResult(FLEXObjCHookRow *left,
                                                           FLEXObjCHookRow *right) {
                return FLEXCompareObjCRows(left, right);
            }];

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || generation != self.discoveryGeneration) {
                    return;
                }
                self.allRows = rows.copy;
                self.scanning = NO;
                [self scheduleFilterForQuery:self.searchController.searchBar.text ?: @""
                                    immediate:YES];
                [self updateNavigationActions];
            });
        }
    });
}

#pragma mark - Indexed search and grouping

- (void)scheduleFilterForQuery:(NSString *)query immediate:(BOOL)immediate {
    NSString *queryCopy = query.copy ?: @"";
    NSArray<FLEXObjCHookRow *> *rows = self.allRows.copy;
    NSUInteger generation = ++self.filterGeneration;
    NSTimeInterval delay = immediate ? 0.0 : 0.18;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   self.filterQueue, ^{
        @autoreleasepool {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.filterGeneration) {
                return;
            }

            NSArray<NSString *> *terms = FLEXObjCSemanticQueryTerms(queryCopy);
            NSMutableArray<NSString *> *orderedKeys = [NSMutableArray array];
            NSMutableDictionary<NSString *, NSMutableArray<FLEXObjCHookRow *> *> *groups =
                [NSMutableDictionary dictionary];
            NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *metadata =
                [NSMutableDictionary dictionary];

            for (FLEXObjCHookRow *row in rows) {
                if (!FLEXObjCRowMatchesTerms(row, terms)) {
                    continue;
                }
                NSString *key = [NSString stringWithFormat:@"%@\n%@",
                    row.imagePath ?: @"",
                    row.className ?: @""];
                NSMutableArray<FLEXObjCHookRow *> *bucket = groups[key];
                if (!bucket) {
                    bucket = [NSMutableArray array];
                    groups[key] = bucket;
                    metadata[key] = @{
                        @"class": row.className.length ? row.className : @"Unknown class",
                        @"image": row.imageName.length ? row.imageName : @"Unknown image",
                    };
                    [orderedKeys addObject:key];
                }
                [bucket addObject:row];
            }

            NSMutableArray<FLEXObjCHookGroup *> *result =
                [NSMutableArray arrayWithCapacity:orderedKeys.count];
            for (NSString *key in orderedKeys) {
                FLEXObjCHookGroup *group = [FLEXObjCHookGroup new];
                group.identifier = key;
                group.className = metadata[key][@"class"];
                group.imageName = metadata[key][@"image"];
                group.rows = groups[key].copy;
                [result addObject:group];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || generation != self.filterGeneration) {
                    return;
                }
                self.visibleGroups = result.copy;
                [self.tableView reloadData];
                [self updateNavigationActions];
                [self updateUnavailableConfiguration];
            });
        }
    });
}

- (NSUInteger)visibleEntryCount {
    NSUInteger count = 0;
    for (FLEXObjCHookGroup *group in self.visibleGroups) {
        count += group.rows.count;
    }
    return count;
}

- (FLEXObjCHookRow *)rowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section < 0 ||
        indexPath.section >= (NSInteger)self.visibleGroups.count) {
        return nil;
    }
    FLEXObjCHookGroup *group = self.visibleGroups[(NSUInteger)indexPath.section];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)group.rows.count) {
        return nil;
    }
    return group.rows[(NSUInteger)indexPath.row];
}

#pragma mark - Registry staging and apply

- (void)registryChanged:(NSNotification *)notification {
    (void)notification;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self registryChanged:notification];
        });
        return;
    }
    [self.tableView reloadData];
    [self updateNavigationActions];
}

- (void)toggleChanged:(UISwitch *)toggle {
    NSString *identifier = objc_getAssociatedObject(toggle, kFLEXObjCBrowserEntryIDKey);
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    FLEXHookEntry *entry = [registry entryForIdentifier:identifier];
    BOOL requestedState = toggle.isOn;

    if (!entry || (requestedState && (!entry.available || !entry.hookable))) {
        toggle.on = entry ? entry.pendingEnabled : NO;
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeError];
        return;
    }

    if (requestedState && !entry.userConfigured) {
        [registry stageForceValue:YES forEntryIdentifier:identifier];
    }
    [registry stageEnabled:requestedState forEntryIdentifier:identifier];

    FLEXHookEntry *staged = [registry entryForIdentifier:identifier];
    BOOL accepted = staged && staged.pendingEnabled == requestedState;
    [toggle setOn:staged ? staged.pendingEnabled : NO animated:YES];
    toggle.enabled = staged &&
        (((staged.available && staged.hookable) || staged.pendingEnabled) &&
         !registry.isApplying);

    if (accepted) {
        UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
        [feedback selectionChanged];
    } else {
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeError];
    }
    [self updateNavigationActions];

    // Row switches stage only. The existing Apply control commits the batch;
    // applyEntryIdentifier:identifier is intentionally not called here.
}

- (void)applyPending {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    if (!registry.hasPendingChanges || registry.isApplying) {
        return;
    }

    [self updateNavigationActions];
    __weak typeof(self) weakSelf = self;
    [registry applyPendingWithCompletion:^(NSArray<FLEXHookEntry *> *applied,
                                           NSArray<FLEXHookEntry *> *failed) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        [self presentApplyResultApplied:applied failed:failed restartAfter:NO];
    }];
}

- (void)applyAndCloseApp {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    if (registry.isApplying) {
        return;
    }
    if (!registry.hasPendingChanges) {
        [self confirmCloseAfterSuccessfulApply];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [registry applyPendingWithCompletion:^(NSArray<FLEXHookEntry *> *applied,
                                           NSArray<FLEXHookEntry *> *failed) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        [self presentApplyResultApplied:applied failed:failed restartAfter:YES];
    }];
}

- (void)presentApplyResultApplied:(NSArray<FLEXHookEntry *> *)applied
                           failed:(NSArray<FLEXHookEntry *> *)failed
                     restartAfter:(BOOL)restartAfter {
    [self.tableView reloadData];
    [self updateNavigationActions];

    if (failed.count) {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (FLEXHookEntry *entry in failed) {
            [lines addObject:[NSString stringWithFormat:@"%@ — %@",
                entry.title ?: entry.identifier,
                entry.lastError ?: @"Unknown apply error"]];
            if (lines.count == 6) {
                break;
            }
        }
        NSString *message = [lines componentsJoinedByString:@"\n\n"];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Apply failed"
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeError];
        return;
    }

    BOOL enabledWasApplied = NO;
    for (FLEXHookEntry *entry in applied) {
        if (entry.desiredEnabled) {
            enabledWasApplied = YES;
            break;
        }
    }
    if (enabledWasApplied && !FLEXHookRegistry.hasPersistedConfirmedEntries) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Persistence failed"
                             message:@"The hook was installed in this process, but its Apply-confirmed state was not readable from the host-scoped store. The app was not closed."
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
    [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    if (restartAfter) {
        [self confirmCloseAfterSuccessfulApply];
    }
}

- (void)confirmCloseAfterSuccessfulApply {
    BOOL synchronized = [FLEXPersistenceStore.sharedStore synchronizeNow];
    if (!synchronized) {
        NSString *message = FLEXPersistenceStore.sharedStore.lastError.length
            ? FLEXPersistenceStore.sharedStore.lastError
            : @"The host-scoped persistence store could not be synchronized.";
        UIAlertController *error = [UIAlertController
            alertControllerWithTitle:@"Could not save before closing"
                             message:message
                      preferredStyle:UIAlertControllerStyleAlert];
        [error addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:error animated:YES completion:nil];
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Apply & Close"
                         message:@"The confirmed hooks were synchronized. The app will close; open it again manually so launch re-arm can run."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close App"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [NSUserDefaults.standardUserDefaults synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            exit(0);
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)discardPendingChanges {
    [FLEXHookRegistry.sharedRegistry discardPendingChanges];
    [self.tableView reloadData];
    [self updateNavigationActions];
}

- (void)updateNavigationActions {
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL applying = registry.isApplying;
    BOOL hasPending = registry.hasPendingChanges;
    self.applyItem.enabled = hasPending && !applying;
    self.applyItem.title = applying ? @"Applying…" : @"Apply";

    __weak typeof(self) weakSelf = self;
    UIAction *reload = [UIAction
        actionWithTitle:@"Reload eligible methods"
                  image:[UIImage systemImageNamed:@"arrow.clockwise"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        [weakSelf reloadEligibleMethods];
    }];
    if (self.scanning || applying) {
        reload.attributes = UIMenuElementAttributesDisabled;
    }

    UIAction *discard = [UIAction
        actionWithTitle:@"Discard pending changes"
                  image:[UIImage systemImageNamed:@"arrow.uturn.backward"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        [weakSelf discardPendingChanges];
    }];
    if (!hasPending || applying) {
        discard.attributes = UIMenuElementAttributesDisabled;
    }

    UIAction *restart = [UIAction
        actionWithTitle:@"Apply and close app"
                  image:[UIImage systemImageNamed:@"arrow.clockwise.circle"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        [weakSelf applyAndCloseApp];
    }];
    if (applying) {
        restart.attributes = UIMenuElementAttributesDisabled;
    }

    self.moreItem.menu = [UIMenu menuWithTitle:@"Objective-C functions"
                                     children:@[reload, discard, restart]];

    if (@available(iOS 26.0, *)) {
        self.navigationItem.subtitle = self.scanning
            ? @"Resolving eligible methods…"
            : [NSString stringWithFormat:@"%lu methods · %lu classes · %lu pending",
                (unsigned long)self.visibleEntryCount,
                (unsigned long)self.visibleGroups.count,
                (unsigned long)registry.pendingCount];
    }
}

- (void)updateUnavailableConfiguration {
    if (@available(iOS 17.0, *)) {
        if (self.visibleEntryCount) {
            self.contentUnavailableConfiguration = nil;
            return;
        }
        UIContentUnavailableConfiguration *configuration = self.scanning
            ? [UIContentUnavailableConfiguration loadingConfiguration]
            : (self.searchController.searchBar.text.length
                ? [UIContentUnavailableConfiguration searchConfiguration]
                : [UIContentUnavailableConfiguration emptyConfiguration]);
        configuration.text = self.scanning
            ? @"Resolving Objective-C functions"
            : @"No hookable Objective-C methods";
        configuration.secondaryText = self.scanning
            ? @"Discovery and ABI validation run away from the main thread."
            : @"Only methods accepted by the active Objective-C hook engine are shown.";
        self.contentUnavailableConfiguration = configuration;
    }
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self scheduleFilterForQuery:searchController.searchBar.text ?: @""
                        immediate:NO];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.visibleGroups.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section < 0 || section >= (NSInteger)self.visibleGroups.count) {
        return 0;
    }
    return self.visibleGroups[(NSUInteger)section].rows.count;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.visibleGroups.count) {
        return nil;
    }

    static NSString *identifier = @"AllFLEXingObjCClassHeader";
    UITableViewHeaderFooterView *header =
        [tableView dequeueReusableHeaderFooterViewWithIdentifier:identifier];
    if (!header) {
        header = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:identifier];
    }

    FLEXObjCHookGroup *group = self.visibleGroups[(NSUInteger)section];
    UIListContentConfiguration *content = [UIListContentConfiguration groupedHeaderConfiguration];
    content.text = group.className;
    content.textProperties.font = [UIFont systemFontOfSize:12.0
                                                   weight:UIFontWeightSemibold];
    content.secondaryText = [NSString stringWithFormat:@"%@ · %lu method%@",
        group.imageName,
        (unsigned long)group.rows.count,
        group.rows.count == 1 ? @"" : @"s"];
    content.secondaryTextProperties.font = [UIFont systemFontOfSize:10.0];
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    header.contentConfiguration = content;
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"AllFLEXingCompactObjCMethodCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    FLEXObjCHookRow *row = [self rowAtIndexPath:indexPath];
    if (!row) {
        return cell;
    }
    FLEXHookEntry *entry = [FLEXHookRegistry.sharedRegistry
        entryForIdentifier:row.entry.identifier] ?: row.entry;
    row.entry = entry;

    NSString *prefix = row.classMethod ? @"+" : @"-";
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = [NSString stringWithFormat:@"%@ %@", prefix, row.selectorName];
    content.textProperties.font = [UIFont systemFontOfSize:13.0
                                                   weight:UIFontWeightMedium];
    content.secondaryText = [NSString stringWithFormat:@"ABI resolved: %@ · %@\n%@",
        FLEXHookABIName(entry.abi),
        row.encoding.length ? row.encoding : @"No encoding",
        entry.statusSummary];
    content.secondaryTextProperties.numberOfLines = 2;
    content.secondaryTextProperties.font = [UIFont systemFontOfSize:10.5];
    content.image = [UIImage systemImageNamed:row.classMethod ? @"c.square" : @"m.square"];
    content.imageProperties.preferredSymbolConfiguration =
        [UIImageSymbolConfiguration configurationWithPointSize:13.0
                                                        weight:UIImageSymbolWeightRegular];
    content.imageProperties.tintColor = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0 ? UIColor.systemGreenColor : UIColor.systemBlueColor)
        : self.view.tintColor;
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryNone;

    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (((entry.available && entry.hookable) || entry.pendingEnabled) &&
                      !FLEXHookRegistry.sharedRegistry.isApplying);
    [toggle sizeToFit];
    toggle.accessibilityLabel = [NSString stringWithFormat:@"Runtime hook for %@ %@",
        prefix, row.selectorName];
    toggle.accessibilityValue = entry.statusSummary;
    objc_setAssociatedObject(toggle,
                             kFLEXObjCBrowserEntryIDKey,
                             entry.identifier,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    [toggle addTarget:self
               action:@selector(toggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    [FLEXLiquidGlass styleTableCell:cell];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FLEXObjCHookRow *row = [self rowAtIndexPath:indexPath];
    FLEXHookEntry *entry = row
        ? [FLEXHookRegistry.sharedRegistry entryForIdentifier:row.entry.identifier]
        : nil;
    if (!entry) {
        return;
    }

    FLEXHookEntryDetailController *detail =
        [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
    [self.navigationController pushViewController:detail animated:YES];
}

@end
