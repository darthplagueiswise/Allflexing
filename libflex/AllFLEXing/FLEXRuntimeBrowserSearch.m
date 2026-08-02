#import "FLEXRuntimeBrowserController.h"

#import "FLEXCHookEngine.h"
#import "FLEXHookRegistry.h"
#import "FLEXRuntimeImageSession.h"

#import <objc/runtime.h>

const char *FLEXRuntimeSearchABIVersion =
    "AllFLEXing selected-image transient-snapshot prefix-index search ABI 7";

static const void *kFLEXSelectedImageKey = &kFLEXSelectedImageKey;
static const void *kFLEXImageSessionKey = &kFLEXImageSessionKey;
static const void *kFLEXSearchIndexKey = &kFLEXSearchIndexKey;
static const void *kFLEXSearchRequestKey = &kFLEXSearchRequestKey;

@interface FLEXRuntimeSearchRequest : NSObject
@property (atomic) BOOL cancelled;
@end
@implementation FLEXRuntimeSearchRequest
@end

@interface FLEXRuntimeSearchIndex : NSObject
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *entries;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *prefixes;
@property (nonatomic, copy) NSString *imageUUID;
@property (nonatomic) FLEXRuntimeBrowserKind kind;
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

static NSString *FLEXNormalizedSearchText(NSString *source) {
    if (!source.length) return @"";

    NSMutableString *output = [NSMutableString stringWithCapacity:source.length + 8];
    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    NSCharacterSet *upper = NSCharacterSet.uppercaseLetterCharacterSet;
    NSCharacterSet *lower = NSCharacterSet.lowercaseLetterCharacterSet;

    for (NSUInteger index = 0; index < source.length; index++) {
        unichar current = [source characterAtIndex:index];
        BOOL alphanumeric = [letters characterIsMember:current] ||
                            [digits characterIsMember:current];
        if (!alphanumeric) {
            if (output.length && [output characterAtIndex:output.length - 1] != ' ') {
                [output appendString:@" "];
            }
            continue;
        }
        if ([upper characterIsMember:current] && index > 0 && output.length &&
            [output characterAtIndex:output.length - 1] != ' ') {
            unichar previous = [source characterAtIndex:index - 1];
            BOOL boundary = [lower characterIsMember:previous] ||
                            [digits characterIsMember:previous];
            if (!boundary && index + 1 < source.length) {
                unichar next = [source characterAtIndex:index + 1];
                boundary = [upper characterIsMember:previous] &&
                           [lower characterIsMember:next];
            }
            if (boundary) [output appendString:@" "];
        }
        [output appendFormat:@"%C", current];
    }

    NSString *folded = [output stringByFoldingWithOptions:
        (NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch |
         NSWidthInsensitiveSearch)
        locale:NSLocale.currentLocale];
    NSArray<NSString *> *parts = [folded.lowercaseString
        componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length) [tokens addObject:part];
    }
    return [tokens componentsJoinedByString:@" "];
}

static NSArray<NSString *> *FLEXSearchTokens(NSString *source) {
    NSString *normalized = FLEXNormalizedSearchText(source);
    return normalized.length
        ? [normalized componentsSeparatedByString:@" "] : @[];
}

static void FLEXAppendSearchValue(NSMutableString *text, id value) {
    if ([value isKindOfClass:NSString.class] && [value length]) {
        [text appendString:value];
        [text appendString:@" "];
    } else if ([value isKindOfClass:NSNumber.class]) {
        [text appendString:[value stringValue]];
        [text appendString:@" "];
    }
}

static FLEXRuntimeImageDescriptor *FLEXDefaultRuntimeImage(void) {
    NSArray<FLEXRuntimeImageDescriptor *> *images =
        FLEXRuntimeImageSession.loadedAppImages;
    for (FLEXRuntimeImageDescriptor *image in images) {
        if (image.mainExecutable) return image;
    }
    return images.firstObject;
}

static FLEXRuntimeImageDescriptor *FLEXRuntimeImageForController(id controller) {
    FLEXRuntimeImageDescriptor *image = objc_getAssociatedObject(
        controller,
        kFLEXSelectedImageKey
    );
    if (!image) {
        image = FLEXDefaultRuntimeImage();
        if (image) {
            objc_setAssociatedObject(
                controller,
                kFLEXSelectedImageKey,
                image,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC
            );
        }
    }
    return image;
}

