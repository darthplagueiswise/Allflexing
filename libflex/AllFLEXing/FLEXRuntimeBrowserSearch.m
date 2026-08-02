#import "FLEXRuntimeBrowserController.h"

#import "FLEXHookRegistry.h"
#import "FLEXRuntimeScanner.h"

#import <objc/runtime.h>

const char *FLEXRuntimeSearchABIVersion =
    "AllFLEXing selected-image complete-snapshot prefix-index search ABI 5";

static const void *kFLEXRuntimeSearchScopeKey = &kFLEXRuntimeSearchScopeKey;
static const void *kFLEXRuntimeSearchIndexKey = &kFLEXRuntimeSearchIndexKey;
static const void *kFLEXRuntimeSearchRequestKey = &kFLEXRuntimeSearchRequestKey;
static const void *kFLEXRuntimeScanRequestKey = &kFLEXRuntimeScanRequestKey;

typedef NS_ENUM(NSInteger, FLEXRuntimeSearchScopeKind) {
    FLEXRuntimeSearchScopeMainExecutable = 0,
    FLEXRuntimeSearchScopeExactImage,
    FLEXRuntimeSearchScopeHostImages,
    FLEXRuntimeSearchScopeAllLoadedImages,
};

@interface FLEXRuntimeSearchScope : NSObject
@property (nonatomic) FLEXRuntimeSearchScopeKind kind;
@property (nonatomic, copy) NSString *imagePath;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *cacheKey;
@end
@implementation FLEXRuntimeSearchScope
@end

@interface FLEXRuntimeSearchRequest : NSObject
@property (atomic) BOOL cancelled;
@end
@implementation FLEXRuntimeSearchRequest
@end

@interface FLEXRuntimeSearchRecord : NSObject
@property (nonatomic) FLEXHookEntry *entry;
@property (nonatomic, copy) NSArray<NSString *> *tokens;
@end
@implementation FLEXRuntimeSearchRecord
@end

@interface FLEXRuntimeSearchIndex : NSObject
@property (nonatomic, copy) NSString *scopeKey;
@property (nonatomic) FLEXRuntimeBrowserKind kind;
@property (nonatomic, copy) NSArray<FLEXRuntimeSearchRecord *> *records;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *allEntries;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *prefixMap;
@end
@implementation FLEXRuntimeSearchIndex
@end

static dispatch_queue_t FLEXRuntimeSearchQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_USER_INITIATED,
            0
        );
        queue = dispatch_queue_create(
            "com.allflexing.runtime-search.selected-image",
            attributes
        );
    });
    return queue;
}

