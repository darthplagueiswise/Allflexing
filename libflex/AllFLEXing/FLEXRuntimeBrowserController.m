#import "FLEXRuntimeBrowserController.h"

#import "FLEXCHookEngine.h"
#import "FLEXCompactRuntimeUI.h"
#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"
#import "FLEXLiquidGlass.h"
#import "FLEXRuntimeImageSession.h"
#import "FLEXRuntimeScanner.h"
#import "FLEXRuntimeSearchSemantics.h"
#import "FLEXSymbolRebind.h"

#import <objc/runtime.h>
#import <string.h>

const char *FLEXStableRuntimeControllerABIVersion =
    "AllFLEXing single-owner type-safe runtime controller ABI 2";
const char *FLEXRuntimeCrashGuardsABIVersion =
    "AllFLEXing runtime browser crash guards ABI 1";
const char *FLEXRuntimeSearchCompletenessABIVersion =
    "AllFLEXing complete-image substring-index search ABI 1";
const char *FLEXOperationalRuntimeProjectionABIVersion =
    "AllFLEXing operational Objective-C hook-target projection ABI 1";

static const char *FLEXOperationalABIEvidence =
    "objc-type-encoding-operational-profile";
static const char *FLEXOperationalProviderEvidence =
    "MSHookMessageEx-live-provider";
static const char *FLEXRuntimeIndexPhase =
    "Indexing complete image snapshot";
static const void *kFLEXRuntimeBrowserEntryIDKey =
    &kFLEXRuntimeBrowserEntryIDKey;

@interface FLEXRuntimeSearchRequest : NSObject
@property (atomic) BOOL cancelled;
@end
@implementation FLEXRuntimeSearchRequest
@end

@interface FLEXRuntimeSearchIndex : NSObject
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *entries;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *tokensByEntry;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *characters;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *bigrams;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *trigrams;
@end
@implementation FLEXRuntimeSearchIndex
@end

static dispatch_queue_t FLEXRuntimeBrowserSearchQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.allflexing.runtime-browser-search",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_USER_INITIATED,
                0
            )
        );
    });
    return queue;
}

static const char *FLEXRuntimeSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static FLEXHookABI FLEXRuntimeObjectiveCABI(Method method) {
    if (!method) return FLEXHookABIUnknown;
    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (*FLEXRuntimeSkipQualifiers(returnType) != 'B') {
        return FLEXHookABIUnknown;
    }

    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount == 2) return FLEXHookABIObjCBoolNoArguments;
    if (argumentCount != 3) return FLEXHookABIUnknown;

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *code = FLEXRuntimeSkipQualifiers(argumentType);
    if (*code == '@' || *code == '#' || *code == ':') {
        return FLEXHookABIObjCBoolObjectArgument;
    }
    if (strchr("BcCsSiIlLqQ", *code)) {
        return FLEXHookABIObjCBoolIntegerArgument;
    }
    return FLEXHookABIUnknown;
}

static BOOL FLEXRuntimeImageMatches(NSString *requested, const char *rawLoaded) {
    if (!requested.length || !rawLoaded) return NO;
    NSString *loaded = [NSString stringWithUTF8String:rawLoaded];
    if (!loaded.length) return NO;
    NSString *left = requested.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSString *right = loaded.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    return [left isEqualToString:right];
}

static BOOL FLEXRuntimeOperationalObjectiveCEntry(FLEXHookEntry *entry) {
    if (!entry || entry.surface != FLEXHookSurfaceObjectiveC ||
        !FLEXMSHookMessageProviderAvailable()) {
        return NO;
    }

    NSDictionary *locator = [entry.locator isKindOfClass:NSDictionary.class]
        ? entry.locator : @{};
    NSString *className = [locator[@"class"] isKindOfClass:NSString.class]
        ? locator[@"class"] : nil;
    NSString *selectorName = [locator[@"selector"] isKindOfClass:NSString.class]
        ? locator[@"selector"] : nil;
    if (!className.length || !selectorName.length) return NO;

    Class targetClass = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (!targetClass || !selector ||
        !FLEXRuntimeImageMatches(locator[@"image"], class_getImageName(targetClass))) {
        return NO;
    }

    BOOL classMethod = [locator[@"classMethod"] boolValue];
    Method method = classMethod
        ? class_getClassMethod(targetClass, selector)
        : class_getInstanceMethod(targetClass, selector);
    FLEXHookABI abi = FLEXRuntimeObjectiveCABI(method);
    if (abi == FLEXHookABIUnknown) return NO;

    entry.abi = abi;
    entry.backend = FLEXHookBackendObjectiveCElleKit;
    entry.available = YES;
    entry.hookable = FLEXFlag(@"engine.objc_ellekit");
    entry.stale = NO;
    entry.lastError = entry.hookable
        ? nil : @"Objective-C/ElleKit engine is disabled";

    NSMutableDictionary *updated = [locator mutableCopy];
    updated[@"abiEvidence"] =
        [NSString stringWithUTF8String:FLEXOperationalABIEvidence];
    updated[@"backendEvidence"] =
        [NSString stringWithUTF8String:FLEXOperationalProviderEvidence];
    entry.locator = updated.copy;
    return YES;
}