static BOOL FLEXEntryHasVerifiedBackend(FLEXHookEntry *entry,
                                        FLEXRuntimeBrowserKind kind) {
    if (!entry.available || entry.stale) return NO;

    if (kind == FLEXRuntimeBrowserKindObjectiveC) {
        // AllFLEXing currently owns typed BOOL replacement profiles only.
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
        NSNumber *address = [entry.locator[@"address"]
            isKindOfClass:NSNumber.class] ? entry.locator[@"address"] : nil;
        NSString *symbol = [entry.locator[@"symbol"]
            isKindOfClass:NSString.class] ? entry.locator[@"symbol"] : nil;
        void *resolved = [FLEXCHookEngine resolveSymbol:symbol];
        return address.unsignedLongLongValue != 0 &&
               resolved == (void *)(uintptr_t)address.unsignedLongLongValue;
    }
    return NO;
}

static NSArray<FLEXHookEntry *> *FLEXVerifiedSnapshotEntries(
    FLEXRuntimeImageSnapshot *snapshot
) {
    NSMutableArray<FLEXHookEntry *> *verified = [NSMutableArray array];
    for (FLEXHookEntry *entry in snapshot.entries) {
        if (FLEXEntryHasVerifiedBackend(entry, snapshot.kind)) {
            [verified addObject:entry];
        }
    }
    return verified.copy;
}

static FLEXRuntimeSearchIndex *FLEXBuildRuntimeIndex(
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

    NSMutableDictionary<NSString *, NSMutableIndexSet *> *mutablePrefixes =
        [NSMutableDictionary dictionary];
    NSArray<NSString *> *locatorKeys = @[
        @"symbol", @"class", @"selector", @"encoding", @"image",
        @"imageUUID", @"backendEvidence", @"abiEvidence", @"source"
    ];

    for (NSUInteger entryIndex = 0; entryIndex < sorted.count; entryIndex++) {
        if ((entryIndex & 127) == 0 && request.cancelled) return nil;
        FLEXHookEntry *entry = sorted[entryIndex];
        @autoreleasepool {
            NSMutableString *raw = [NSMutableString string];
            FLEXAppendSearchValue(raw, entry.title);
            FLEXAppendSearchValue(raw, entry.identifier);
            FLEXAppendSearchValue(raw, entry.detail);
            FLEXAppendSearchValue(raw, entry.imageName);
            for (NSString *key in locatorKeys) {
                FLEXAppendSearchValue(raw, entry.locator[key]);
            }

            NSSet<NSString *> *uniqueTokens =
                [NSSet setWithArray:FLEXSearchTokens(raw)];
            for (NSString *token in uniqueTokens) {
                NSUInteger prefixLength = MIN((NSUInteger)32, token.length);
                for (NSUInteger length = 1; length <= prefixLength; length++) {
                    NSString *prefix = [token substringToIndex:length];
                    NSMutableIndexSet *indexes = mutablePrefixes[prefix];
                    if (!indexes) {
                        indexes = [NSMutableIndexSet indexSet];
                        mutablePrefixes[prefix] = indexes;
                    }
                    [indexes addIndex:entryIndex];
                }
                if (token.length > prefixLength) {
                    NSMutableIndexSet *indexes = mutablePrefixes[token];
                    if (!indexes) {
                        indexes = [NSMutableIndexSet indexSet];
                        mutablePrefixes[token] = indexes;
                    }
                    [indexes addIndex:entryIndex];
                }
            }
        }
    }
    if (request.cancelled) return nil;

    NSMutableDictionary<NSString *, NSIndexSet *> *prefixes =
        [NSMutableDictionary dictionaryWithCapacity:mutablePrefixes.count];
    [mutablePrefixes enumerateKeysAndObjectsUsingBlock:^(
        NSString *key,
        NSMutableIndexSet *indexes,
        BOOL *stop
    ) {
        (void)stop;
        prefixes[key] = indexes.copy;
    }];

    FLEXRuntimeSearchIndex *index = [FLEXRuntimeSearchIndex new];
    index.entries = sorted;
    index.prefixes = prefixes.copy;
    index.imageUUID = imageUUID ?: @"";
    index.kind = kind;
    return index;
}

static NSArray<FLEXHookEntry *> *FLEXQueryRuntimeIndex(
    FLEXRuntimeSearchIndex *index,
    NSString *query,
    FLEXRuntimeSearchRequest *request
) {
    NSArray<NSString *> *tokens = FLEXSearchTokens(query);
    if (!tokens.count) return index.entries;

    NSMutableIndexSet *matches = nil;
    for (NSString *token in tokens) {
        if (request.cancelled) return nil;
        NSIndexSet *tokenMatches = index.prefixes[token];
        if (!tokenMatches.count) return @[];
        if (!matches) matches = tokenMatches.mutableCopy;
        else [matches intersectIndexes:tokenMatches];
        if (!matches.count) return @[];
    }

    NSMutableArray<FLEXHookEntry *> *results =
        [NSMutableArray arrayWithCapacity:matches.count];
    [matches enumerateIndexesUsingBlock:^(NSUInteger indexValue, BOOL *stop) {
        if (request.cancelled) {
            *stop = YES;
            return;
        }
        if (indexValue < index.entries.count) {
            [results addObject:index.entries[indexValue]];
        }
    }];
    return request.cancelled ? nil : results.copy;
}

