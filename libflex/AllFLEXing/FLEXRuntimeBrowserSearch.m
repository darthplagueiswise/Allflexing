#import "FLEXRuntimeBrowserController.h"

#import "FLEXCHookEngine.h"
#import "FLEXHookRegistry.h"
#import "FLEXRuntimeImageSession.h"

#import <objc/runtime.h>

const char *FLEXRuntimeSearchABIVersion =
    "AllFLEXing selected-image complete-snapshot prefix-index search ABI 6";

static const void *kFLEXRuntimeSelectedImageKey = &kFLEXRuntimeSelectedImageKey;
static const void *kFLEXRuntimeImageSessionKey = &kFLEXRuntimeImageSessionKey;
static const void *kFLEXRuntimeSearchIndexKey = &kFLEXRuntimeSearchIndexKey;
static const void *kFLEXRuntimeSearchRequestKey = &kFLEXRuntimeSearchRequestKey;

@interface FLEXRuntimeSearchRequest : NSObject
@property (atomic) BOOL cancelled;
@end
@implementation FLEXRuntimeSearchRequest
@end

@interface FLEXRuntimeSearchRecord : NSObject
@property (nonatomic) FLEXHookEntry *entry;
@end
@implementation FLEXRuntimeSearchRecord
@end

@interface FLEXRuntimeSearchIndex : NSObject
@property (nonatomic, copy) NSString *imageUUID;
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

static FLEXRuntimeImageDescriptor *FLEXDefaultImage(void) {
    NSArray<FLEXRuntimeImageDescriptor *> *images =
        FLEXRuntimeImageSession.loadedAppImages;
    for (FLEXRuntimeImageDescriptor *image in images) {
        if (image.mainExecutable) {
            return image;
        }
    }
    return images.firstObject;
}