static BOOL FLEXRuntimeOperationalCEntry(FLEXHookEntry *entry) {
    if (!entry || !entry.available || entry.stale) return NO;
    if (entry.surface == FLEXHookSurfaceCImport) {
        NSUInteger bindSlots = [entry.locator[@"bindSlots"] unsignedIntegerValue];
        if (!bindSlots || !FLEXEmbeddedFishhookAvailable()) return NO;
        entry.backend = FLEXHookBackendFishhook;
        entry.hookable = entry.abi != FLEXHookABIUnknown &&
            FLEXFlag(@"engine.fishhook");
        return YES;
    }
    if (entry.surface == FLEXHookSurfaceCInline) {
        NSString *source = [entry.locator[@"source"] isKindOfClass:NSString.class]
            ? entry.locator[@"source"] : @"";
        BOOL imageScoped = [source isEqualToString:@"mach-o-symbol-table"] ||
            [source isEqualToString:@"LC_FUNCTION_STARTS"];
        BOOL addressEvidence =
            [entry.locator[@"address"] unsignedLongLongValue] != 0 ||
            [entry.locator[@"offset"] unsignedLongLongValue] != 0;
        if (!imageScoped || !addressEvidence ||
            !FLEXMSHookFunctionProviderAvailable()) {
            return NO;
        }
        entry.backend = FLEXHookBackendInlineElleKit;
        entry.hookable = entry.abi != FLEXHookABIUnknown &&
            FLEXFlag(@"engine.inline_ellekit");
        return YES;
    }
    return NO;
}