static void FLEXSetLoading(UIViewController *controller,
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
            configuration.secondaryText = detail ?: @"Reading complete runtime metadata.";
            controller.contentUnavailableConfiguration = configuration;
        } else {
            controller.contentUnavailableConfiguration = nil;
        }
    }
}

static void FLEXSetFailure(UIViewController *controller, NSString *message) {
    if (@available(iOS 17.0, *)) {
        UIContentUnavailableConfiguration *configuration =
            [UIContentUnavailableConfiguration emptyConfiguration];
        configuration.image = [UIImage systemImageNamed:@"exclamationmark.triangle"];
        configuration.text = @"Runtime image scan failed";
        configuration.secondaryText = message ?: @"The selected image could not be scanned.";
        controller.contentUnavailableConfiguration = configuration;
    }
}

static void FLEXRemoveManualTargetButton(FLEXRuntimeBrowserController *controller) {
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
        FLEXExchangeInstanceMethods(cls, @selector(viewDidLoad),
                                     @selector(af_image_viewDidLoad));
        FLEXExchangeInstanceMethods(cls, @selector(reloadEntries),
                                     @selector(af_image_reloadEntries));
        FLEXExchangeInstanceMethods(cls, @selector(reloadScan),
                                     @selector(af_image_reloadScan));
        FLEXExchangeInstanceMethods(cls, @selector(scopeMenu),
                                     @selector(af_image_scopeMenu));
        FLEXExchangeInstanceMethods(cls,
            @selector(tableView:cellForRowAtIndexPath:),
            @selector(af_image_tableView:cellForRowAtIndexPath:));
    });
}

- (void)af_image_viewDidLoad {
    (void)FLEXRuntimeImageForController(self);
    [self af_image_viewDidLoad];
    FLEXRemoveManualTargetButton(self);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78.0;

    FLEXRuntimeImageDescriptor *image = FLEXRuntimeImageForController(self);
    @try {
        UIBarButtonItem *scopeItem = [self valueForKey:@"scopeItem"];
        scopeItem.title = image.displayName ?: @"Select image";
        scopeItem.menu = [self af_image_scopeMenu];
    } @catch (__unused NSException *exception) {
    }
}

