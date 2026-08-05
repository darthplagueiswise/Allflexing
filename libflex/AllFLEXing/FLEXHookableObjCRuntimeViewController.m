#import "FLEXHookableObjCRuntimeViewController.h"

#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXLiquidGlass.h"
#import "FLEXMethod.h"
#import "FLEXObjCHookResolver.h"
#import "FLEXRuntimeClient.h"
#import "FLEXRuntimeHostIdentity.h"
#import "FLEXRuntimeScanner.h"
#import "FLEXSearchToken.h"

#import <objc/runtime.h>

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
    NSMutableString *result = [NSMutableString string];

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

        BOOL isUpper = [uppercase characterIsMember:character];
        BOOL boundary = NO;
        if (index > 0 && isUpper) {
            unichar previous = [input characterAtIndex:index - 1];
            BOOL previousLower = [lowercase characterIsMember:previous];
            BOOL previousDigit = [digits characterIsMember:previous];
            BOOL previousUpper = [uppercase characterIsMember:previous];
            BOOL nextLower = NO;
            if (index + 1 < input.length) {
                nextLower = [lowercase characterIsMember:
                    [input characterAtIndex:index + 1]];
            }
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
    NSMutableArray<NSString *> *nonempty = [NSMutableArray array];
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

static BOOL FLEXObjCEntryMatchesTerms(FLEXHookEntry *entry,
                                      NSArray<NSString *> *terms) {
    if (terms.count == 0) {
        return YES;
    }

    NSArray<NSString *> *fields = @[
        entry.title ?: @"",
        entry.detail ?: @"",
        entry.imageName ?: @"",
        FLEXObjCEntryClassName(entry),
        FLEXObjCEntrySelector(entry),
        FLEXObjCEntryEncoding(entry),
        FLEXHookABIName(entry.abi),
        FLEXHookBackendName(entry.backend),
        entry.statusSummary ?: @"",
        entry.lastError ?: @"",
        FLEXObjCEntryIsClassMethod(entry) ? @"class method +" : @"instance method -",
    ];

    NSMutableArray<NSString *> *normalizedFields =
        [NSMutableArray arrayWithCapacity:fields.count];
    NSMutableArray<NSString *> *compactFields =
        [NSMutableArray arrayWithCapacity:fields.count];
    for (NSString *field in fields) {
        [normalizedFields addObject:FLEXObjCSemanticNormalizedText(field)];
        [compactFields addObject:FLEXObjCSemanticCompactText(field)];
    }

    for (NSString *term in terms) {
        NSString *compactTerm = FLEXObjCSemanticCompactText(term);
        BOOL matched = NO;
        for (NSUInteger index = 0; index < normalizedFields.count; index++) {
            if ([normalizedFields[index] rangeOfString:term].location != NSNotFound ||
                (compactTerm.length &&
                 [compactFields[index] rangeOfString:compactTerm].location != NSNotFound)) {
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

static NSComparisonResult FLEXCompareObjCEntries(FLEXHookEntry *left,
                                                  FLEXHookEntry *right) {
    NSComparisonResult classResult = [FLEXObjCEntryClassName(left)
        localizedCaseInsensitiveCompare:FLEXObjCEntryClassName(right)];
    if (classResult != NSOrderedSame) {
        return classResult;
    }
    BOOL leftClassMethod = FLEXObjCEntryIsClassMethod(left);
    BOOL rightClassMethod = FLEXObjCEntryIsClassMethod(right);
    if (leftClassMethod != rightClassMethod) {
        return leftClassMethod ? NSOrderedDescending : NSOrderedAscending;
    }
    return [FLEXObjCEntrySelector(left)
        localizedCaseInsensitiveCompare:FLEXObjCEntrySelector(right)];
}

@interface FLEXHookableObjCRuntimeViewController () <UISearchResultsUpdating>
@property (nonatomic) dispatch_queue_t discoveryQueue;
@property (nonatomic) BOOL scanning;
@property (nonatomic) NSUInteger discoveryGeneration;
@property (nonatomic) UISearchController *searchController;
@property (nonatomic) UIBarButtonItem *reloadItem;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *catalogEntries;
@property (nonatomic, copy) NSArray<NSString *> *sectionKeys;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<FLEXHookEntry *> *> *entriesBySection;
@end

@implementation FLEXHookableObjCRuntimeViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _discoveryQueue = dispatch_queue_create(
            "com.allflexing.flex-objc-eligible-discovery",
            DISPATCH_QUEUE_SERIAL
        );
        _catalogEntries = @[];
        _sectionKeys = @[];
        _entriesBySection = @{};
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Objective-C Functions";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 82.0;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"Class, selector, ABI or image";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.reloadItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(reloadEligibleMethods)];
    self.navigationItem.rightBarButtonItem = self.reloadItem;

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

    [self reloadEligibleMethods];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshCatalogStateFromRegistry];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)registryChanged:(NSNotification *)notification {
    (void)notification;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshCatalogStateFromRegistry];
        });
        return;
    }
    [self refreshCatalogStateFromRegistry];
}