static NSArray<FLEXHookEntry *> *FLEXRuntimeOperationalProjection(
    FLEXRuntimeBrowserKind kind,
    NSArray<FLEXHookEntry *> *entries
) {
    NSMutableArray<FLEXHookEntry *> *result =
        [NSMutableArray arrayWithCapacity:entries.count];
    for (FLEXHookEntry *entry in entries ?: @[]) {
        BOOL accepted = kind == FLEXRuntimeBrowserKindObjectiveC
            ? FLEXRuntimeOperationalObjectiveCEntry(entry)
            : FLEXRuntimeOperationalCEntry(entry);
        if (accepted) [result addObject:entry];
    }
    return [result sortedArrayUsingComparator:^NSComparisonResult(
        FLEXHookEntry *left,
        FLEXHookEntry *right
    ) {
        if (left.surface != right.surface) {
            return left.surface < right.surface
                ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];
}

static void FLEXRuntimeAddSearchValue(NSMutableArray *values, id value) {
    if ([value isKindOfClass:NSString.class] && [value length]) {
        [values addObject:value];
    } else if ([value isKindOfClass:NSNumber.class]) {
        [values addObject:[value stringValue]];
    }
}

static void FLEXRuntimeAddPosting(
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *map,
    NSString *gram,
    NSUInteger index
) {
    if (!gram.length) return;
    NSMutableIndexSet *posting = map[gram];
    if (!posting) {
        posting = [NSMutableIndexSet indexSet];
        map[gram] = posting;
    }
    [posting addIndex:index];
}

static void FLEXRuntimeIndexToken(
    NSString *token,
    NSUInteger index,
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *characters,
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *bigrams,
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *trigrams
) {
    NSMutableSet<NSString *> *seenCharacters = [NSMutableSet set];
    NSMutableSet<NSString *> *seenBigrams = [NSMutableSet set];
    NSMutableSet<NSString *> *seenTrigrams = [NSMutableSet set];
    for (NSUInteger position = 0; position < token.length; position++) {
        NSString *character = [token substringWithRange:NSMakeRange(position, 1)];
        if (![seenCharacters containsObject:character]) {
            [seenCharacters addObject:character];
            FLEXRuntimeAddPosting(characters, character, index);
        }
        if (position + 2 <= token.length) {
            NSString *bigram = [token substringWithRange:NSMakeRange(position, 2)];
            if (![seenBigrams containsObject:bigram]) {
                [seenBigrams addObject:bigram];
                FLEXRuntimeAddPosting(bigrams, bigram, index);
            }
        }
        if (position + 3 <= token.length) {
            NSString *trigram = [token substringWithRange:NSMakeRange(position, 3)];
            if (![seenTrigrams containsObject:trigram]) {
                [seenTrigrams addObject:trigram];
                FLEXRuntimeAddPosting(trigrams, trigram, index);
            }
        }
    }
}

static NSDictionary<NSString *, NSIndexSet *> *FLEXRuntimeFreezePostings(
    NSDictionary<NSString *, NSMutableIndexSet *> *mutable
) {
    NSMutableDictionary<NSString *, NSIndexSet *> *result =
        [NSMutableDictionary dictionaryWithCapacity:mutable.count];
    [mutable enumerateKeysAndObjectsUsingBlock:^(
        NSString *key,
        NSMutableIndexSet *indexes,
        BOOL *stop
    ) {
        (void)stop;
        result[key] = indexes.copy;
    }];
    return result.copy;
}

static FLEXRuntimeSearchIndex *FLEXRuntimeBuildIndex(
    NSArray<FLEXHookEntry *> *entries,
    FLEXRuntimeSearchRequest *request,
    void (^progress)(NSUInteger completed, NSUInteger total)
) {
    NSMutableArray<NSArray<NSString *> *> *tokensByEntry =
        [NSMutableArray arrayWithCapacity:entries.count];
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *characters =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *bigrams =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *trigrams =
        [NSMutableDictionary dictionary];
    NSArray<NSString *> *locatorKeys = @[
        @"symbol", @"class", @"selector", @"encoding", @"image",
        @"imageUUID", @"source", @"backendEvidence", @"abiEvidence",
        @"offset", @"address"
    ];

    for (NSUInteger entryIndex = 0; entryIndex < entries.count; entryIndex++) {
        if ((entryIndex & 127) == 0 && request.cancelled) return nil;
        FLEXHookEntry *entry = entries[entryIndex];
        @autoreleasepool {
            NSMutableArray *values = [NSMutableArray array];
            FLEXRuntimeAddSearchValue(values, entry.title);
            FLEXRuntimeAddSearchValue(values, entry.detail);
            FLEXRuntimeAddSearchValue(values, entry.imageName);
            FLEXRuntimeAddSearchValue(values, entry.identifier);
            for (NSString *key in locatorKeys) {
                FLEXRuntimeAddSearchValue(values, entry.locator[key]);
            }
            NSArray<NSString *> *tokens =
                FLEXRuntimeSearchSemanticTokensForValues(values);
            [tokensByEntry addObject:tokens];
            for (NSString *token in [NSSet setWithArray:tokens]) {
                FLEXRuntimeIndexToken(
                    token,
                    entryIndex,
                    characters,
                    bigrams,
                    trigrams
                );
            }
        }
        if (progress && ((entryIndex & 1023) == 0 ||
                         entryIndex + 1 == entries.count)) {
            progress(entryIndex + 1, entries.count);
        }
    }
    if (request.cancelled) return nil;

    FLEXRuntimeSearchIndex *index = [FLEXRuntimeSearchIndex new];
    index.entries = entries;
    index.tokensByEntry = tokensByEntry.copy;
    index.characters = FLEXRuntimeFreezePostings(characters);
    index.bigrams = FLEXRuntimeFreezePostings(bigrams);
    index.trigrams = FLEXRuntimeFreezePostings(trigrams);
    return index;
}

static NSIndexSet *FLEXRuntimePostingForToken(FLEXRuntimeSearchIndex *index,
                                              NSString *token) {
    if (token.length == 1) return index.characters[token];
    if (token.length == 2) return index.bigrams[token];
    NSMutableIndexSet *candidates = nil;
    for (NSUInteger position = 0; position + 3 <= token.length; position++) {
        NSString *trigram = [token substringWithRange:NSMakeRange(position, 3)];
        NSIndexSet *posting = index.trigrams[trigram];
        if (!posting.count) return nil;
        if (!candidates) candidates = posting.mutableCopy;
        else [candidates intersectIndexes:posting];
        if (!candidates.count) return nil;
    }
    return candidates.copy;
}

static BOOL FLEXRuntimeEntryMatchesQuery(FLEXRuntimeSearchIndex *index,
                                         NSUInteger entryIndex,
                                         NSArray<NSString *> *queryTokens) {
    if (entryIndex >= index.tokensByEntry.count) return NO;
    NSArray<NSString *> *candidateTokens = index.tokensByEntry[entryIndex];
    for (NSString *query in queryTokens) {
        BOOL matched = NO;
        for (NSString *candidate in candidateTokens) {
            if ([candidate containsString:query]) {
                matched = YES;
                break;
            }
        }
        if (!matched) return NO;
    }
    return YES;
}

static NSArray<FLEXHookEntry *> *FLEXRuntimeQueryIndex(
    FLEXRuntimeSearchIndex *index,
    NSString *text,
    FLEXRuntimeSearchRequest *request
) {
    NSArray<NSString *> *queryTokens = FLEXRuntimeSearchQueryTokens(text);
    if (!queryTokens.count) return index.entries;

    NSMutableIndexSet *candidates = nil;
    for (NSString *token in queryTokens) {
        if (request.cancelled) return nil;
        NSIndexSet *posting = FLEXRuntimePostingForToken(index, token);
        if (!posting.count) return @[];
        if (!candidates) candidates = posting.mutableCopy;
        else [candidates intersectIndexes:posting];
        if (!candidates.count) return @[];
    }

    NSMutableArray<FLEXHookEntry *> *results =
        [NSMutableArray arrayWithCapacity:candidates.count];
    [candidates enumerateIndexesUsingBlock:^(NSUInteger entryIndex, BOOL *stop) {
        if (request.cancelled) {
            *stop = YES;
            return;
        }
        if (FLEXRuntimeEntryMatchesQuery(index, entryIndex, queryTokens)) {
            [results addObject:index.entries[entryIndex]];
        }
    }];
    return request.cancelled ? nil : results.copy;
}

@interface FLEXRuntimeBrowserController () <UISearchResultsUpdating>
@property (nonatomic) FLEXRuntimeBrowserKind kind;
@property (nonatomic) BOOL scanning;
@property (nonatomic) BOOL indexing;
@property (nonatomic) BOOL initialScanStarted;
@property (nonatomic) UISearchController *searchController;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *allEntries;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *filteredEntries;
@property (nonatomic, copy) NSArray<FLEXRuntimeEntryGroup *> *groups;
@property (nonatomic) FLEXRuntimeSearchIndex *searchIndex;
@property (nonatomic) FLEXRuntimeSearchRequest *searchRequest;
@property (nonatomic) FLEXRuntimeImageDescriptor *selectedImage;
@property (nonatomic) FLEXRuntimeImageSession *session;
@property (nonatomic) FLEXRuntimeImageSnapshot *snapshot;
@property (nonatomic) NSUInteger searchGeneration;
@property (nonatomic) UIBarButtonItem *scopeItem;
@property (nonatomic) UIBarButtonItem *reloadItem;
@property (nonatomic) UIBarButtonItem *progressItem;
@property (nonatomic) UIProgressView *progressView;
@property (nonatomic) UIActivityIndicatorView *progressSpinner;
@property (nonatomic, copy) NSString *progressPhase;
@property (nonatomic) NSUInteger progressCompleted;
@property (nonatomic) NSUInteger progressTotal;
@end

@implementation FLEXRuntimeBrowserController

- (instancetype)initWithKind:(FLEXRuntimeBrowserKind)kind {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _kind = kind;
        _allEntries = @[];
        _filteredEntries = @[];
        _groups = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.kind == FLEXRuntimeBrowserKindObjectiveC
        ? @"Objective-C Runtime" : @"C Runtime";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    FLEXConfigureCompactRuntimeTable(self.tableView);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64.0;

    self.searchController = [[UISearchController alloc]
        initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"Scan an image before searching";
    self.searchController.searchBar.userInteractionEnabled = NO;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    [self setContentScrollView:self.tableView
                      forEdge:(NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom)];

    self.reloadItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                             target:self
                             action:@selector(reloadScan)];
    self.scopeItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Image"
                 menu:[self scopeMenu]];
    [self buildProgressItem];
    [self installNavigationItemsScanning:NO];

    self.selectedImage = FLEXRuntimeImageSession.loadedAppImages.firstObject;
    [self updateScopeItem];

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

    [FLEXLiquidGlass applyToViewController:self];
    [self updateUnavailableConfigurationWithError:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshCanonicalEntries];
    [FLEXLiquidGlass applyToViewController:self];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.initialScanStarted || !self.selectedImage) return;
    self.initialScanStarted = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.viewIfLoaded.window && !self.scanning && !self.snapshot) {
            [self reloadScan];
        }
    });
}