- (void)af_image_reloadScan {
    FLEXRuntimeImageSession *previousSession = objc_getAssociatedObject(
        self,
        kFLEXImageSessionKey
    );
    [previousSession cancel];
    FLEXRuntimeSearchRequest *previousSearch = objc_getAssociatedObject(
        self,
        kFLEXSearchRequestKey
    );
    previousSearch.cancelled = YES;
    objc_setAssociatedObject(self, kFLEXSearchIndexKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    FLEXRuntimeImageDescriptor *image = FLEXRuntimeImageForController(self);
    if (!image) {
        FLEXSetFailure(self, @"No app Mach-O image is currently loaded.");
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
    objc_setAssociatedObject(self, kFLEXImageSessionKey, session,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    reloadItem.enabled = NO;
    scopeItem.enabled = NO;
    [self.tableView reloadData];
    FLEXSetLoading(self, search, YES,
        @"Scanning selected Mach-O image",
        [NSString stringWithFormat:@"%@ · complete scan before search",
            image.displayName]);

    __weak typeof(self) weakSelf = self;
    [session scanKind:kind
             progress:^(NSString *phase, NSUInteger completed, NSUInteger total) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || session.cancelled ||
            objc_getAssociatedObject(self, kFLEXImageSessionKey) != session) return;
        NSString *detail = total
            ? [NSString stringWithFormat:@"%@ · %lu/%lu",
                image.displayName,
                (unsigned long)completed,
                (unsigned long)total]
            : image.displayName;
        FLEXSetLoading(self, search, YES, phase, detail);
        if (@available(iOS 26.0, *)) {
            self.navigationItem.subtitle = [NSString stringWithFormat:@"%@ · %@",
                image.displayName, phase];
        }
    }
           completion:^(FLEXRuntimeImageSnapshot *snapshot, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || session.cancelled ||
            objc_getAssociatedObject(self, kFLEXImageSessionKey) != session) return;

        if (!snapshot) {
            @try { [self setValue:@NO forKey:@"scanning"]; }
            @catch (__unused NSException *exception) {}
            reloadItem.enabled = YES;
            scopeItem.enabled = YES;
            search.searchBar.userInteractionEnabled = NO;
            FLEXSetFailure(self, error.localizedDescription);
            return;
        }

        NSArray<FLEXHookEntry *> *verified = FLEXVerifiedSnapshotEntries(snapshot);
        FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
        NSMutableArray<FLEXHookEntry *> *transientEntries =
            [NSMutableArray arrayWithCapacity:verified.count];
        for (FLEXHookEntry *entry in verified) {
            FLEXHookEntry *resolved = [registry upsertDiscoveredEntry:entry];
            if (resolved) [transientEntries addObject:resolved];
        }

        FLEXRuntimeSearchRequest *indexRequest = [FLEXRuntimeSearchRequest new];
        objc_setAssociatedObject(self, kFLEXSearchRequestKey, indexRequest,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FLEXSetLoading(self, search, YES,
            @"Indexing verified runtime targets",
            [NSString stringWithFormat:@"%lu target(s) in %@",
                (unsigned long)transientEntries.count,
                image.displayName]);

        dispatch_async(FLEXRuntimeSearchQueue(), ^{
            FLEXRuntimeSearchIndex *index = FLEXBuildRuntimeIndex(
                transientEntries.copy,
                kind,
                image.uuid,
                indexRequest
            );
            if (!index || indexRequest.cancelled) return;

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || session.cancelled || indexRequest.cancelled ||
                    objc_getAssociatedObject(self, kFLEXImageSessionKey) != session) return;
                objc_setAssociatedObject(self, kFLEXSearchIndexKey, index,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                @try {
                    [self setValue:@NO forKey:@"scanning"];
                    [self setValue:index.entries forKey:@"filteredEntries"];
                } @catch (__unused NSException *exception) {}
                reloadItem.enabled = YES;
                scopeItem.enabled = YES;
                search.searchBar.userInteractionEnabled = YES;
                search.searchBar.placeholder = [NSString stringWithFormat:
                    @"Search %lu verified target(s) in %@",
                    (unsigned long)index.entries.count,
                    image.displayName];
                FLEXSetLoading(self, search, NO, nil, nil);
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
        kFLEXSearchIndexKey
    );
    if (!index) return;

    UISearchController *search = nil;
    @try { search = [self valueForKey:@"searchController"]; }
    @catch (__unused NSException *exception) {
        [self af_image_reloadEntries];
        return;
    }

    FLEXRuntimeSearchRequest *previous = objc_getAssociatedObject(
        self,
        kFLEXSearchRequestKey
    );
    previous.cancelled = YES;
    FLEXRuntimeSearchRequest *request = [FLEXRuntimeSearchRequest new];
    objc_setAssociatedObject(self, kFLEXSearchRequestKey, request,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *query = search.searchBar.text ?: @"";
    NSTimeInterval debounce = query.length ? 0.10 : 0.0;
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(debounce * NSEC_PER_SEC)),
        FLEXRuntimeSearchQueue(),
        ^{
            NSArray<FLEXHookEntry *> *results = FLEXQueryRuntimeIndex(
                index, query, request);
            if (!results || request.cancelled) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || request.cancelled ||
                    objc_getAssociatedObject(self, kFLEXSearchRequestKey) != request) return;
                @try { [self setValue:results forKey:@"filteredEntries"]; }
                @catch (__unused NSException *exception) { return; }
                [self.tableView reloadData];
                [self updateNavigationStatus];
                [self updateUnavailableConfiguration];
            });
        }
    );
}

- (UIMenu *)af_image_scopeMenu {
    __weak typeof(self) weakSelf = self;
    FLEXRuntimeImageDescriptor *selected = FLEXRuntimeImageForController(self);
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];

    for (FLEXRuntimeImageDescriptor *image in FLEXRuntimeImageSession.loadedAppImages) {
        UIAction *action = [UIAction
            actionWithTitle:image.displayName
                      image:[UIImage systemImageNamed:image.mainExecutable
                          ? @"terminal" : @"shippingbox"]
                 identifier:nil
                    handler:^(__unused UIAction *menuAction) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            objc_setAssociatedObject(self, kFLEXSelectedImageKey, image,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try {
                UIBarButtonItem *scopeItem = [self valueForKey:@"scopeItem"];
                scopeItem.title = image.displayName;
                scopeItem.menu = [self af_image_scopeMenu];
            } @catch (__unused NSException *exception) {}
            [self reloadScan];
        }];
        action.state = [selected.path isEqualToString:image.path]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }

    return [UIMenu menuWithTitle:@"Loaded app image"
                           image:nil
                      identifier:nil
                         options:UIMenuOptionsDisplayInline
                        children:actions];
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
