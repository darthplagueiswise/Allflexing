#import "FLEXRuntimeBrowserController.h"

#import "FLEXHookRegistry.h"

#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <stdatomic.h>

const char *FLEXRuntimeSearchABIVersion =
    "AllFLEXing full-snapshot async indexed cancellable search ABI 4";

static const void *kFLEXRuntimeSearchRequestKey = &kFLEXRuntimeSearchRequestKey;
static const void *kFLEXRuntimeSearchIndexKey = &kFLEXRuntimeSearchIndexKey;
static const void *kFLEXRuntimeSearchScopeKey = &kFLEXRuntimeSearchScopeKey;
static atomic_ullong gFLEXRuntimeSearchRevision = 1;
static id gFLEXRuntimeSearchRevisionObserver;

typedef NS_ENUM(NSInteger, FLEXRuntimeSearchScopeKind) {
    FLEXRuntimeSearchScopeHostImages = 0,
    FLEXRuntimeSearchScopeMainExecutable,
    FLEXRuntimeSearchScopeExactImage,
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
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *image;
@property (nonatomic, copy) NSString *searchText;
@end
@implementation FLEXRuntimeSearchRecord
@end

@interface FLEXRuntimeSearchIndex : NSObject
@property (nonatomic) unsigned long long revision;
@property (nonatomic) FLEXRuntimeBrowserKind kind;
@property (nonatomic, copy) NSString *scopeKey;
@property (nonatomic, copy) NSArray<FLEXRuntimeSearchRecord *> *records;
@end
@implementation FLEXRuntimeSearchIndex
@end

@interface FLEXRuntimeSearchMatch : NSObject
@property (nonatomic) FLEXRuntimeSearchRecord *record;
@property (nonatomic) NSInteger score;
@end
@implementation FLEXRuntimeSearchMatch
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
        queue = dispatch_queue_create("com.allflexing.runtime-search", attributes);
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
            BOOL previousLowerOrDigit = [lower characterIsMember:previous] ||
                                        [digits characterIsMember:previous];
            BOOL acronymBoundary = NO;
            if (index + 1 < source.length) {
                unichar next = [source characterAtIndex:index + 1];
                acronymBoundary = [upper characterIsMember:previous] &&
                                  [lower characterIsMember:next];
            }
            if (previousLowerOrDigit || acronymBoundary) {
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

static NSArray<NSString *> *FLEXSearchTokens(NSString *normalized) {
    return normalized.length ? [normalized componentsSeparatedByString:@" "] : @[];
}

static BOOL FLEXRuntimeSurfaceMatches(FLEXHookEntry *entry,
                                      FLEXRuntimeBrowserKind kind) {
    return kind == FLEXRuntimeBrowserKindObjectiveC
        ? entry.surface == FLEXHookSurfaceObjectiveC
        : (entry.surface == FLEXHookSurfaceCImport ||
           entry.surface == FLEXHookSurfaceCInline);
}

static NSString *FLEXEntryImagePath(FLEXHookEntry *entry) {
    id value = entry.locator[@"image"];
    if ([value isKindOfClass:NSString.class] && [value length]) {
        return value;
    }
    return entry.imageName ?: @"";
}

static FLEXRuntimeSearchScope *FLEXDefaultRuntimeScope(void) {
    FLEXRuntimeSearchScope *scope = [FLEXRuntimeSearchScope new];
    scope.kind = FLEXRuntimeSearchScopeHostImages;
    scope.title = @"App images";
    scope.cacheKey = @"host-images";
    scope.imagePath = @"";
    return scope;
}

static FLEXRuntimeSearchScope *FLEXScopeForController(id controller) {
    FLEXRuntimeSearchScope *scope = objc_getAssociatedObject(
        controller, kFLEXRuntimeSearchScopeKey);
    if (!scope) {
        scope = FLEXDefaultRuntimeScope();
        objc_setAssociatedObject(controller,
                                 kFLEXRuntimeSearchScopeKey,
                                 scope,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return scope;
}

static BOOL FLEXEntryMatchesScope(FLEXHookEntry *entry,
                                  FLEXRuntimeSearchScope *scope) {
    NSString *path = FLEXEntryImagePath(entry);
    switch (scope.kind) {
        case FLEXRuntimeSearchScopeMainExecutable:
            return [path isEqualToString:NSBundle.mainBundle.executablePath];
        case FLEXRuntimeSearchScopeExactImage:
            return [path isEqualToString:scope.imagePath] ||
                [entry.imageName isEqualToString:scope.imagePath.lastPathComponent];
        case FLEXRuntimeSearchScopeAllLoadedImages:
            return YES;
        case FLEXRuntimeSearchScopeHostImages: {
            NSString *bundlePath = NSBundle.mainBundle.bundlePath;
            return bundlePath.length && [path hasPrefix:bundlePath];
        }
    }
}

static NSArray<NSString *> *FLEXLoadedHostImagePaths(void) {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    NSString *executable = NSBundle.mainBundle.executablePath;
    if (executable.length) {
        [paths addObject:executable];
    }
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *raw = _dyld_get_image_name(index);
        if (!raw) {
            continue;
        }
        NSString *path = [NSString stringWithUTF8String:raw];
        if (bundlePath.length && [path hasPrefix:bundlePath]) {
            [paths addObject:path];
        }
    }
    return [paths.array sortedArrayUsingComparator:^NSComparisonResult(
        NSString *left, NSString *right
    ) {
        if ([left isEqualToString:executable]) return NSOrderedAscending;
        if ([right isEqualToString:executable]) return NSOrderedDescending;
        return [left.lastPathComponent localizedCaseInsensitiveCompare:
            right.lastPathComponent];
    }];
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

static FLEXRuntimeSearchIndex *FLEXBuildRuntimeSearchIndex(
    NSArray<FLEXHookEntry *> *entries,
    FLEXRuntimeBrowserKind kind,
    FLEXRuntimeSearchScope *scope,
    unsigned long long revision,
    FLEXRuntimeSearchRequest *request
) {
    NSMutableArray<FLEXRuntimeSearchRecord *> *records =
        [NSMutableArray arrayWithCapacity:entries.count];
    NSArray<NSString *> *locatorKeys = @[
        @"symbol", @"class", @"selector", @"encoding",
        @"image", @"imageUUID"
    ];

    NSUInteger visited = 0;
    for (FLEXHookEntry *entry in entries) {
        if ((visited++ & 127) == 0 && request.cancelled) {
            return nil;
        }
        if (!FLEXRuntimeSurfaceMatches(entry, kind) ||
            !FLEXEntryMatchesScope(entry, scope)) {
            continue;
        }

        @autoreleasepool {
            NSMutableString *raw = [NSMutableString stringWithCapacity:
                entry.title.length + entry.identifier.length +
                entry.detail.length + entry.imageName.length + 64];
            FLEXAppendSearchField(raw, entry.title);
            FLEXAppendSearchField(raw, entry.identifier);
            FLEXAppendSearchField(raw, entry.detail);
            FLEXAppendSearchField(raw, entry.imageName);
            NSDictionary *locator = entry.locator;
            if ([locator isKindOfClass:NSDictionary.class]) {
                for (NSString *key in locatorKeys) {
                    FLEXAppendSearchField(raw, locator[key]);
                }
            }

            FLEXRuntimeSearchRecord *record = [FLEXRuntimeSearchRecord new];
            record.entry = entry;
            record.title = FLEXSearchNormalizedText(entry.title);
            record.identifier = FLEXSearchNormalizedText(entry.identifier);
            record.image = FLEXSearchNormalizedText(entry.imageName);
            record.searchText = FLEXSearchNormalizedText(raw);
            [records addObject:record];
        }
    }

    if (request.cancelled) {
        return nil;
    }
    FLEXRuntimeSearchIndex *index = [FLEXRuntimeSearchIndex new];
    index.revision = revision;
    index.kind = kind;
    index.scopeKey = scope.cacheKey;
    index.records = records.copy;
    return index;
}

static BOOL FLEXTextContainsSearchToken(NSString *text, NSString *token) {
    if (!text.length || !token.length) {
        return NO;
    }
    if (token.length > 1) {
        return [text rangeOfString:token].location != NSNotFound;
    }

    NSRange remaining = NSMakeRange(0, text.length);
    while (remaining.length) {
        NSRange match = [text rangeOfString:token options:0 range:remaining];
        if (match.location == NSNotFound) {
            return NO;
        }
        if (match.location == 0 || [text characterAtIndex:match.location - 1] == ' ') {
            return YES;
        }
        NSUInteger next = NSMaxRange(match);
        if (next >= text.length) {
            return NO;
        }
        remaining = NSMakeRange(next, text.length - next);
    }
    return NO;
}

static NSInteger FLEXRuntimeSearchScore(FLEXRuntimeSearchRecord *record,
                                        NSArray<NSString *> *tokens,
                                        NSString *query) {
    for (NSString *token in tokens) {
        if (!FLEXTextContainsSearchToken(record.searchText, token)) {
            return -1;
        }
    }

    NSInteger score = 0;
    if ([record.title isEqualToString:query]) score += 500;
    else if ([record.title hasPrefix:query]) score += 320;
    else if ([record.title containsString:query]) score += 180;
    if ([record.identifier containsString:query]) score += 110;
    if ([record.image containsString:query]) score += 60;
    for (NSString *token in tokens) {
        if ([record.title hasPrefix:token]) score += 45;
        else if ([record.title containsString:token]) score += 20;
    }
    return score;
}

static NSUInteger FLEXRuntimeMaterializationLimit(NSString *query) {
    NSString *compact = [query stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (!compact.length) return 1500;
    if (compact.length == 1) return 256;
    if (compact.length == 2) return 1024;
    return 4096;
}

static NSArray<FLEXHookEntry *> *FLEXMaterializeRuntimeResults(
    FLEXRuntimeSearchIndex *index,
    NSString *query,
    FLEXRuntimeSearchRequest *request,
    BOOL *truncated
) {
    NSUInteger limit = FLEXRuntimeMaterializationLimit(query);
    if (!query.length) {
        NSUInteger count = MIN(limit, index.records.count);
        NSMutableArray<FLEXHookEntry *> *entries =
            [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            [entries addObject:index.records[i].entry];
        }
        if (truncated) *truncated = index.records.count > count;
        return entries.copy;
    }

    NSArray<NSString *> *tokens = FLEXSearchTokens(query);
    NSMutableArray<FLEXRuntimeSearchMatch *> *matches = [NSMutableArray array];
    NSUInteger visited = 0;
    BOOL didTruncate = NO;
    for (FLEXRuntimeSearchRecord *record in index.records) {
        if ((visited++ & 127) == 0 && request.cancelled) return nil;
        NSInteger score = FLEXRuntimeSearchScore(record, tokens, query);
        if (score < 0) continue;
        if (matches.count >= limit) {
            didTruncate = YES;
            break;
        }
        FLEXRuntimeSearchMatch *match = [FLEXRuntimeSearchMatch new];
        match.record = record;
        match.score = score;
        [matches addObject:match];
    }
    if (request.cancelled) return nil;

    [matches sortUsingComparator:^NSComparisonResult(
        FLEXRuntimeSearchMatch *left, FLEXRuntimeSearchMatch *right
    ) {
        if (left.score != right.score) {
            return left.score > right.score ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.record.entry.title localizedCaseInsensitiveCompare:
            right.record.entry.title];
    }];

    NSMutableArray<FLEXHookEntry *> *entries =
        [NSMutableArray arrayWithCapacity:matches.count];
    for (FLEXRuntimeSearchMatch *match in matches) {
        [entries addObject:match.record.entry];
    }
    if (truncated) *truncated = didTruncate;
    return entries.copy;
}

static void FLEXSetRuntimeLoading(id controller, BOOL loading, NSString *text) {
    UISearchController *search = nil;
    @try {
        search = [controller valueForKey:@"searchController"];
    } @catch (__unused NSException *exception) {
    }
    search.searchBar.userInteractionEnabled = !loading;

    if (@available(iOS 17.0, *)) {
        UIViewController *viewController = controller;
        if (loading) {
            UIContentUnavailableConfiguration *configuration =
                [UIContentUnavailableConfiguration loadingConfiguration];
            configuration.text = text ?: @"Indexing runtime…";
            configuration.secondaryText =
                @"The full snapshot is built once. Search stays responsive after indexing.";
            viewController.contentUnavailableConfiguration = configuration;
        } else {
            viewController.contentUnavailableConfiguration = nil;
        }
    }
}

@interface FLEXRuntimeBrowserController (AllFLEXingSearchPrivate)
- (void)reloadEntries;
- (void)reloadScan;
- (UIMenu *)scopeMenu;
- (void)updateNavigationStatus;
- (void)updateUnavailableConfiguration;
@end

@implementation FLEXRuntimeBrowserController (AllFLEXingIndexedSearch)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FLEXRuntimeBrowserController.class;
        FLEXExchangeInstanceMethods(cls, @selector(viewDidLoad),
                                     @selector(af_indexed_viewDidLoad));
        FLEXExchangeInstanceMethods(cls, @selector(reloadEntries),
                                     @selector(af_indexed_reloadEntries));
        FLEXExchangeInstanceMethods(cls, @selector(reloadScan),
                                     @selector(af_indexed_reloadScan));
        FLEXExchangeInstanceMethods(cls, @selector(scopeMenu),
                                     @selector(af_indexed_scopeMenu));
        FLEXExchangeInstanceMethods(cls,
                                     @selector(tableView:cellForRowAtIndexPath:),
                                     @selector(af_indexed_tableView:cellForRowAtIndexPath:));

        gFLEXRuntimeSearchRevisionObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:FLEXHookRegistryDidChangeNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
            atomic_fetch_add_explicit(&gFLEXRuntimeSearchRevision,
                                      1,
                                      memory_order_relaxed);
        }];
    });
}