- (void)dealloc {
    self.searchRequest.cancelled = YES;
    [self.session cancel];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)buildProgressItem {
    self.progressSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.progressView = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progress = 0;
    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[self.progressSpinner, self.progressView]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8.0;
    [self.progressView.widthAnchor constraintEqualToConstant:72.0].active = YES;
    self.progressItem = [[UIBarButtonItem alloc] initWithCustomView:stack];
    self.progressItem.accessibilityLabel = @"Runtime image scan progress";
}

- (void)installNavigationItemsScanning:(BOOL)scanning {
    UIBarButtonItem *separator = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace
                             target:nil
                             action:nil];
    separator.width = 8.0;
    if (@available(iOS 26.0, *)) separator.hidesSharedBackground = YES;
    self.navigationItem.rightBarButtonItems = scanning
        ? @[self.progressItem, separator, self.scopeItem]
        : @[self.reloadItem, separator, self.scopeItem];
}

- (void)updateScopeItem {
    self.scopeItem.title = self.selectedImage.displayName ?: @"Image";
    self.scopeItem.menu = [self scopeMenu];
}

- (UIMenu *)scopeMenu {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
    for (FLEXRuntimeImageDescriptor *image in
         FLEXRuntimeImageSession.loadedAppImages) {
        NSString *subtitle = image.mainExecutable
            ? @"Main executable"
            : [image.path stringByAbbreviatingWithTildeInPath];
        UIAction *action = [UIAction actionWithTitle:image.displayName
                                           subtitle:subtitle
                                              image:[UIImage systemImageNamed:
                                                  image.mainExecutable
                                                    ? @"terminal"
                                                    : @"shippingbox"]
                                         identifier:nil
                                            handler:^(__unused UIAction *menuAction) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || [self.selectedImage.path isEqualToString:image.path]) return;
            self.selectedImage = image;
            [self updateScopeItem];
            [self reloadScan];
        }];
        action.state = [self.selectedImage.path isEqualToString:image.path]
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    if (!actions.count) {
        UIAction *empty = [UIAction actionWithTitle:@"No app image is loaded"
                                             image:[UIImage systemImageNamed:
                                                 @"exclamationmark.triangle"]
                                        identifier:nil
                                           handler:^(__unused UIAction *action) {}];
        empty.attributes = UIMenuElementAttributesDisabled;
        [actions addObject:empty];
    }
    return [UIMenu menuWithTitle:@"Runtime image"
                           image:nil
                      identifier:nil
                         options:UIMenuOptionsDisplayInline
                        children:actions];
}