- (void)runtimeImagesChanged:(NSNotification *)notification {
    (void)notification;
    if (self.viewIfLoaded.window && !self.scanning) {
        [self reloadEligibleMethods];
    }
}

- (void)reloadEligibleMethods {
    if (self.scanning) {
        return;
    }

    self.scanning = YES;
    self.reloadItem.enabled = NO;
    NSUInteger generation = ++self.discoveryGeneration;
    [self updateNavigationStatus];
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

            NSMutableDictionary<NSString *, FLEXHookEntry *> *entriesByIdentifier =
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
                        if (entry && entry.abi != FLEXHookABIUnknown &&
                            entry.identifier.length) {
                            entriesByIdentifier[entry.identifier] = entry;
                        }
                    }
                }
            }

            NSArray<FLEXHookEntry *> *discovered = [entriesByIdentifier.allValues
                sortedArrayUsingComparator:^NSComparisonResult(FLEXHookEntry *left,
                                                                FLEXHookEntry *right) {
                    NSComparisonResult imageResult = [FLEXObjCEntryImagePath(left)
                        localizedCaseInsensitiveCompare:FLEXObjCEntryImagePath(right)];
                    return imageResult == NSOrderedSame
                        ? FLEXCompareObjCEntries(left, right)
                        : imageResult;
                }];

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || generation != self.discoveryGeneration) {
                    return;
                }

                FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
                [registry mergeDiscoveredEntries:discovered
                                          surface:FLEXHookSurfaceObjectiveC];

                NSMutableArray<FLEXHookEntry *> *resolved =
                    [NSMutableArray arrayWithCapacity:discovered.count];
                for (FLEXHookEntry *entry in discovered) {
                    FLEXHookEntry *current = [registry entryForIdentifier:entry.identifier];
                    if (current) {
                        [resolved addObject:current];
                    }
                }

                self.catalogEntries = resolved.copy;
                self.scanning = NO;
                self.reloadItem.enabled = YES;
                [self rebuildSections];
            });
        }
    });
}

- (void)refreshCatalogStateFromRegistry {
    if (self.catalogEntries.count == 0) {
        [self rebuildSections];
        return;
    }

    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    NSMutableArray<FLEXHookEntry *> *updated =
        [NSMutableArray arrayWithCapacity:self.catalogEntries.count];
    for (FLEXHookEntry *entry in self.catalogEntries) {
        FLEXHookEntry *current = [registry entryForIdentifier:entry.identifier];
        if (current) {
            [updated addObject:current];
        }
    }
    self.catalogEntries = updated.copy;
    [self rebuildSections];
}