static void FLEXExchangeInstanceMethods(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

static NSString *FLEXSearchNormalizedText(NSString *source) {
    if (!source.length) {
        return @"";
    }

    NSMutableString *spaced = [NSMutableString stringWithCapacity:source.length + 8];
    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSCharacterSet *upper = NSCharacterSet.uppercaseLetterCharacterSet;
    NSCharacterSet *lower = NSCharacterSet.lowercaseLetterCharacterSet;

    for (NSUInteger index = 0; index < source.length; index++) {
        unichar current = [source characterAtIndex:index];
        BOOL alphanumeric = [letters characterIsMember:current] ||
                            [digits characterIsMember:current];
        if (!alphanumeric) {
            if (spaced.length && [spaced characterAtIndex:spaced.length - 1] != ' ') {
                [spaced appendString:@" "];
            }
            continue;
        }

        if ([upper characterIsMember:current] && index > 0 && spaced.length &&
            [spaced characterAtIndex:spaced.length - 1] != ' ') {
            unichar previous = [source characterAtIndex:index - 1];
            BOOL boundary = [lower characterIsMember:previous] ||
                            [digits characterIsMember:previous];
            if (!boundary && index + 1 < source.length) {
                unichar next = [source characterAtIndex:index + 1];
                boundary = [upper characterIsMember:previous] &&
                           [lower characterIsMember:next];
            }
            if (boundary) {
                [spaced appendString:@" "];
            }
        }
        [spaced appendFormat:@"%C", current];
    }

    NSString *folded = [spaced stringByFoldingWithOptions:
        (NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch |
         NSWidthInsensitiveSearch)
        locale:NSLocale.currentLocale];
    NSArray<NSString *> *parts = [folded.lowercaseString
        componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts) {
        if (part.length) {
            [tokens addObject:part];
        }
    }
    return [tokens componentsJoinedByString:@" "];
}

static NSArray<NSString *> *FLEXSearchTokens(NSString *source) {
    NSString *normalized = FLEXSearchNormalizedText(source);
    return normalized.length
        ? [normalized componentsSeparatedByString:@" "] : @[];
}

static void FLEXAppendSearchField(NSMutableString *raw, id value) {
    if ([value isKindOfClass:NSString.class] && [value length]) {
        [raw appendString:value];
        [raw appendString:@" "];
    } else if ([value isKindOfClass:NSNumber.class]) {
        [raw appendString:[value stringValue]];
        [raw appendString:@" "];
    }
}

static FLEXRuntimeSearchScope *FLEXDefaultRuntimeScope(void) {
    FLEXRuntimeSearchScope *scope = [FLEXRuntimeSearchScope new];
    scope.kind = FLEXRuntimeSearchScopeMainExecutable;
    scope.imagePath = NSBundle.mainBundle.executablePath ?: @"";
    scope.title = @"Main executable";
    scope.cacheKey = [@"main|" stringByAppendingString:scope.imagePath];
    return scope;
}

static FLEXRuntimeSearchScope *FLEXScopeForController(id controller) {
    FLEXRuntimeSearchScope *scope = objc_getAssociatedObject(
        controller,
        kFLEXRuntimeSearchScopeKey
    );
    if (!scope) {
        scope = FLEXDefaultRuntimeScope();
        objc_setAssociatedObject(
            controller,
            kFLEXRuntimeSearchScopeKey,
            scope,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
    return scope;
}

static NSArray<NSString *> *FLEXPathsForScope(FLEXRuntimeSearchScope *scope) {
    switch (scope.kind) {
        case FLEXRuntimeSearchScopeMainExecutable:
        case FLEXRuntimeSearchScopeExactImage:
            return scope.imagePath.length ? @[scope.imagePath] : @[];
        case FLEXRuntimeSearchScopeHostImages:
            return [FLEXRuntimeScanner
                loadedImagePathsIncludingSystemImages:NO];
        case FLEXRuntimeSearchScopeAllLoadedImages:
            return [FLEXRuntimeScanner
                loadedImagePathsIncludingSystemImages:YES];
    }
}

static FLEXRuntimeSearchIndex *FLEXBuildSearchIndex(
    NSArray<FLEXHookEntry *> *entries,
    FLEXRuntimeBrowserKind kind,
    NSString *scopeKey,
    FLEXRuntimeSearchRequest *request
) {
    NSArray<FLEXHookEntry *> *sorted = [entries sortedArrayUsingComparator:^NSComparisonResult(
        FLEXHookEntry *left,
        FLEXHookEntry *right
    ) {
        NSComparisonResult imageResult =
            [left.imageName localizedCaseInsensitiveCompare:right.imageName];
        if (imageResult != NSOrderedSame) {
            return imageResult;
        }
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];

    NSMutableArray<FLEXRuntimeSearchRecord *> *records =
        [NSMutableArray arrayWithCapacity:sorted.count];
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *mutablePrefixMap =
        [NSMutableDictionary dictionary];
    NSArray<NSString *> *locatorKeys = @[
        @"symbol", @"class", @"selector", @"encoding",
        @"image", @"imageUUID", @"backendEvidence", @"abiEvidence"
    ];

    NSUInteger recordIndex = 0;
    for (FLEXHookEntry *entry in sorted) {
        if ((recordIndex & 127) == 0 && request.cancelled) {
            return nil;
        }
        @autoreleasepool {
            NSMutableString *raw = [NSMutableString string];
            FLEXAppendSearchField(raw, entry.title);
            FLEXAppendSearchField(raw, entry.identifier);
            FLEXAppendSearchField(raw, entry.detail);
            FLEXAppendSearchField(raw, entry.imageName);
            if ([entry.locator isKindOfClass:NSDictionary.class]) {
                for (NSString *key in locatorKeys) {
                    FLEXAppendSearchField(raw, entry.locator[key]);
                }
            }

            NSArray<NSString *> *tokens = FLEXSearchTokens(raw);
            FLEXRuntimeSearchRecord *record = [FLEXRuntimeSearchRecord new];
            record.entry = entry;
            record.tokens = tokens;
            [records addObject:record];

            NSSet<NSString *> *uniqueTokens = [NSSet setWithArray:tokens];
            for (NSString *token in uniqueTokens) {
                NSUInteger maximumPrefix = MIN((NSUInteger)32, token.length);
                for (NSUInteger length = 1; length <= maximumPrefix; length++) {
                    NSString *prefix = [token substringToIndex:length];
                    NSMutableIndexSet *indexes = mutablePrefixMap[prefix];
                    if (!indexes) {
                        indexes = [NSMutableIndexSet indexSet];
                        mutablePrefixMap[prefix] = indexes;
                    }
                    [indexes addIndex:recordIndex];
                }
                if (token.length > maximumPrefix) {
                    NSMutableIndexSet *indexes = mutablePrefixMap[token];
                    if (!indexes) {
                        indexes = [NSMutableIndexSet indexSet];
                        mutablePrefixMap[token] = indexes;
                    }
                    [indexes addIndex:recordIndex];
                }
            }
        }
        recordIndex++;
    }

    if (request.cancelled) {
        return nil;
    }
    NSMutableDictionary<NSString *, NSIndexSet *> *prefixMap =
        [NSMutableDictionary dictionaryWithCapacity:mutablePrefixMap.count];
    [mutablePrefixMap enumerateKeysAndObjectsUsingBlock:^(
        NSString *key,
        NSMutableIndexSet *indexes,
        BOOL *stop
    ) {
        (void)stop;
        prefixMap[key] = indexes.copy;
    }];

    FLEXRuntimeSearchIndex *index = [FLEXRuntimeSearchIndex new];
    index.scopeKey = scopeKey;
    index.kind = kind;
    index.records = records.copy;
    index.allEntries = sorted;
    index.prefixMap = prefixMap.copy;
    return index;
}

static NSArray<FLEXHookEntry *> *FLEXSearchIndex(
    FLEXRuntimeSearchIndex *index,
    NSString *query,
    FLEXRuntimeSearchRequest *request
) {
    NSArray<NSString *> *tokens = FLEXSearchTokens(query);
    if (!tokens.count) {
        return index.allEntries;
    }

    NSMutableIndexSet *candidates = nil;
    for (NSString *token in tokens) {
        if (request.cancelled) {
            return nil;
        }
        NSIndexSet *tokenIndexes = index.prefixMap[token];
        if (!tokenIndexes.count) {
            return @[];
        }
        if (!candidates) {
            candidates = tokenIndexes.mutableCopy;
        } else {
            [candidates intersectIndexes:tokenIndexes];
        }
        if (!candidates.count) {
            return @[];
        }
    }

    NSMutableArray<FLEXHookEntry *> *results =
        [NSMutableArray arrayWithCapacity:candidates.count];
    [candidates enumerateIndexesUsingBlock:^(NSUInteger recordIndex,
                                              BOOL *stop) {
        if (request.cancelled) {
            *stop = YES;
            return;
        }
        if (recordIndex < index.records.count) {
            [results addObject:index.records[recordIndex].entry];
        }
    }];
    return request.cancelled ? nil : results.copy;
}

static void FLEXSetRuntimeLoading(UIViewController *controller,
                                  UISearchController *search,
                                  BOOL loading,
                                  NSString *title,
                                  NSString *detail) {
    search.searchBar.userInteractionEnabled = !loading;
    if (@available(iOS 17.0, *)) {
        if (loading) {
            UIContentUnavailableConfiguration *configuration =
                [UIContentUnavailableConfiguration loadingConfiguration];
            configuration.text = title ?: @"Scanning selected image";
            configuration.secondaryText = detail ?: @"Reading runtime metadata.";
            controller.contentUnavailableConfiguration = configuration;
        } else {
            controller.contentUnavailableConfiguration = nil;
        }
    }
}

static void FLEXRemoveManualSymbolButton(FLEXRuntimeBrowserController *controller) {
    NSMutableArray<UIBarButtonItem *> *items =
        [controller.navigationItem.rightBarButtonItems mutableCopy];
    if (!items.count) {
        return;
    }
    NSIndexSet *manualIndexes = [items indexesOfObjectsPassingTest:^BOOL(
        UIBarButtonItem *item,
        NSUInteger index,
        BOOL *stop
    ) {
        (void)index;
        (void)stop;
        return item.action == NSSelectorFromString(@"addManualSymbol:");
    }];
    if (manualIndexes.count) {
        [items removeObjectsAtIndexes:manualIndexes];
        controller.navigationItem.rightBarButtonItems = items;
    }
}

@interface FLEXRuntimeBrowserController (AllFLEXingSearchPrivate)
- (void)reloadEntries;
- (void)reloadScan;
- (UIMenu *)scopeMenu;
- (void)updateNavigationStatus;
- (void)updateUnavailableConfiguration;
@end

@implementation FLEXRuntimeBrowserController (AllFLEXingSelectedImageSearch)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FLEXRuntimeBrowserController.class;
        FLEXExchangeInstanceMethods(cls,
            @selector(viewDidLoad),
            @selector(af_image_viewDidLoad));
        FLEXExchangeInstanceMethods(cls,
            @selector(reloadEntries),
            @selector(af_image_reloadEntries));
        FLEXExchangeInstanceMethods(cls,
            @selector(reloadScan),
            @selector(af_image_reloadScan));
        FLEXExchangeInstanceMethods(cls,
            @selector(scopeMenu),
            @selector(af_image_scopeMenu));
        FLEXExchangeInstanceMethods(cls,
            @selector(tableView:cellForRowAtIndexPath:),
            @selector(af_image_tableView:cellForRowAtIndexPath:));
    });
}

- (void)af_image_viewDidLoad {
    FLEXRuntimeSearchScope *scope = FLEXScopeForController(self);
    [self af_image_viewDidLoad];
    FLEXRemoveManualSymbolButton(self);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76.0;

    @try {
        UIBarButtonItem *scopeItem = [self valueForKey:@"scopeItem"];
        scopeItem.title = scope.title;
        scopeItem.menu = [self af_image_scopeMenu];
    } @catch (__unused NSException *exception) {
    }
}

- (void)af_image_reloadScan {
    FLEXRuntimeSearchRequest *oldSearch = objc_getAssociatedObject(
        self,
        kFLEXRuntimeSearchRequestKey
    );
    oldSearch.cancelled = YES;
    FLEXRuntimeSearchRequest *oldScan = objc_getAssociatedObject(
        self,
        kFLEXRuntimeScanRequestKey
    );
    oldScan.cancelled = YES;

    FLEXRuntimeSearchRequest *scanRequest = [FLEXRuntimeSearchRequest new];
    objc_setAssociatedObject(
        self,
        kFLEXRuntimeScanRequestKey,
        scanRequest,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
    objc_setAssociatedObject(
        self,
        kFLEXRuntimeSearchIndexKey,
        nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    FLEXRuntimeBrowserKind kind = FLEXRuntimeBrowserKindObjectiveC;
    UISearchController *search = nil;
    UIBarButtonItem *reloadItem = nil;
    UIBarButtonItem *scopeItem = nil;
    @try {
        kind = [[self valueForKey:@"kind"] integerValue];
        search = [self valueForKey:@"searchController"];
        reloadItem = [self valueForKey:@"reloadItem"];
        scopeItem = [self valueForKey:@"scopeItem"];
        [self setValue:@YES forKey:@"scanning"];
        [self setValue:@[] forKey:@"filteredEntries"];
    } @catch (__unused NSException *exception) {
        [self af_image_reloadScan];
        return;
    }

    FLEXRuntimeSearchScope *scope = FLEXScopeForController(self);
    NSArray<NSString *> *imagePaths = FLEXPathsForScope(scope);
    reloadItem.enabled = NO;
    scopeItem.enabled = NO;
    [self.tableView reloadData];
    [self updateNavigationStatus];
    FLEXSetRuntimeLoading(
        self,
        search,
        YES,
        @"Scanning selected runtime image",
        [NSString stringWithFormat:@"%@ · reading complete metadata before search",
            scope.title]
    );

    __weak typeof(self) weakSelf = self;
    FLEXRuntimeScanProgress progress = ^(
        NSString *stage,
        NSString *imagePath,
        NSUInteger completed,
        NSUInteger total
    ) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || scanRequest.cancelled ||
            objc_getAssociatedObject(self, kFLEXRuntimeScanRequestKey) != scanRequest) {
            return;
        }
        NSString *image = imagePath.lastPathComponent ?: scope.title;
        NSString *detail = total
            ? [NSString stringWithFormat:@"%@ · %lu/%lu images",
                image,
                (unsigned long)MIN(completed + 1, total),
                (unsigned long)total]
            : image;
        FLEXSetRuntimeLoading(self, search, YES, stage, detail);
        if (@available(iOS 26.0, *)) {
            self.navigationItem.subtitle = [NSString stringWithFormat:@"%@ · %@",
                stage,
                image];
        }
    };

    FLEXRuntimeScanCompletion completion = ^(NSArray<FLEXHookEntry *> *entries) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || scanRequest.cancelled ||
            objc_getAssociatedObject(self, kFLEXRuntimeScanRequestKey) != scanRequest) {
            return;
        }

        FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
        NSMutableArray<FLEXHookEntry *> *resolved = [NSMutableArray array];
        if (kind == FLEXRuntimeBrowserKindObjectiveC) {
            [resolved addObjectsFromArray:[registry
                mergeDiscoveredEntries:entries
                               surface:FLEXHookSurfaceObjectiveC
                            imagePaths:imagePaths]];
        } else {
            NSPredicate *importPredicate = [NSPredicate predicateWithBlock:^BOOL(
                FLEXHookEntry *entry,
                NSDictionary *bindings
            ) {
                (void)bindings;
                return entry.surface == FLEXHookSurfaceCImport;
            }];
            NSPredicate *inlinePredicate = [NSPredicate predicateWithBlock:^BOOL(
                FLEXHookEntry *entry,
                NSDictionary *bindings
            ) {
                (void)bindings;
                return entry.surface == FLEXHookSurfaceCInline;
            }];
            [resolved addObjectsFromArray:[registry
                mergeDiscoveredEntries:[entries filteredArrayUsingPredicate:importPredicate]
                               surface:FLEXHookSurfaceCImport
                            imagePaths:imagePaths]];
            [resolved addObjectsFromArray:[registry
                mergeDiscoveredEntries:[entries filteredArrayUsingPredicate:inlinePredicate]
                               surface:FLEXHookSurfaceCInline
                            imagePaths:imagePaths]];
        }

        FLEXRuntimeSearchRequest *indexRequest = [FLEXRuntimeSearchRequest new];
        objc_setAssociatedObject(
            self,
            kFLEXRuntimeSearchRequestKey,
            indexRequest,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
        FLEXSetRuntimeLoading(
            self,
            search,
            YES,
            @"Indexing complete snapshot",
            [NSString stringWithFormat:@"%lu verified target(s) · %@",
                (unsigned long)resolved.count,
                scope.title]
        );

        dispatch_async(FLEXRuntimeSearchQueue(), ^{
            FLEXRuntimeSearchIndex *index = FLEXBuildSearchIndex(
                resolved.copy,
                kind,
                scope.cacheKey,
                indexRequest
            );
            if (!index || indexRequest.cancelled) {
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || scanRequest.cancelled || indexRequest.cancelled ||
                    objc_getAssociatedObject(self, kFLEXRuntimeScanRequestKey) != scanRequest) {
                    return;
                }
                objc_setAssociatedObject(
                    self,
                    kFLEXRuntimeSearchIndexKey,
                    index,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );
                @try {
                    [self setValue:@NO forKey:@"scanning"];
                    [self setValue:index.allEntries forKey:@"filteredEntries"];
                } @catch (__unused NSException *exception) {
                }
                reloadItem.enabled = YES;
                scopeItem.enabled = YES;
                search.searchBar.userInteractionEnabled = YES;
                search.searchBar.placeholder = [NSString stringWithFormat:
                    @"Search %lu verified %@ in %@",
                    (unsigned long)index.allEntries.count,
                    kind == FLEXRuntimeBrowserKindObjectiveC ? @"methods" : @"functions",
                    scope.title];
                FLEXSetRuntimeLoading(self, search, NO, nil, nil);
                [self.tableView reloadData];
                [self updateNavigationStatus];
                [self updateUnavailableConfiguration];
            });
        });
    };

    if (!imagePaths.count) {
        completion(@[]);
    } else if (kind == FLEXRuntimeBrowserKindObjectiveC) {
        [FLEXRuntimeScanner
            scanObjectiveCRuntimeInImagePaths:imagePaths
                                     progress:progress
                                   completion:completion];
    } else {
        [FLEXRuntimeScanner
            scanCFunctionsInImagePaths:imagePaths
                               progress:progress
                             completion:completion];
    }
}