- (void)runtimeImagesChanged:(NSNotification *)notification {
    (void)notification;
    NSArray<FLEXRuntimeImageDescriptor *> *images =
        FLEXRuntimeImageSession.loadedAppImages;
    FLEXRuntimeImageDescriptor *matching = nil;
    for (FLEXRuntimeImageDescriptor *image in images) {
        BOOL pathMatches = [image.path isEqualToString:self.selectedImage.path];
        BOOL uuidMatches = !self.selectedImage.uuid.length || !image.uuid.length ||
            [image.uuid caseInsensitiveCompare:self.selectedImage.uuid] == NSOrderedSame;
        if (pathMatches && uuidMatches) {
            matching = image;
            break;
        }
    }
    self.selectedImage = matching ?: images.firstObject;
    [self updateScopeItem];
}

- (void)registryChanged:(NSNotification *)notification {
    (void)notification;
    [self refreshCanonicalEntries];
}

- (void)refreshCanonicalEntries {
    if (!self.searchIndex.entries.count) return;
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    NSMutableArray<FLEXHookEntry *> *canonical =
        [NSMutableArray arrayWithCapacity:self.searchIndex.entries.count];
    for (FLEXHookEntry *entry in self.searchIndex.entries) {
        [canonical addObject:[registry entryForIdentifier:entry.identifier] ?: entry];
    }
    self.searchIndex.entries = canonical.copy;
    self.allEntries = canonical.copy;
    [self scheduleSearchForText:self.searchController.searchBar.text ?: @""
                       immediate:YES];
}