- (void)rebuildSections {
    NSArray<NSString *> *terms = FLEXObjCSemanticQueryTerms(
        self.searchController.searchBar.text ?: @""
    );
    NSMutableDictionary<NSString *, NSMutableArray<FLEXHookEntry *> *> *groups =
        [NSMutableDictionary dictionary];

    for (FLEXHookEntry *entry in self.catalogEntries) {
        if (!FLEXObjCEntryMatchesTerms(entry, terms)) {
            continue;
        }
        NSString *imagePath = FLEXObjCEntryImagePath(entry);
        NSString *sectionKey = imagePath.length
            ? imagePath
            : (entry.imageName.length ? entry.imageName : @"Unknown image");
        NSMutableArray<FLEXHookEntry *> *group = groups[sectionKey];
        if (!group) {
            group = [NSMutableArray array];
            groups[sectionKey] = group;
        }
        [group addObject:entry];
    }

    NSMutableDictionary<NSString *, NSArray<FLEXHookEntry *> *> *immutableGroups =
        [NSMutableDictionary dictionaryWithCapacity:groups.count];
    for (NSString *key in groups) {
        immutableGroups[key] = [groups[key]
            sortedArrayUsingComparator:^NSComparisonResult(FLEXHookEntry *left,
                                                            FLEXHookEntry *right) {
                return FLEXCompareObjCEntries(left, right);
            }];
    }

    self.sectionKeys = [groups.allKeys sortedArrayUsingComparator:^NSComparisonResult(
        NSString *left, NSString *right
    ) {
        NSComparisonResult shortResult = [left.lastPathComponent
            localizedCaseInsensitiveCompare:right.lastPathComponent];
        return shortResult == NSOrderedSame
            ? [left localizedCaseInsensitiveCompare:right]
            : shortResult;
    }];
    self.entriesBySection = immutableGroups.copy;
    [self.tableView reloadData];
    [self updateNavigationStatus];
    [self updateUnavailableConfiguration];
}

- (FLEXHookEntry *)entryAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section < 0 ||
        indexPath.section >= (NSInteger)self.sectionKeys.count) {
        return nil;
    }
    NSString *key = self.sectionKeys[(NSUInteger)indexPath.section];
    NSArray<FLEXHookEntry *> *entries = self.entriesBySection[key] ?: @[];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)entries.count) {
        return nil;
    }
    return entries[(NSUInteger)indexPath.row];
}

- (NSUInteger)visibleEntryCount {
    NSUInteger count = 0;
    for (NSString *key in self.sectionKeys) {
        count += self.entriesBySection[key].count;
    }
    return count;
}