- (void)af_indexed_viewDidLoad {
    (void)FLEXScopeForController(self);
    [self af_indexed_viewDidLoad];
    self.tableView.estimatedRowHeight = 72.0;
}

- (void)af_indexed_reloadScan {
    FLEXRuntimeSearchRequest *request = objc_getAssociatedObject(
        self, kFLEXRuntimeSearchRequestKey);
    request.cancelled = YES;
    objc_setAssociatedObject(self,
                             kFLEXRuntimeSearchIndexKey,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FLEXSetRuntimeLoading(self, YES, @"Scanning and resolving runtime metadata…");
    [self af_indexed_reloadScan];
}

- (void)af_indexed_reloadEntries {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf af_indexed_reloadEntries];
        });
        return;
    }

    BOOL scanning = NO;
    FLEXRuntimeBrowserKind kind = FLEXRuntimeBrowserKindObjectiveC;
    UISearchController *search = nil;
    @try {
        scanning = [[self valueForKey:@"scanning"] boolValue];
        kind = [[self valueForKey:@"kind"] integerValue];
        search = [self valueForKey:@"searchController"];
    } @catch (__unused NSException *exception) {
        [self af_indexed_reloadEntries];
        return;
    }

    FLEXRuntimeSearchRequest *previous = objc_getAssociatedObject(
        self, kFLEXRuntimeSearchRequestKey);
    previous.cancelled = YES;

    if (scanning) {
        FLEXSetRuntimeLoading(self, YES, @"Scanning complete runtime scope…");
        return;
    }

    FLEXRuntimeSearchRequest *request = [FLEXRuntimeSearchRequest new];
    objc_setAssociatedObject(self,
                             kFLEXRuntimeSearchRequestKey,
                             request,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *query = FLEXSearchNormalizedText(search.searchBar.text ?: @"");
    FLEXRuntimeSearchScope *scope = FLEXScopeForController(self);
    unsigned long long revision = atomic_load_explicit(
        &gFLEXRuntimeSearchRevision,
        memory_order_relaxed
    );
    FLEXRuntimeSearchIndex *cached = objc_getAssociatedObject(
        self, kFLEXRuntimeSearchIndexKey);
    BOOL cacheValid = cached && cached.revision == revision &&
        cached.kind == kind && [cached.scopeKey isEqualToString:scope.cacheKey];

    FLEXSetRuntimeLoading(self,
                          !cacheValid,
                          cacheValid ? @"Searching…" : @"Indexing complete runtime snapshot…");

    NSTimeInterval debounce = query.length ? 0.18 : 0.0;
    NSArray<FLEXHookEntry *> *snapshot = FLEXHookRegistry.sharedRegistry.entries;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(debounce * NSEC_PER_SEC)),
                   FLEXRuntimeSearchQueue(), ^{
        if (request.cancelled) return;

        FLEXRuntimeSearchIndex *index = cacheValid ? cached :
            FLEXBuildRuntimeSearchIndex(snapshot, kind, scope, revision, request);
        if (!index || request.cancelled) return;

        BOOL truncated = NO;
        NSArray<FLEXHookEntry *> *results = FLEXMaterializeRuntimeResults(
            index, query, request, &truncated);
        if (!results || request.cancelled) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || request.cancelled ||
                objc_getAssociatedObject(self, kFLEXRuntimeSearchRequestKey) != request) {
                return;
            }
            if (atomic_load_explicit(&gFLEXRuntimeSearchRevision,
                                     memory_order_relaxed) != revision) {
                [self af_indexed_reloadEntries];
                return;
            }

            objc_setAssociatedObject(self,
                                     kFLEXRuntimeSearchIndexKey,
                                     index,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try {
                [self setValue:results forKey:@"filteredEntries"];
            } @catch (__unused NSException *exception) {
                return;
            }
            search.searchBar.userInteractionEnabled = YES;
            search.searchBar.placeholder = [NSString stringWithFormat:
                @"Search %lu indexed %@",
                (unsigned long)index.records.count,
                kind == FLEXRuntimeBrowserKindObjectiveC ? @"methods" : @"symbols"];
            FLEXSetRuntimeLoading(self, NO, nil);
            [self.tableView reloadData];
            [self updateNavigationStatus];
            [self updateUnavailableConfiguration];

            if (truncated && @available(iOS 17.0, *)) {
                UIContentUnavailableConfiguration *configuration =
                    [UIContentUnavailableConfiguration emptyConfiguration];
                configuration.text = [NSString stringWithFormat:
                    @"%lu of %lu indexed results shown",
                    (unsigned long)results.count,
                    (unsigned long)index.records.count];
                configuration.secondaryText = @"Type more characters to refine the full index.";
                // Keep rows visible; this message is intentionally not installed
                // as contentUnavailableConfiguration when results exist.
                (void)configuration;
            }
        });
    });
}