- (void)reloadScan {
    if (!self.selectedImage) return;
    self.searchRequest.cancelled = YES;
    [self.session cancel];
    self.searchGeneration++;
    self.scanning = YES;
    self.indexing = NO;
    self.snapshot = nil;
    self.searchIndex = nil;
    self.allEntries = @[];
    self.filteredEntries = @[];
    self.groups = @[];
    self.searchController.searchBar.text = @"";
    self.searchController.searchBar.userInteractionEnabled = NO;
    self.reloadItem.enabled = NO;
    self.scopeItem.enabled = NO;
    self.progressPhase = @"Opening selected image";
    self.progressCompleted = 0;
    self.progressTotal = 0;
    self.progressView.progress = 0;
    [self.progressSpinner startAnimating];
    [self installNavigationItemsScanning:YES];
    [self.tableView reloadData];
    [self updateNavigationStatus];
    [self updateUnavailableConfigurationWithError:nil];

    self.session = [[FLEXRuntimeImageSession alloc]
        initWithImage:self.selectedImage];
    __weak typeof(self) weakSelf = self;
    [self.session scanKind:self.kind
                  progress:^(NSString *phase, NSUInteger completed, NSUInteger total) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.scanning) return;
        self.progressPhase = phase;
        self.progressCompleted = completed;
        self.progressTotal = total;
        self.progressView.progress = total
            ? MIN(1.0, (float)completed / (float)total)
            : 0.05;
        [self updateNavigationStatus];
        [self updateUnavailableConfigurationWithError:nil];
    } completion:^(FLEXRuntimeImageSnapshot *snapshot, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.scanning = NO;
        [self.progressSpinner stopAnimating];
        self.reloadItem.enabled = YES;
        self.scopeItem.enabled = YES;
        [self installNavigationItemsScanning:NO];
        if (!snapshot || error) {
            self.allEntries = @[];
            self.filteredEntries = @[];
            self.groups = @[];
            [self.tableView reloadData];
            [self updateNavigationStatus];
            [self updateUnavailableConfigurationWithError:error];
            return;
        }

        self.snapshot = snapshot;
        NSArray<FLEXHookEntry *> *projected =
            FLEXRuntimeOperationalProjection(self.kind, snapshot.entries);
        NSMutableArray<FLEXHookEntry *> *entries =
            [NSMutableArray arrayWithCapacity:projected.count];
        FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
        for (FLEXHookEntry *entry in projected) {
            @autoreleasepool {
                FLEXHookEntry *resolved = [registry upsertDiscoveredEntry:entry];
                [entries addObject:resolved ?: entry];
            }
        }
        [self buildSearchIndexForEntries:entries.copy];
    }];
}

- (void)buildSearchIndexForEntries:(NSArray<FLEXHookEntry *> *)entries {
    self.searchRequest.cancelled = YES;
    FLEXRuntimeSearchRequest *request = [FLEXRuntimeSearchRequest new];
    self.searchRequest = request;
    NSUInteger generation = ++self.searchGeneration;
    NSArray<FLEXHookEntry *> *projected = entries.copy ?: @[];

    self.indexing = YES;
    self.progressPhase = [NSString stringWithUTF8String:FLEXRuntimeIndexPhase];
    self.progressCompleted = 0;
    self.progressTotal = projected.count;
    self.progressView.progress = 0;
    self.searchController.searchBar.userInteractionEnabled = NO;
    [self.progressSpinner startAnimating];
    [self installNavigationItemsScanning:YES];
    [self updateNavigationStatus];
    [self updateUnavailableConfigurationWithError:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(FLEXRuntimeBrowserSearchQueue(), ^{
        FLEXRuntimeSearchIndex *index = FLEXRuntimeBuildIndex(
            projected,
            request,
            ^(NSUInteger completed, NSUInteger total) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) self = weakSelf;
                    if (!self || request.cancelled ||
                        generation != self.searchGeneration) return;
                    self.progressCompleted = completed;
                    self.progressTotal = total;
                    self.progressView.progress = total
                        ? (float)completed / (float)total : 1.0;
                    [self updateNavigationStatus];
                });
            }
        );
        if (!index || request.cancelled) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || request.cancelled ||
                generation != self.searchGeneration) return;
            self.searchIndex = index;
            self.allEntries = index.entries;
            self.filteredEntries = index.entries;
            self.groups = FLEXRuntimeGroupEntries(index.entries);
            self.indexing = NO;
            [self.progressSpinner stopAnimating];
            [self installNavigationItemsScanning:NO];
            self.searchController.searchBar.userInteractionEnabled = YES;
            self.searchController.searchBar.placeholder = [NSString stringWithFormat:
                @"Search %lu supported target(s)",
                (unsigned long)index.entries.count];
            [self.tableView reloadData];
            [self updateNavigationStatusWithTotalMatches:index.entries.count];
            [self updateUnavailableConfigurationWithError:nil];
        });
    });
}