- (void)updateNavigationStatus {
    NSString *status = self.scanning
        ? @"Resolving eligible methods and Objective-C ABIs…"
        : [NSString stringWithFormat:@"%lu eligible method%@ · ABI resolved",
            (unsigned long)self.visibleEntryCount,
            self.visibleEntryCount == 1 ? @"" : @"s"];
    if (@available(iOS 26.0, *)) {
        self.navigationItem.subtitle = status;
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
            : @"No eligible Objective-C functions";
        configuration.secondaryText = self.scanning
            ? @"FLEX supplies runtime metadata while AllFLEXing validates each method and resolves its supported ABI."
            : @"Only methods with a structurally valid encoding and a supported resolved ABI are listed.";
        self.contentUnavailableConfiguration = configuration;
    }
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    (void)searchController;
    [self rebuildSections];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.sectionKeys.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section < 0 || section >= (NSInteger)self.sectionKeys.count) {
        return 0;
    }
    return self.entriesBySection[self.sectionKeys[(NSUInteger)section]].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section < 0 || section >= (NSInteger)self.sectionKeys.count) {
        return nil;
    }
    NSString *key = self.sectionKeys[(NSUInteger)section];
    NSString *name = key.lastPathComponent;
    return name.length ? name : key;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section != (NSInteger)self.sectionKeys.count - 1) {
        return nil;
    }
    return @"Objective-C ABIs are derived from the real method encoding and are read-only. Manual ABI selection belongs to C Symbol Patcher.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"AllFLEXingEligibleObjCMethodCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }

    FLEXHookEntry *entry = [self entryAtIndexPath:indexPath];
    if (!entry) {
        return cell;
    }

    NSString *className = FLEXObjCEntryClassName(entry);
    NSString *selector = FLEXObjCEntrySelector(entry);
    NSString *encoding = FLEXObjCEntryEncoding(entry);
    NSString *prefix = FLEXObjCEntryIsClassMethod(entry) ? @"+" : @"-";
    NSString *displayName = [NSString stringWithFormat:@"%@[%@ %@]",
        prefix,
        className.length ? className : @"UnknownClass",
        selector.length ? selector : @"unknownSelector"];

    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    content.text = displayName;
    content.textProperties.font = [UIFont systemFontOfSize:14.0
                                                   weight:UIFontWeightSemibold];
    content.secondaryText = [NSString stringWithFormat:
        @"ABI resolved: %@\n%@ · %@\n%@",
        FLEXHookABIName(entry.abi),
        encoding.length ? encoding : @"No encoding",
        FLEXHookBackendName(entry.backend),
        entry.statusSummary];
    content.secondaryTextProperties.numberOfLines = 0;
    content.secondaryTextProperties.font = [UIFont systemFontOfSize:11.5];
    content.image = [UIImage systemImageNamed:FLEXObjCEntryIsClassMethod(entry)
        ? @"c.square"
        : @"m.square"];
    content.imageProperties.tintColor = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0 ? UIColor.systemGreenColor : UIColor.systemBlueColor)
        : (entry.hookable ? self.view.tintColor : UIColor.secondaryLabelColor);
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryNone;

    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = ((entry.available && entry.hookable) || entry.pendingEnabled) &&
                     !FLEXHookRegistry.sharedRegistry.isApplying;
    [toggle sizeToFit];
    toggle.accessibilityLabel = [NSString stringWithFormat:
        @"Objective-C runtime hook for %@", displayName];
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
    FLEXHookEntry *entry = [self entryAtIndexPath:indexPath];
    if (!entry) {
        return;
    }
    FLEXHookEntryDetailController *detail =
        [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
    [self.navigationController pushViewController:detail animated:YES];
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

    toggle.enabled = NO;
    if (requestedState && !entry.userConfigured) {
        [registry stageForceValue:YES forEntryIdentifier:identifier];
    }
    [registry stageEnabled:requestedState forEntryIdentifier:identifier];

    FLEXHookEntry *staged = [registry entryForIdentifier:identifier];
    if (!staged || staged.pendingEnabled != requestedState) {
        toggle.on = staged ? staged.pendingEnabled : NO;
        toggle.enabled = YES;
        UINotificationFeedbackGenerator *feedback = [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeError];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [registry applyEntryIdentifier:identifier
                        completion:^(NSArray<FLEXHookEntry *> *applied,
                                     NSArray<FLEXHookEntry *> *failed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) {
                return;
            }

            BOOL didFail = NO;
            for (FLEXHookEntry *failedEntry in failed) {
                if ([failedEntry.identifier isEqualToString:identifier]) {
                    didFail = YES;
                    break;
                }
            }

            FLEXHookEntry *current = [registry entryForIdentifier:identifier];
            if (didFail || !current) {
                UINotificationFeedbackGenerator *feedback =
                    [UINotificationFeedbackGenerator new];
                [feedback notificationOccurred:UINotificationFeedbackTypeError];
            } else if (!requestedState) {
                UISelectionFeedbackGenerator *feedback =
                    [UISelectionFeedbackGenerator new];
                [feedback selectionChanged];
            } else {
                UINotificationFeedbackGenerator *feedback =
                    [UINotificationFeedbackGenerator new];
                [feedback notificationOccurred:current.overrideHitCount > 0
                    ? UINotificationFeedbackTypeSuccess
                    : UINotificationFeedbackTypeWarning];
            }

            (void)applied;
            [self refreshCatalogStateFromRegistry];
        });
    }];
}

@end