- (void)af_image_reloadEntries {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf af_image_reloadEntries];
        });
        return;
    }

    FLEXRuntimeSearchIndex *index = objc_getAssociatedObject(
        self,
        kFLEXRuntimeSearchIndexKey
    );
    if (!index) {
        return;
    }

    UISearchController *search = nil;
    @try {
        search = [self valueForKey:@"searchController"];
    } @catch (__unused NSException *exception) {
        [self af_image_reloadEntries];
        return;
    }

    FLEXRuntimeSearchRequest *previous = objc_getAssociatedObject(
        self,
        kFLEXRuntimeSearchRequestKey
    );
    previous.cancelled = YES;
    FLEXRuntimeSearchRequest *request = [FLEXRuntimeSearchRequest new];
    objc_setAssociatedObject(
        self,
        kFLEXRuntimeSearchRequestKey,
        request,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    NSString *query = search.searchBar.text ?: @"";
    NSTimeInterval debounce = query.length ? 0.12 : 0.0;
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(debounce * NSEC_PER_SEC)),
        FLEXRuntimeSearchQueue(),
        ^{
            NSArray<FLEXHookEntry *> *results = FLEXSearchIndex(
                index,
                query,
                request
            );
            if (!results || request.cancelled) {
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || request.cancelled ||
                    objc_getAssociatedObject(self, kFLEXRuntimeSearchRequestKey) != request) {
                    return;
                }
                @try {
                    [self setValue:results forKey:@"filteredEntries"];
                } @catch (__unused NSException *exception) {
                    return;
                }
                [self.tableView reloadData];
                [self updateNavigationStatus];
                [self updateUnavailableConfiguration];
            });
        }
    );
}