- (void)reloadEntries {
    [self scheduleSearchForText:self.searchController.searchBar.text ?: @""
                       immediate:YES];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)controller {
    [self scheduleSearchForText:controller.searchBar.text ?: @""
                       immediate:NO];
}

- (void)scheduleSearchForText:(NSString *)text immediate:(BOOL)immediate {
    FLEXRuntimeSearchIndex *index = self.searchIndex;
    if (self.scanning || self.indexing || !index) return;

    self.searchRequest.cancelled = YES;
    FLEXRuntimeSearchRequest *request = [FLEXRuntimeSearchRequest new];
    self.searchRequest = request;
    NSUInteger generation = ++self.searchGeneration;
    NSString *query = text.copy ?: @"";
    NSTimeInterval delay = immediate ? 0.0 : 0.10;
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        FLEXRuntimeBrowserSearchQueue(),
        ^{
            NSArray<FLEXHookEntry *> *results =
                FLEXRuntimeQueryIndex(index, query, request);
            if (!results || request.cancelled) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || request.cancelled ||
                    generation != self.searchGeneration) return;
                self.filteredEntries = results;
                self.groups = FLEXRuntimeGroupEntries(results);
                [self.tableView reloadData];
                [self updateNavigationStatusWithTotalMatches:results.count];
                [self updateUnavailableConfigurationWithError:nil];
            });
        }
    );
}

- (void)addManualSymbol:(UIBarButtonItem *)sender {
    (void)sender;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Add symbol in selected image"
                         message:self.selectedImage.displayName
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Exact symbol name";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Resolve"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *symbol = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!symbol.length) return;
        FLEXHookEntry *entry = [FLEXRuntimeScanner manualCEntryForSymbol:symbol
                                                               imageName:self.selectedImage.path];
        [FLEXCHookEngine refreshAvailabilityForEntry:entry];
        entry.userConfigured = YES;
        FLEXHookEntry *canonical = [FLEXHookRegistry.sharedRegistry
            upsertDiscoveredEntry:entry];
        FLEXHookEntryDetailController *detail =
            [[FLEXHookEntryDetailController alloc]
                initWithEntry:canonical ?: entry];
        [self.navigationController pushViewController:detail animated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.groups.count;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return section >= 0 && section < (NSInteger)self.groups.count
        ? self.groups[(NSUInteger)section].entries.count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"AllFLEXingNativeRuntimeCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
            reuseIdentifier:identifier];
    }

    FLEXRuntimeEntryGroup *group = self.groups[indexPath.section];
    FLEXHookEntry *entry = group.entries[indexPath.row];
    NSString *icon = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0
            ? @"checkmark.circle.fill"
            : @"bolt.circle.fill")
        : (entry.hookable ? @"circle.dashed" : @"eye");
    UIColor *tint = entry.effectiveEnabled
        ? (entry.overrideHitCount > 0
            ? UIColor.systemGreenColor
            : UIColor.systemBlueColor)
        : (entry.hookable ? self.view.tintColor : UIColor.secondaryLabelColor);
    FLEXConfigureCompactRuntimeContent(
        cell,
        FLEXRuntimeMemberTitleForEntry(entry),
        FLEXRuntimeCompactSummaryForEntry(entry),
        icon,
        tint
    );
    FLEXStyleCompactRuntimeCell(
        cell,
        FLEXCompactPositionForRow(indexPath.row, group.entries.count)
    );

    UISwitch *toggle = [UISwitch new];
    toggle.on = entry.pendingEnabled;
    toggle.enabled = (entry.available && entry.hookable) || entry.pendingEnabled;
    toggle.accessibilityLabel = [NSString stringWithFormat:
        @"Stage runtime hook for %@", entry.title];
    toggle.accessibilityValue = entry.statusSummary;
    objc_setAssociatedObject(
        toggle,
        kFLEXRuntimeBrowserEntryIDKey,
        entry.identifier,
        OBJC_ASSOCIATION_COPY_NONATOMIC
    );
    [toggle addTarget:self
               action:@selector(toggleChanged:)
     forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section >= 0 && section < (NSInteger)self.groups.count
        ? self.groups[(NSUInteger)section].title : nil;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == (NSInteger)self.groups.count - 1) {
        return @"Switches stage changes only. Open Hook Center or the target detail and press Apply to install them.";
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView
 didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FLEXHookEntry *entry = self.groups[indexPath.section].entries[indexPath.row];
    FLEXHookEntryDetailController *detail =
        [[FLEXHookEntryDetailController alloc] initWithEntry:entry];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)toggleChanged:(UISwitch *)toggle {
    NSString *identifier = objc_getAssociatedObject(
        toggle,
        kFLEXRuntimeBrowserEntryIDKey
    );
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    BOOL requested = toggle.isOn;
    FLEXHookEntry *entry = [registry entryForIdentifier:identifier];
    if (requested && (!entry || !entry.userConfigured)) {
        [registry stageForceValue:YES forEntryIdentifier:identifier];
    }
    [registry stageEnabled:requested forEntryIdentifier:identifier];
    entry = [registry entryForIdentifier:identifier];
    BOOL accepted = entry && entry.pendingEnabled == requested;
    [toggle setOn:accepted ? requested : !requested animated:YES];
    if (accepted) {
        [UISelectionFeedbackGenerator.new selectionChanged];
    } else {
        [UINotificationFeedbackGenerator.new
            notificationOccurred:UINotificationFeedbackTypeError];
    }
    [self refreshCanonicalEntries];
}