static FLEXRuntimeImageDescriptor *FLEXSelectedImage(id controller) {
    FLEXRuntimeImageDescriptor *image = objc_getAssociatedObject(
        controller,
        kFLEXRuntimeSelectedImageKey
    );
    if (!image) {
        image = FLEXDefaultImage();
        if (image) {
            objc_setAssociatedObject(
                controller,
                kFLEXRuntimeSelectedImageKey,
                image,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }
    }
    return image;
}

static BOOL FLEXEntryIsVerifiedForBrowser(FLEXHookEntry *entry,
                                          FLEXRuntimeBrowserKind kind) {
    if (!entry.available || entry.stale) {
        return NO;
    }
    if (kind == FLEXRuntimeBrowserKindObjectiveC) {
        return entry.surface == FLEXHookSurfaceObjectiveC &&
               entry.backend == FLEXHookBackendObjectiveCElleKit &&
               entry.abi != FLEXHookABIUnknown;
    }

    if (entry.surface == FLEXHookSurfaceCImport) {
        return entry.backend == FLEXHookBackendFishhook &&
               [entry.locator[@"bindSlots"] unsignedIntegerValue] > 0;
    }
    if (entry.surface == FLEXHookSurfaceCInline) {
        if (entry.backend != FLEXHookBackendInlineElleKit ||
            ![entry.locator[@"source"] isEqualToString:@"mach-o-symbol-table"]) {
            return NO;
        }
        NSNumber *recordedAddress = [entry.locator[@"address"]
            isKindOfClass:NSNumber.class] ? entry.locator[@"address"] : nil;
        NSString *symbol = [entry.locator[@"symbol"]
            isKindOfClass:NSString.class] ? entry.locator[@"symbol"] : nil;
        void *resolved = [FLEXCHookEngine resolveSymbol:symbol];
        return recordedAddress.unsignedLongLongValue != 0 &&
            resolved == (void *)(uintptr_t)recordedAddress.unsignedLongLongValue;
    }
    return NO;
}

static NSArray<FLEXHookEntry *> *FLEXVerifiedEntries(
    FLEXRuntimeImageSnapshot *snapshot
) {
    NSMutableArray<FLEXHookEntry *> *verified = [NSMutableArray array];
    for (FLEXHookEntry *entry in snapshot.entries) {
        if (FLEXEntryIsVerifiedForBrowser(entry, snapshot.kind)) {
            [verified addObject:entry];
        }
    }
    return verified.copy;
}

static FLEXRuntimeSearchIndex *FLEXBuildSearchIndex(
    NSArray<FLEXHookEntry *> *entries,
    FLEXRuntimeBrowserKind kind,
    NSString *imageUUID,
    FLEXRuntimeSearchRequest *request
) {
    NSArray<FLEXHookEntry *> *sorted = [entries sortedArrayUsingComparator:^NSComparisonResult(
        FLEXHookEntry *left,
        FLEXHookEntry *right
    ) {
        if (left.surface != right.surface) {
            return left.surface < right.surface
                ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];

    NSMutableArray<FLEXRuntimeSearchRecord *> *records =
        [NSMutableArray arrayWithCapacity:sorted.count];
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *mutablePrefixMap =
        [NSMutableDictionary dictionary];
    NSArray<NSString *> *locatorKeys = @[
        @"symbol", @"class", @"selector", @"encoding",
        @"image", @"imageUUID", @"backendEvidence", @"abiEvidence",
        @"source"
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
    index.imageUUID = imageUUID ?: @"";
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

static void FLEXSetRuntimeFailure(UIViewController *controller,
                                  NSString *message) {
    if (@available(iOS 17.0, *)) {
        UIContentUnavailableConfiguration *configuration =
            [UIContentUnavailableConfiguration emptyConfiguration];
        configuration.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        configuration.text = @"Runtime image scan failed";
        configuration.secondaryText = message ?: @"The selected image could not be scanned.";
        controller.contentUnavailableConfiguration = configuration;
    }
}

static void FLEXRemoveManualSymbolButton(FLEXRuntimeBrowserController *controller) {
    NSMutableArray<UIBarButtonItem *> *items =
        [controller.navigationItem.rightBarButtonItems mutableCopy];
    NSIndexSet *indexes = [items indexesOfObjectsPassingTest:^BOOL(
        UIBarButtonItem *item,
        NSUInteger index,
        BOOL *stop
    ) {
        (void)index;
        (void)stop;
        return item.action == NSSelectorFromString(@"addManualSymbol:");
    }];
    if (indexes.count) {
        [items removeObjectsAtIndexes:indexes];
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
    (void)FLEXSelectedImage(self);
    [self af_image_viewDidLoad];
    FLEXRemoveManualSymbolButton(self);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78.0;

    FLEXRuntimeImageDescriptor *image = FLEXSelectedImage(self);
    @try {
        UIBarButtonItem *scopeItem = [self valueForKey:@"scopeItem"];
        scopeItem.title = image.displayName ?: @"Select image";
        scopeItem.menu = [self af_image_scopeMenu];
    } @catch (__unused NSException *exception) {
    }
}

- (void)af_image_reloadScan {
    FLEXRuntimeImageSession *oldSession = objc_getAssociatedObject(
        self,
        kFLEXRuntimeImageSessionKey
    );
    [oldSession cancel];
    FLEXRuntimeSearchRequest *oldSearch = objc_getAssociatedObject(
        self,
        kFLEXRuntimeSearchRequestKey
    );
    oldSearch.cancelled = YES;
    objc_setAssociatedObject(
        self,
        kFLEXRuntimeSearchIndexKey,
        nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    FLEXRuntimeImageDescriptor *image = FLEXSelectedImage(self);
    if (!image) {
        FLEXSetRuntimeFailure(self, @"No app Mach-O image is currently loaded.");
        return;
    }

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

    FLEXRuntimeImageSession *session = [[FLEXRuntimeImageSession alloc]
        initWithImage:image];
    objc_setAssociatedObject(
        self,
        kFLEXRuntimeImageSessionKey,
        session,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );

    reloadItem.enabled = NO;
    scopeItem.enabled = NO;
    [self.tableView reloadData];
    FLEXSetRuntimeLoading(
        self,
        search,
        YES,
        @"Scanning selected Mach-O image",
        [NSString stringWithFormat:@"%@ · full scan before search",
            image.displayName]
    );

    __weak typeof(self) weakSelf = self;
    [session scanKind:kind
             progress:^(NSString *phase, NSUInteger completed, NSUInteger total) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || session.cancelled ||
            objc_getAssociatedObject(self, kFLEXRuntimeImageSessionKey) != session) {
            return;
        }
        NSString *detail = total
            ? [NSString stringWithFormat:@"%@ · %lu/%lu",
                image.displayName,
                (unsigned long)completed,
                (unsigned long)total]
            : image.displayName;
        FLEXSetRuntimeLoading(self, search, YES, phase, detail);
        if (@available(iOS 26.0, *)) {
            self.navigationItem.subtitle = [NSString stringWithFormat:@"%@ · %@",
                image.displayName,
                phase];
        }
    }
           completion:^(FLEXRuntimeImageSnapshot *snapshot, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || session.cancelled ||
            objc_getAssociatedObject(self, kFLEXRuntimeImageSessionKey) != session) {
            return;
        }
        if (!snapshot) {
            @try {
                [self setValue:@NO forKey:@"scanning"];
            } @catch (__unused NSException *exception) {
            }
            reloadItem.enabled = YES;
            scopeItem.enabled = YES;
            search.searchBar.userInteractionEnabled = NO;
            FLEXSetRuntimeFailure(self, error.localizedDescription);
            return;
        }

        NSArray<FLEXHookEntry *> *verified = FLEXVerifiedEntries(snapshot);
        FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
        NSMutableArray<FLEXHookEntry *> *resolved = [NSMutableArray array];
        if (kind == FLEXRuntimeBrowserKindObjectiveC) {
            [resolved addObjectsFromArray:[registry
                mergeDiscoveredEntries:verified
                               surface:FLEXHookSurfaceObjectiveC
                            imagePaths:@[image.path]]];
        } else {
            NSPredicate *imports = [NSPredicate predicateWithBlock:^BOOL(
                FLEXHookEntry *entry,
                NSDictionary *bindings
            ) {
                (void)bindings;
                return entry.surface == FLEXHookSurfaceCImport;
            }];
            NSPredicate *inlineTargets = [NSPredicate predicateWithBlock:^BOOL(
                FLEXHookEntry *entry,
                NSDictionary *bindings
            ) {
                (void)bindings;
                return entry.surface == FLEXHookSurfaceCInline;
            }];
            [resolved addObjectsFromArray:[registry
                mergeDiscoveredEntries:[verified filteredArrayUsingPredicate:imports]
                               surface:FLEXHookSurfaceCImport
                            imagePaths:@[image.path]]];
            [resolved addObjectsFromArray:[registry
                mergeDiscoveredEntries:[verified filteredArrayUsingPredicate:inlineTargets]
                               surface:FLEXHookSurfaceCInline
                            imagePaths:@[image.path]]];
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
            @"Indexing verified runtime targets",
            [NSString stringWithFormat:@"%lu target(s) in %@",
                (unsigned long)resolved.count,
                image.displayName]
        );

        dispatch_async(FLEXRuntimeSearchQueue(), ^{
            FLEXRuntimeSearchIndex *index = FLEXBuildSearchIndex(
                resolved.copy,
                kind,
                image.uuid,
                indexRequest
            );
            if (!index || indexRequest.cancelled) {
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || session.cancelled || indexRequest.cancelled ||
                    objc_getAssociatedObject(self, kFLEXRuntimeImageSessionKey) != session) {
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
                    @"Search %lu verified target(s) in %@",
                    (unsigned long)index.allEntries.count,
                    image.displayName];
                FLEXSetRuntimeLoading(self, search, NO, nil, nil);
                [self.tableView reloadData];
                [self updateNavigationStatus];
                [self updateUnavailableConfiguration];
            });
        });
    }];
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
    NSTimeInterval debounce = query.length ? 0.10 : 0.0;
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
    FLEXRuntimeImageDescriptor *selected = FLEXSelectedImage(self);
    NSMutableArray<UIMenuElement *> *images = [NSMutableArray array];

    for (FLEXRuntimeImageDescriptor *image in FLEXRuntimeImageSession.loadedAppImages) {
        UIAction *action = [UIAction
            actionWithTitle:image.displayName
                      image:[UIImage systemImageNamed:image.mainExecutable
                          ? @"terminal" : @"shippingbox"]
                 identifier:nil
                    handler:^(__unused UIAction *menuAction) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) {
                return;
            }
            objc_setAssociatedObject(
                self,
                kFLEXRuntimeSelectedImageKey,
                image,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
            @try {
                UIBarButtonItem *scopeItem = [self valueForKey:@"scopeItem"];
                scopeItem.title = image.displayName;
                scopeItem.menu = [self af_image_scopeMenu];
            } @catch (__unused NSException *exception) {
            }
            [self reloadScan];
        }];
        action.state = [selected.path isEqualToString:image.path]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [images addObject:action];
    }

    return [UIMenu
        menuWithTitle:@"Loaded app image"
                image:nil
           identifier:nil
              options:UIMenuOptionsDisplayInline
             children:images];
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
