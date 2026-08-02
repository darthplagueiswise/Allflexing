#import "FLEXRuntimeBrowserController.h"

#import "FLEXHookRegistry.h"

#import <objc/runtime.h>
#import <stdatomic.h>

const char *FLEXRuntimeSearchABIVersion =
    "AllFLEXing async indexed cancellable search ABI 3";

static const void *kFLEXRuntimeSearchRequestKey = &kFLEXRuntimeSearchRequestKey;
static const void *kFLEXRuntimeSearchIndexKey = &kFLEXRuntimeSearchIndexKey;
static atomic_ullong gFLEXRuntimeSearchRevision = 1;
static id gFLEXRuntimeSearchRevisionObserver;

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
    NSCharacterSet *uppercaseLetters = NSCharacterSet.uppercaseLetterCharacterSet;
    NSCharacterSet *lowercaseLetters = NSCharacterSet.lowercaseLetterCharacterSet;

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

        BOOL uppercase = [uppercaseLetters characterIsMember:current];
        if (uppercase && index > 0 && spaced.length &&
            [spaced characterAtIndex:spaced.length - 1] != ' ') {
            unichar previous = [source characterAtIndex:index - 1];
            BOOL previousLowerOrDigit =
                [lowercaseLetters characterIsMember:previous] ||
                [digits characterIsMember:previous];
            BOOL acronymBoundary = NO;
            if (index + 1 < source.length) {
                unichar next = [source characterAtIndex:index + 1];
                acronymBoundary = [uppercaseLetters characterIsMember:previous] &&
                    [lowercaseLetters characterIsMember:next];
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

static NSArray<NSString *> *FLEXSearchTokensFromNormalized(NSString *normalized) {
    return normalized.length
        ? [normalized componentsSeparatedByString:@" "]
        : @[];
}

static BOOL FLEXRuntimeSurfaceMatches(FLEXHookEntry *entry,
                                      FLEXRuntimeBrowserKind kind) {
    return kind == FLEXRuntimeBrowserKindObjectiveC
        ? entry.surface == FLEXHookSurfaceObjectiveC
        : (entry.surface == FLEXHookSurfaceCImport ||
           entry.surface == FLEXHookSurfaceCInline);
}

static void FLEXAppendSearchField(NSMutableString *raw, id value) {
    if ([value isKindOfClass:NSString.class]) {
        NSString *string = value;
        if (string.length) {
            [raw appendString:string];
            [raw appendString:@" "];
        }
    } else if ([value isKindOfClass:NSNumber.class]) {
        [raw appendString:[value stringValue]];
        [raw appendString:@" "];
    }
}

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

static FLEXRuntimeSearchIndex *FLEXBuildRuntimeSearchIndex(
    NSArray<FLEXHookEntry *> *entries,
    FLEXRuntimeBrowserKind kind,
    unsigned long long revision,
    FLEXRuntimeSearchRequest *request
) {
    NSMutableArray<FLEXRuntimeSearchRecord *> *records =
        [NSMutableArray arrayWithCapacity:entries.count];
    NSArray<NSString *> *locatorKeys = @[
        @"symbol", @"class", @"selector", @"encoding", @"image", @"imageUUID"
    ];

    NSUInteger visited = 0;
    for (FLEXHookEntry *entry in entries) {
        if ((visited++ & 127) == 0 && request.cancelled) {
            return nil;
        }
        if (!FLEXRuntimeSurfaceMatches(entry, kind)) {
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
        NSRange match = [text rangeOfString:token
                                   options:0
                                     range:remaining];
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
                                        NSArray<NSString *> *queryTokens,
                                        NSString *normalizedQuery) {
    for (NSString *token in queryTokens) {
        if (!FLEXTextContainsSearchToken(record.searchText, token)) {
            return -1;
        }
    }

    NSInteger score = 0;
    if ([record.title isEqualToString:normalizedQuery]) {
        score += 500;
    } else if ([record.title hasPrefix:normalizedQuery]) {
        score += 320;
    } else if ([record.title containsString:normalizedQuery]) {
        score += 180;
    }
    if ([record.identifier containsString:normalizedQuery]) {
        score += 110;
    }
    if ([record.image containsString:normalizedQuery]) {
        score += 60;
    }

    for (NSString *token in queryTokens) {
        if ([record.title hasPrefix:token]) {
            score += 45;
        } else if ([record.title containsString:token]) {
            score += 20;
        }
    }
    return score;
}

static NSUInteger FLEXRuntimeSearchResultLimit(NSString *normalizedQuery) {
    NSString *compact = [normalizedQuery stringByReplacingOccurrencesOfString:@" "
                                                                    withString:@""];
    if (compact.length <= 1) {
        return 256;
    }
    if (compact.length == 2) {
        return 1024;
    }
    return 4096;
}

static NSArray<FLEXHookEntry *> *FLEXSearchRuntimeIndex(
    FLEXRuntimeSearchIndex *index,
    NSString *normalizedQuery,
    FLEXRuntimeSearchRequest *request,
    BOOL *truncated
) {
    NSArray<NSString *> *queryTokens =
        FLEXSearchTokensFromNormalized(normalizedQuery);
    NSUInteger limit = FLEXRuntimeSearchResultLimit(normalizedQuery);
    NSMutableArray<FLEXRuntimeSearchMatch *> *matches =
        [NSMutableArray arrayWithCapacity:MIN(limit, index.records.count)];

    NSUInteger visited = 0;
    BOOL didTruncate = NO;
    for (FLEXRuntimeSearchRecord *record in index.records) {
        if ((visited++ & 127) == 0 && request.cancelled) {
            return nil;
        }
        NSInteger score = FLEXRuntimeSearchScore(record, queryTokens, normalizedQuery);
        if (score < 0) {
            continue;
        }
        if (matches.count >= limit) {
            didTruncate = YES;
            break;
        }
        FLEXRuntimeSearchMatch *match = [FLEXRuntimeSearchMatch new];
        match.record = record;
        match.score = score;
        [matches addObject:match];
    }

    if (request.cancelled) {
        return nil;
    }
    [matches sortUsingComparator:^NSComparisonResult(
        FLEXRuntimeSearchMatch *left,
        FLEXRuntimeSearchMatch *right
    ) {
        if (left.score != right.score) {
            return left.score > right.score
                ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.record.entry.title
            localizedCaseInsensitiveCompare:right.record.entry.title];
    }];

    NSMutableArray<FLEXHookEntry *> *entries =
        [NSMutableArray arrayWithCapacity:matches.count];
    for (FLEXRuntimeSearchMatch *match in matches) {
        [entries addObject:match.record.entry];
    }
    if (truncated) {
        *truncated = didTruncate;
    }
    return entries.copy;
}

static UIFont *FLEXScaledRuntimeFont(CGFloat pointSize,
                                     UIFontWeight weight,
                                     UIFontTextStyle style,
                                     CGFloat maximum) {
    UIFont *base = [UIFont systemFontOfSize:pointSize weight:weight];
    return [[UIFontMetrics metricsForTextStyle:style]
        scaledFontForFont:base maximumPointSize:maximum];
}

@interface FLEXRuntimeBrowserController (AllFLEXingSearchPrivate)
- (void)updateNavigationStatus;
- (void)updateUnavailableConfiguration;
@end

@implementation FLEXRuntimeBrowserController (AllFLEXingTokenSearch)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FLEXRuntimeBrowserController.class;
        FLEXExchangeInstanceMethods(cls, @selector(viewDidLoad),
                                     @selector(af_search_viewDidLoad));
        FLEXExchangeInstanceMethods(cls, NSSelectorFromString(@"reloadEntries"),
                                     @selector(af_tokenizedReloadEntries));
        FLEXExchangeInstanceMethods(
            cls,
            @selector(tableView:cellForRowAtIndexPath:),
            @selector(af_search_tableView:cellForRowAtIndexPath:)
        );

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

- (void)af_search_viewDidLoad {
    [self af_search_viewDidLoad];
    self.tableView.estimatedRowHeight = 56.0;
    @try {
        UISearchController *search = [self valueForKey:@"searchController"];
        search.searchBar.searchTextField.font = FLEXScaledRuntimeFont(
            13.5,
            UIFontWeightRegular,
            UIFontTextStyleBody,
            16.0
        );
    } @catch (__unused NSException *exception) {
    }
}

- (void)af_tokenizedReloadEntries {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf af_tokenizedReloadEntries];
        });
        return;
    }

    FLEXRuntimeBrowserKind kind = FLEXRuntimeBrowserKindObjectiveC;
    UISearchController *search = nil;
    @try {
        kind = [[self valueForKey:@"kind"] integerValue];
        search = [self valueForKey:@"searchController"];
    } @catch (__unused NSException *exception) {
        [self af_tokenizedReloadEntries];
        return;
    }

    NSString *query = search.searchBar.text ?: @"";
    NSString *normalizedQuery = FLEXSearchNormalizedText(query);
    unsigned long long revision = atomic_load_explicit(
        &gFLEXRuntimeSearchRevision,
        memory_order_relaxed
    );

    FLEXRuntimeSearchRequest *previous = objc_getAssociatedObject(
        self, kFLEXRuntimeSearchRequestKey);
    previous.cancelled = YES;

    FLEXRuntimeSearchRequest *request = [FLEXRuntimeSearchRequest new];
    objc_setAssociatedObject(self,
                             kFLEXRuntimeSearchRequestKey,
                             request,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    FLEXRuntimeSearchIndex *cachedIndex = objc_getAssociatedObject(
        self, kFLEXRuntimeSearchIndexKey);
    BOOL cacheValid = cachedIndex &&
        cachedIndex.revision == revision &&
        cachedIndex.kind == kind;

    if (normalizedQuery.length && @available(iOS 26.0, *)) {
        self.navigationItem.subtitle = cacheValid
            ? @"Searching…"
            : @"Indexing runtime symbols…";
    }

    NSTimeInterval debounce = normalizedQuery.length ? 0.22 : 0.0;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(debounce * NSEC_PER_SEC)),
                   FLEXRuntimeSearchQueue(), ^{
        if (request.cancelled) {
            return;
        }

        FLEXRuntimeSearchIndex *index = cacheValid ? cachedIndex : nil;
        NSArray<FLEXHookEntry *> *results = nil;
        BOOL truncated = NO;

        if (!normalizedQuery.length) {
            NSArray<FLEXHookEntry *> *snapshot =
                FLEXHookRegistry.sharedRegistry.entries;
            NSMutableArray<FLEXHookEntry *> *visible =
                [NSMutableArray arrayWithCapacity:snapshot.count];
            NSUInteger visited = 0;
            for (FLEXHookEntry *entry in snapshot) {
                if ((visited++ & 255) == 0 && request.cancelled) {
                    return;
                }
                if (FLEXRuntimeSurfaceMatches(entry, kind)) {
                    [visible addObject:entry];
                }
            }
            results = visible.copy;
        } else {
            if (!index) {
                NSArray<FLEXHookEntry *> *snapshot =
                    FLEXHookRegistry.sharedRegistry.entries;
                index = FLEXBuildRuntimeSearchIndex(
                    snapshot,
                    kind,
                    revision,
                    request
                );
                if (!index || request.cancelled) {
                    return;
                }
            }
            results = FLEXSearchRuntimeIndex(
                index,
                normalizedQuery,
                request,
                &truncated
            );
            if (!results || request.cancelled) {
                return;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || request.cancelled ||
                objc_getAssociatedObject(self, kFLEXRuntimeSearchRequestKey) != request) {
                return;
            }

            unsigned long long currentRevision = atomic_load_explicit(
                &gFLEXRuntimeSearchRevision,
                memory_order_relaxed
            );
            if (currentRevision != revision) {
                [self af_tokenizedReloadEntries];
                return;
            }

            if (index) {
                objc_setAssociatedObject(self,
                                         kFLEXRuntimeSearchIndexKey,
                                         index,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            @try {
                [self setValue:results forKey:@"filteredEntries"];
            } @catch (__unused NSException *exception) {
                [self af_tokenizedReloadEntries];
                return;
            }

            [self.tableView reloadData];
            [self updateNavigationStatus];
            [self updateUnavailableConfiguration];
            if (truncated && @available(iOS 26.0, *)) {
                self.navigationItem.subtitle = [NSString stringWithFormat:
                    @"Showing first %lu matches · type more",
                    (unsigned long)results.count];
            }
        });
    });
}

- (UITableViewCell *)af_search_tableView:(UITableView *)tableView
                   cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self af_search_tableView:tableView
                               cellForRowAtIndexPath:indexPath];
    id configuration = cell.contentConfiguration;
    if ([configuration isKindOfClass:UIListContentConfiguration.class]) {
        UIListContentConfiguration *content = [configuration copy];
        content.textProperties.font = FLEXScaledRuntimeFont(
            13.5,
            UIFontWeightSemibold,
            UIFontTextStyleBody,
            17.0
        );
        content.secondaryTextProperties.font = FLEXScaledRuntimeFont(
            10.5,
            UIFontWeightRegular,
            UIFontTextStyleCaption1,
            13.0
        );
        content.secondaryTextProperties.numberOfLines = 1;
        cell.contentConfiguration = content;
    }
    return cell;
}

@end
