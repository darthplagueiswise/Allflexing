#import "FLEXHookableObjCSearchController.h"

#import "FLEXObjCHookResolver.h"
#import "FLEXRuntimeHostIdentity.h"
#import "FLEXRuntimeClient.h"
#import "FLEXSearchToken.h"
#import "FLEXMethod.h"

#import <objc/runtime.h>

static NSString *const kFLEXHookableObjCCell = @"AllFLEXingHookableObjCClassCell";

#pragma mark - Semantic normalization (shared with the browser)

/// Splits identifiers on case and non-alphanumeric boundaries and lowercases
/// the result, so "FBConfigManager", "fb_config_manager" and "fb config manager"
/// all normalize to "fb config manager". No wildcards, no operators.
static NSString *FLEXHookableNormalize(NSString *input) {
    if (input.length == 0) {
        return @"";
    }
    NSCharacterSet *upper = NSCharacterSet.uppercaseLetterCharacterSet;
    NSCharacterSet *lower = NSCharacterSet.lowercaseLetterCharacterSet;
    NSCharacterSet *digit = NSCharacterSet.decimalDigitCharacterSet;
    NSMutableString *out = [NSMutableString string];

    for (NSUInteger i = 0; i < input.length; i++) {
        unichar c = [input characterAtIndex:i];
        BOOL isUpper = [upper characterIsMember:c];
        BOOL isLower = [lower characterIsMember:c];
        BOOL isDigit = [digit characterIsMember:c];
        if (!isUpper && !isLower && !isDigit) {
            if (out.length && ![out hasSuffix:@" "]) {
                [out appendString:@" "];
            }
            continue;
        }
        if (isUpper && i > 0) {
            unichar prev = [input characterAtIndex:i - 1];
            BOOL prevLower = [lower characterIsMember:prev];
            BOOL prevDigit = [digit characterIsMember:prev];
            BOOL nextLower = (i + 1 < input.length) &&
                [lower characterIsMember:[input characterAtIndex:i + 1]];
            BOOL prevUpper = [upper characterIsMember:prev];
            if ((prevLower || prevDigit || (prevUpper && nextLower)) &&
                out.length && ![out hasSuffix:@" "]) {
                [out appendString:@" "];
            }
        }
        unichar lowered = [[[NSString stringWithCharacters:&c length:1]
            lowercaseString] characterAtIndex:0];
        [out appendString:[NSString stringWithCharacters:&lowered length:1]];
    }

    NSArray<NSString *> *parts = [out componentsSeparatedByCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *keep = [NSMutableArray array];
    for (NSString *p in parts) {
        if (p.length) {
            [keep addObject:p];
        }
    }
    return [keep componentsJoinedByString:@" "];
}

static NSString *FLEXHookableCompact(NSString *input) {
    return [FLEXHookableNormalize(input)
        stringByReplacingOccurrencesOfString:@" " withString:@""];
}

static NSArray<NSString *> *FLEXHookableTerms(NSString *query) {
    NSString *normalized = FLEXHookableNormalize(query);
    if (normalized.length == 0) {
        return @[];
    }
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    for (NSString *t in [normalized componentsSeparatedByString:@" "]) {
        if (t.length) {
            [set addObject:t];
        }
    }
    return set.array;
}

#pragma mark - Discovered class model

@interface FLEXHookableClassIndexEntry : NSObject
@property (nonatomic, copy) NSString *className;
@property (nonatomic, copy) NSString *imageShortName;
/// A precomputed normalized haystack (class + methods + image) for matching.
@property (nonatomic, copy) NSString *normalizedHaystack;
@property (nonatomic, copy) NSString *compactHaystack;
/// A short "-foo -bar +baz" preview of the hookable selectors.
@property (nonatomic, copy) NSString *methodPreview;
@property (nonatomic) NSUInteger hookableCount;
@end

@implementation FLEXHookableClassIndexEntry
@end

#pragma mark - Controller

@interface FLEXHookableObjCSearchController ()
@property (nonatomic, weak) id<FLEXHookableObjCSearchControllerDelegate> delegate;
@property (nonatomic) dispatch_queue_t indexQueue;
@property (nonatomic) BOOL indexed;
@property (nonatomic) BOOL indexing;
@property (nonatomic) NSUInteger searchGeneration;
/// Full index of hookable classes, built once.
@property (nonatomic, copy) NSArray<FLEXHookableClassIndexEntry *> *allClasses;
/// The classes currently displayed (filtered by the query).
@property (nonatomic, copy) NSArray<FLEXHookableClassIndexEntry *> *visibleClasses;
@end

@implementation FLEXHookableObjCSearchController

+ (instancetype)delegate:(id<FLEXHookableObjCSearchControllerDelegate>)delegate {
    FLEXHookableObjCSearchController *controller = [self new];
    controller->_delegate = delegate;
    controller->_indexQueue = dispatch_queue_create(
        "com.allflexing.hookable-objc-search", DISPATCH_QUEUE_SERIAL);
    controller->_allClasses = @[];
    controller->_visibleClasses = @[];

    NSParameterAssert(delegate.tableView);
    NSParameterAssert(delegate.searchController);
    delegate.tableView.dataSource = controller;
    delegate.tableView.delegate = controller;
    [delegate.tableView registerClass:UITableViewCell.class
               forCellReuseIdentifier:kFLEXHookableObjCCell];
    delegate.searchController.searchResultsUpdater = controller;
    return controller;
}

- (void)loadIfNeeded {
    if (self.indexed || self.indexing) {
        return;
    }
    self.indexing = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.indexQueue, ^{
        @autoreleasepool {
            NSArray<FLEXHookableClassIndexEntry *> *index = [weakSelf buildIndex];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) {
                    return;
                }
                self.allClasses = index;
                self.indexed = YES;
                self.indexing = NO;
                [self applyQuery:self.delegate.searchController.searchBar.text];
            });
        }
    });
}