- (UIMenu *)af_indexed_scopeMenu {
    __weak typeof(self) weakSelf = self;
    FLEXRuntimeSearchScope *selected = FLEXScopeForController(self);

    void (^selectScope)(FLEXRuntimeSearchScope *) = ^(FLEXRuntimeSearchScope *scope) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        objc_setAssociatedObject(self,
                                 kFLEXRuntimeSearchScopeKey,
                                 scope,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            [self setValue:@(scope.kind == FLEXRuntimeSearchScopeAllLoadedImages)
                    forKey:@"includeSystemImages"];
            UIBarButtonItem *scopeItem = [self valueForKey:@"scopeItem"];
            scopeItem.title = scope.title;
            scopeItem.menu = [self af_indexed_scopeMenu];
        } @catch (__unused NSException *exception) {
        }
        [self reloadScan];
    };

    NSMutableArray<UIMenuElement *> *primary = [NSMutableArray array];
    FLEXRuntimeSearchScope *host = FLEXDefaultRuntimeScope();
    UIAction *hostAction = [UIAction actionWithTitle:@"All app images"
                                               image:[UIImage systemImageNamed:@"app"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) {
        selectScope(host);
    }];
    hostAction.state = selected.kind == FLEXRuntimeSearchScopeHostImages
        ? UIMenuElementStateOn : UIMenuElementStateOff;
    [primary addObject:hostAction];

    FLEXRuntimeSearchScope *main = [FLEXRuntimeSearchScope new];
    main.kind = FLEXRuntimeSearchScopeMainExecutable;
    main.imagePath = NSBundle.mainBundle.executablePath ?: @"";
    main.title = @"Main executable";
    main.cacheKey = [@"main|" stringByAppendingString:main.imagePath];
    UIAction *mainAction = [UIAction actionWithTitle:@"Main executable"
                                               image:[UIImage systemImageNamed:@"terminal"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) {
        selectScope(main);
    }];
    mainAction.state = selected.kind == FLEXRuntimeSearchScopeMainExecutable
        ? UIMenuElementStateOn : UIMenuElementStateOff;
    [primary addObject:mainAction];

    NSMutableArray<UIMenuElement *> *images = [NSMutableArray array];
    for (NSString *path in FLEXLoadedHostImagePaths()) {
        if ([path isEqualToString:NSBundle.mainBundle.executablePath]) continue;
        FLEXRuntimeSearchScope *imageScope = [FLEXRuntimeSearchScope new];
        imageScope.kind = FLEXRuntimeSearchScopeExactImage;
        imageScope.imagePath = path;
        imageScope.title = path.lastPathComponent;
        imageScope.cacheKey = [@"image|" stringByAppendingString:path];
        UIAction *action = [UIAction actionWithTitle:path.lastPathComponent
                                               image:[UIImage systemImageNamed:@"shippingbox"]
                                          identifier:nil
                                             handler:^(__unused UIAction *menuAction) {
            selectScope(imageScope);
        }];
        action.state = selected.kind == FLEXRuntimeSearchScopeExactImage &&
            [selected.imagePath isEqualToString:path]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [images addObject:action];
    }

    FLEXRuntimeSearchScope *all = [FLEXRuntimeSearchScope new];
    all.kind = FLEXRuntimeSearchScopeAllLoadedImages;
    all.imagePath = @"";
    all.title = @"All loaded";
    all.cacheKey = @"all-loaded";
    UIAction *allAction = [UIAction actionWithTitle:@"All loaded images"
                                              image:[UIImage systemImageNamed:@"square.stack.3d.up"]
                                         identifier:nil
                                            handler:^(__unused UIAction *action) {
        selectScope(all);
    }];
    allAction.state = selected.kind == FLEXRuntimeSearchScopeAllLoadedImages
        ? UIMenuElementStateOn : UIMenuElementStateOff;

    NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
    [children addObjectsFromArray:primary];
    if (images.count) {
        [children addObject:[UIMenu menuWithTitle:@"App frameworks"
                                           image:nil
                                      identifier:nil
                                         options:0
                                        children:images]];
    }
    [children addObject:allAction];
    return [UIMenu menuWithTitle:@"Runtime scope"
                           image:nil
                      identifier:nil
                         options:UIMenuOptionsDisplayInline
                        children:children];
}

- (UITableViewCell *)af_indexed_tableView:(UITableView *)tableView
                    cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self af_indexed_tableView:tableView
                               cellForRowAtIndexPath:indexPath];
    id configuration = cell.contentConfiguration;
    if ([configuration isKindOfClass:UIListContentConfiguration.class]) {
        UIListContentConfiguration *content = [configuration copy];
        content.textProperties.numberOfLines = 0;
        content.textProperties.lineBreakMode = NSLineBreakByCharWrapping;
        content.secondaryTextProperties.numberOfLines = 2;
        content.secondaryTextProperties.lineBreakMode = NSLineBreakByWordWrapping;
        cell.contentConfiguration = content;
    }
    return cell;
}

@end