- (void)updateNavigationStatus {
    [self updateNavigationStatusWithTotalMatches:self.filteredEntries.count];
}

- (void)updateNavigationStatusWithTotalMatches:(NSUInteger)totalMatches {
    NSString *status = nil;
    if (self.scanning || self.indexing) {
        status = self.progressTotal
            ? [NSString stringWithFormat:@"%@ · %lu/%lu",
                self.progressPhase ?: @"Working",
                (unsigned long)self.progressCompleted,
                (unsigned long)self.progressTotal]
            : (self.progressPhase ?: @"Working…");
    } else if (self.snapshot) {
        status = [NSString stringWithFormat:@"%@ · %lu indexed · %lu shown",
            self.selectedImage.displayName,
            (unsigned long)self.searchIndex.entries.count,
            (unsigned long)totalMatches];
    } else {
        status = @"Select an image and scan";
    }
    if (@available(iOS 26.0, *)) self.navigationItem.subtitle = status;
}

- (void)updateUnavailableConfigurationWithError:(NSError *)error {
    if (@available(iOS 17.0, *)) {
        if (self.filteredEntries.count) {
            self.contentUnavailableConfiguration = nil;
            return;
        }
        UIContentUnavailableConfiguration *configuration = nil;
        if (self.scanning || self.indexing) {
            configuration = [UIContentUnavailableConfiguration loadingConfiguration];
            configuration.text = self.progressPhase ?: @"Scanning selected image";
            configuration.secondaryText =
                @"Mach-O, Objective-C metadata, symbols, function starts and search evidence are resolved off the main thread.";
        } else if (error) {
            configuration = [UIContentUnavailableConfiguration emptyConfiguration];
            configuration.image = [UIImage systemImageNamed:
                @"exclamationmark.triangle"];
            configuration.text = @"Runtime scan failed";
            configuration.secondaryText = error.localizedDescription;
        } else if (self.searchController.searchBar.text.length) {
            configuration = [UIContentUnavailableConfiguration searchConfiguration];
            configuration.text = @"No result in the selected image";
            configuration.secondaryText =
                @"The complete selected-image index was searched.";
        } else {
            configuration = [UIContentUnavailableConfiguration emptyConfiguration];
            configuration.text = self.selectedImage
                ? @"No supported runtime entries"
                : @"No app image loaded";
            configuration.secondaryText = self.selectedImage
                ? @"Refresh the selected image or choose another framework."
                : @"Load the app executable or an embedded framework first.";
        }
        self.contentUnavailableConfiguration = configuration;
    }
}

@end