/// One-time discovery. Reuses FLEXRuntimeClient's cached enumeration; the only
/// AllFLEXing addition is filtering to classes that expose a hookable method.
- (NSArray<FLEXHookableClassIndexEntry *> *)buildIndex {
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

    NSMutableArray<FLEXHookableClassIndexEntry *> *index = [NSMutableArray array];
    NSUInteger count = MIN(classes.count, methodLists.count);
    for (NSUInteger i = 0; i < count; i++) {
        @autoreleasepool {
            NSString *className = classes[i];
            NSMutableArray<NSString *> *hookableSelectors = [NSMutableArray array];
            for (FLEXMethod *method in methodLists[i]) {
                if ([FLEXObjCHookResolver canRepresentMethod:method
                                                inClassNamed:className]) {
                    NSString *prefix = method.isInstanceMethod ? @"-" : @"+";
                    [hookableSelectors addObject:
                        [prefix stringByAppendingString:method.selectorString]];
                }
            }
            if (hookableSelectors.count == 0) {
                continue;
            }

            Class cls = NSClassFromString(className);
            const char *rawImage = cls ? class_getImageName(cls) : NULL;
            NSString *image = rawImage
                ? [NSString stringWithUTF8String:rawImage].lastPathComponent
                : @"";

            NSString *methodsJoined = [hookableSelectors componentsJoinedByString:@" "];
            NSString *haystackSource = [NSString stringWithFormat:@"%@ %@ %@",
                className, methodsJoined, image];

            FLEXHookableClassIndexEntry *entry = [FLEXHookableClassIndexEntry new];
            entry.className = className;
            entry.imageShortName = image;
            entry.hookableCount = hookableSelectors.count;
            entry.normalizedHaystack = FLEXHookableNormalize(haystackSource);
            entry.compactHaystack = FLEXHookableCompact(haystackSource);

            NSMutableString *preview = [NSMutableString string];
            for (NSUInteger m = 0; m < hookableSelectors.count && m < 3; m++) {
                if (preview.length) {
                    [preview appendString:@"\n"];
                }
                [preview appendString:hookableSelectors[m]];
            }
            if (hookableSelectors.count > 3) {
                [preview appendString:@"\n..."];
            }
            entry.methodPreview = preview;

            [index addObject:entry];
        }
    }

    [index sortUsingComparator:^NSComparisonResult(FLEXHookableClassIndexEntry *a,
                                                    FLEXHookableClassIndexEntry *b) {
        return [a.className localizedCaseInsensitiveCompare:b.className];
    }];
    return index;
}

#pragma mark - Filtering

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    if (!self.indexed) {
        [self loadIfNeeded];
        return;
    }
    [self applyQuery:searchController.searchBar.text];
}

/// Filters off the main thread (the index can be large) and reloads on main.
- (void)applyQuery:(NSString *)query {
    NSArray<NSString *> *terms = FLEXHookableTerms(query);
    NSArray<FLEXHookableClassIndexEntry *> *source = self.allClasses;
    NSUInteger generation = ++self.searchGeneration;

    if (terms.count == 0) {
        self.visibleClasses = source;
        [self.delegate.tableView reloadData];
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(self.indexQueue, ^{
        NSMutableArray<NSString *> *compactTerms =
            [NSMutableArray arrayWithCapacity:terms.count];
        for (NSString *t in terms) {
            [compactTerms addObject:FLEXHookableCompact(t)];
        }

        NSMutableArray<FLEXHookableClassIndexEntry *> *matches = [NSMutableArray array];
        for (FLEXHookableClassIndexEntry *entry in source) {
            BOOL all = YES;
            for (NSUInteger i = 0; i < terms.count; i++) {
                NSString *term = terms[i];
                NSString *compact = compactTerms[i];
                BOOL hit =
                    [entry.normalizedHaystack rangeOfString:term].location != NSNotFound ||
                    (compact.length &&
                     [entry.compactHaystack rangeOfString:compact].location != NSNotFound);
                if (!hit) {
                    all = NO;
                    break;
                }
            }
            if (all) {
                [matches addObject:entry];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || generation != self.searchGeneration) {
                return;
            }
            self.visibleClasses = matches.copy;
            [self.delegate.tableView reloadData];
        });
    });
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.visibleClasses.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView
        dequeueReusableCellWithIdentifier:kFLEXHookableObjCCell
                             forIndexPath:indexPath];
    if (indexPath.row >= (NSInteger)self.visibleClasses.count) {
        return cell;
    }
    FLEXHookableClassIndexEntry *entry = self.visibleClasses[indexPath.row];

    UIListContentConfiguration *content =
        [UIListContentConfiguration subtitleCellConfiguration];
    content.text = entry.className;
    content.secondaryText = entry.methodPreview;
    content.secondaryTextProperties.numberOfLines = 0;
    content.secondaryTextProperties.font =
        [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    content.textProperties.font =
        [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    cell.contentConfiguration = content;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView
titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if (!self.indexed) {
        return @"Resolving hookable classes...";
    }
    NSUInteger n = self.visibleClasses.count;
    return [NSString stringWithFormat:@"%lu hookable class%@",
        (unsigned long)n, n == 1 ? @"" : @"es"];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.visibleClasses.count) {
        return;
    }
    Class cls = NSClassFromString(self.visibleClasses[indexPath.row].className);
    if (cls) {
        [self.delegate hookableSearchDidSelectClass:cls];
    }
}

@end