- (UIMenu *)af_image_scopeMenu {
    __weak typeof(self) weakSelf = self;
    FLEXRuntimeSearchScope *selected = FLEXScopeForController(self);

    void (^selectScope)(FLEXRuntimeSearchScope *) = ^(FLEXRuntimeSearchScope *scope) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        objc_setAssociatedObject(
            self,
            kFLEXRuntimeSearchScopeKey,
            scope,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
        @try {
            UIBarButtonItem *scopeItem = [self valueForKey:@"scopeItem"];
            scopeItem.title = scope.title;
            scopeItem.menu = [self af_image_scopeMenu];
        } @catch (__unused NSException *exception) {
        }
        [self reloadScan];
    };

    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    FLEXRuntimeSearchScope *main = FLEXDefaultRuntimeScope();
    UIAction *mainAction = [UIAction
        actionWithTitle:@"Main executable"
                  image:[UIImage systemImageNamed:@"terminal"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        selectScope(main);
    }];
    mainAction.state = selected.kind == FLEXRuntimeSearchScopeMainExecutable
        ? UIMenuElementStateOn : UIMenuElementStateOff;
    [children addObject:mainAction];

    FLEXRuntimeSearchScope *host = [FLEXRuntimeSearchScope new];
    host.kind = FLEXRuntimeSearchScopeHostImages;
    host.imagePath = @"";
    host.title = @"All app images";
    host.cacheKey = @"host-images";
    UIAction *hostAction = [UIAction
        actionWithTitle:@"All app images"
                  image:[UIImage systemImageNamed:@"app"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        selectScope(host);
    }];
    hostAction.state = selected.kind == FLEXRuntimeSearchScopeHostImages
        ? UIMenuElementStateOn : UIMenuElementStateOff;
    [children addObject:hostAction];

    NSMutableArray<UIMenuElement *> *frameworkActions = [NSMutableArray array];
    for (NSString *path in [FLEXRuntimeScanner
            loadedImagePathsIncludingSystemImages:NO]) {
        if ([path isEqualToString:NSBundle.mainBundle.executablePath]) {
            continue;
        }
        FLEXRuntimeSearchScope *framework = [FLEXRuntimeSearchScope new];
        framework.kind = FLEXRuntimeSearchScopeExactImage;
        framework.imagePath = path;
        framework.title = path.lastPathComponent;
        framework.cacheKey = [@"image|" stringByAppendingString:path];
        UIAction *action = [UIAction
            actionWithTitle:path.lastPathComponent
                      image:[UIImage systemImageNamed:@"shippingbox"]
                 identifier:nil
                    handler:^(__unused UIAction *menuAction) {
            selectScope(framework);
        }];
        action.state = selected.kind == FLEXRuntimeSearchScopeExactImage &&
            [selected.imagePath isEqualToString:path]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [frameworkActions addObject:action];
    }
    if (frameworkActions.count) {
        [children addObject:[UIMenu
            menuWithTitle:@"App frameworks"
                    image:nil
               identifier:nil
                  options:0
                 children:frameworkActions]];
    }

    FLEXRuntimeSearchScope *all = [FLEXRuntimeSearchScope new];
    all.kind = FLEXRuntimeSearchScopeAllLoadedImages;
    all.imagePath = @"";
    all.title = @"All loaded images";
    all.cacheKey = @"all-loaded";
    UIAction *allAction = [UIAction
        actionWithTitle:@"All loaded images"
                  image:[UIImage systemImageNamed:@"square.stack.3d.up"]
             identifier:nil
                handler:^(__unused UIAction *action) {
        selectScope(all);
    }];
    allAction.state = selected.kind == FLEXRuntimeSearchScopeAllLoadedImages
        ? UIMenuElementStateOn : UIMenuElementStateOff;
    [children addObject:allAction];

    return [UIMenu
        menuWithTitle:@"Scan scope"
                image:nil
           identifier:nil
              options:UIMenuOptionsDisplayInline
             children:children];
}

- (UITableViewCell *)af_image_tableView:(UITableView *)tableView
                  cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self af_image_tableView:tableView
                             cellForRowAtIndexPath:indexPath];
    id configuration = cell.contentConfiguration;
    if ([configuration isKindOfClass:UIListContentConfiguration.class]) {
        UIListContentConfiguration *content = [configuration copy];
        content.textProperties.numberOfLines = 0;
        content.textProperties.lineBreakMode = NSLineBreakByCharWrapping;
        content.secondaryTextProperties.numberOfLines = 0;
        content.secondaryTextProperties.lineBreakMode = NSLineBreakByWordWrapping;
        cell.contentConfiguration = content;
    }
    return cell;
}

@end
