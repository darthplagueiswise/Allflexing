#import "FLEXCHookEngine.h"
#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"
#import "FLEXRuntimeBrowserController.h"

#import <objc/runtime.h>
#import <stdint.h>

const char *FLEXRuntimeSnapshotRegistryBridgeABIVersion =
    "AllFLEXing transient runtime snapshot bridge ABI 2";
const char *FLEXRuntimeSearchAccelerationABIVersion =
    "AllFLEXing selected-image inverted-prefix-index search ABI 1";

static const void *kFLEXFastIndexKey = &kFLEXFastIndexKey;
static const void *kFLEXFastRequestKey = &kFLEXFastRequestKey;
static const void *kFLEXFastGenerationKey = &kFLEXFastGenerationKey;
static NSUInteger const kFLEXMaximumIndexedPrefixLength = 48;

@interface FLEXRuntimeFastRequest : NSObject
@property (atomic) BOOL cancelled;
@end
@implementation FLEXRuntimeFastRequest
@end

@interface FLEXRuntimeFastIndex : NSObject
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *entries;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *tokensByEntry;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *prefixes;
@end
@implementation FLEXRuntimeFastIndex
@end

@interface FLEXHookRegistry (AllFLEXingRuntimeSnapshotBridgePrivate)
- (FLEXHookEntry *)af_runtimeSnapshot_upsertDiscoveredEntry:(FLEXHookEntry *)entry;
- (void)af_runtimeSnapshot_stageEnabled:(BOOL)enabled
                     forEntryIdentifier:(NSString *)identifier;
@end

@interface FLEXHookEntryDetailController (AllFLEXingRuntimeSnapshotBridgePrivate)
- (instancetype)af_runtimeSnapshot_initWithEntry:(FLEXHookEntry *)entry;
@end

@interface FLEXRuntimeBrowserController (AllFLEXingFastSearchPrivate)
- (void)af_fast_buildSearchIndexForEntries:(NSArray<FLEXHookEntry *> *)entries;
- (void)af_fast_scheduleSearchForText:(NSString *)text immediate:(BOOL)immediate;
- (void)af_fast_refreshCanonicalEntries;
- (void)installNavigationItemsScanning:(BOOL)scanning;
- (void)updateNavigationStatus;
- (void)updateNavigationStatusWithTotalMatches:(NSUInteger)totalMatches;
- (void)updateUnavailableConfigurationWithError:(NSError * _Nullable)error;
@end

static dispatch_queue_t FLEXRuntimeFastSearchQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_USER_INITIATED,
            0
        );
        queue = dispatch_queue_create(
            "com.allflexing.runtime-search.inverted-prefix-index",
            attributes
        );
    });
    return queue;
}

static NSMapTable<NSString *, FLEXHookEntry *> *FLEXTransientRuntimeEntries(void) {
    static NSMapTable<NSString *, FLEXHookEntry *> *entries;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        entries = [NSMapTable strongToWeakObjectsMapTable];
    });
    return entries;
}

static BOOL FLEXEntryComesFromRuntimeImageSession(FLEXHookEntry *entry) {
    NSString *source = [entry.locator[@"source"] isKindOfClass:NSString.class]
        ? entry.locator[@"source"] : @"";
    return [source isEqualToString:@"objc-runtime-metadata"] ||
           [source isEqualToString:@"mach-o-indirect-symbols"] ||
           [source isEqualToString:@"mach-o-symbol-table"] ||
           [source isEqualToString:@"LC_FUNCTION_STARTS"];
}

static BOOL FLEXEntryCanAppearInRuntimeBrowser(FLEXHookEntry *entry,
                                                FLEXRuntimeBrowserKind kind,
                                                BOOL resolveInlineAddress) {
    if (!entry.available || entry.stale) {
        return NO;
    }

    if (kind == FLEXRuntimeBrowserKindObjectiveC) {
        return entry.surface == FLEXHookSurfaceObjectiveC &&
               entry.backend == FLEXHookBackendObjectiveCElleKit &&
               entry.abi != FLEXHookABIUnknown &&
               FLEXMSHookMessageProviderAvailable();
    }

    if (entry.surface == FLEXHookSurfaceCImport) {
        return entry.backend == FLEXHookBackendFishhook &&
               [entry.locator[@"bindSlots"] unsignedIntegerValue] > 0;
    }

    if (entry.surface == FLEXHookSurfaceCInline) {
        if (entry.backend != FLEXHookBackendInlineElleKit ||
            ![entry.locator[@"source"] isEqualToString:@"mach-o-symbol-table"] ||
            !FLEXMSHookFunctionProviderAvailable()) {
            return NO;
        }
        NSNumber *recordedAddress = [entry.locator[@"address"]
            isKindOfClass:NSNumber.class] ? entry.locator[@"address"] : nil;
        NSString *symbol = [entry.locator[@"symbol"]
            isKindOfClass:NSString.class] ? entry.locator[@"symbol"] : nil;
        if (!recordedAddress.unsignedLongLongValue || !symbol.length) {
            return NO;
        }
        if (!resolveInlineAddress) {
            return YES;
        }
        void *resolved = [FLEXCHookEngine resolveSymbol:symbol];
        return resolved == (void *)(uintptr_t)recordedAddress.unsignedLongLongValue;
    }

    return NO;
}

static FLEXHookEntry *FLEXPromotableEntryCopy(FLEXHookEntry *entry) {
    FLEXHookEntry *copy = [entry copy];
    NSMutableDictionary *locator = [copy.locator mutableCopy] ?: [NSMutableDictionary dictionary];
    locator[@"runtimeSnapshotPromoted"] = @YES;
    copy.locator = locator.copy;
    return copy;
}

static void FLEXBridgeExchangeInstanceMethods(Class cls,
                                               SEL original,
                                               SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

static NSString *FLEXFastNormalizedText(NSString *source) {
    if (!source.length) {
        return @"";
    }

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
            if (boundary) {
                [output appendString:@" "];
            }
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
    NSMutableArray<NSString *> *tokens = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts) {
        if (part.length) {
            [tokens addObject:part];
        }
    }
    return [tokens componentsJoinedByString:@" "];
}

static NSArray<NSString *> *FLEXFastTokens(NSString *source) {
    NSString *normalized = FLEXFastNormalizedText(source);
    return normalized.length
        ? [normalized componentsSeparatedByString:@" "] : @[];
}

static void FLEXFastAppendValue(NSMutableString *raw, id value) {
    if ([value isKindOfClass:NSString.class] && [value length]) {
        [raw appendString:value];
        [raw appendString:@" "];
    } else if ([value isKindOfClass:NSNumber.class]) {
        [raw appendString:[value stringValue]];
        [raw appendString:@" "];
    }
}

static NSUInteger FLEXFastGeneration(id controller) {
    NSNumber *value = objc_getAssociatedObject(controller, kFLEXFastGenerationKey);
    return value.unsignedIntegerValue;
}

static NSUInteger FLEXFastAdvanceGeneration(id controller) {
    NSUInteger next = FLEXFastGeneration(controller) + 1;
    objc_setAssociatedObject(controller,
                             kFLEXFastGenerationKey,
                             @(next),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return next;
}

static FLEXRuntimeFastIndex *FLEXBuildFastIndex(
    NSArray<FLEXHookEntry *> *sourceEntries,
    FLEXRuntimeBrowserKind kind,
    FLEXRuntimeFastRequest *request,
    void (^progress)(NSUInteger completed, NSUInteger total)
) {
    NSMutableArray<FLEXHookEntry *> *verified =
        [NSMutableArray arrayWithCapacity:sourceEntries.count];
    for (FLEXHookEntry *entry in sourceEntries) {
        if (request.cancelled) {
            return nil;
        }
        if (FLEXEntryCanAppearInRuntimeBrowser(entry, kind, YES)) {
            [verified addObject:entry];
        }
    }

    [verified sortUsingComparator:^NSComparisonResult(
        FLEXHookEntry *left,
        FLEXHookEntry *right
    ) {
        if (left.surface != right.surface) {
            return left.surface < right.surface
                ? NSOrderedAscending : NSOrderedDescending;
        }
        return [left.title localizedCaseInsensitiveCompare:right.title];
    }];

    NSMutableArray<NSArray<NSString *> *> *tokensByEntry =
        [NSMutableArray arrayWithCapacity:verified.count];
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *mutablePrefixes =
        [NSMutableDictionary dictionary];
    NSArray<NSString *> *locatorKeys = @[
        @"symbol", @"class", @"selector", @"encoding", @"image",
        @"imageUUID", @"source", @"backendEvidence", @"abiEvidence"
    ];

    for (NSUInteger entryIndex = 0; entryIndex < verified.count; entryIndex++) {
        if ((entryIndex & 127) == 0 && request.cancelled) {
            return nil;
        }
        FLEXHookEntry *entry = verified[entryIndex];
        @autoreleasepool {
            NSMutableString *raw = [NSMutableString string];
            FLEXFastAppendValue(raw, entry.title);
            FLEXFastAppendValue(raw, entry.identifier);
            FLEXFastAppendValue(raw, entry.detail);
            FLEXFastAppendValue(raw, entry.imageName);
            if ([entry.locator isKindOfClass:NSDictionary.class]) {
                for (NSString *key in locatorKeys) {
                    FLEXFastAppendValue(raw, entry.locator[key]);
                }
            }

            NSArray<NSString *> *tokens = FLEXFastTokens(raw);
            [tokensByEntry addObject:tokens];
            for (NSString *token in [NSSet setWithArray:tokens]) {
                NSUInteger maximum = MIN(kFLEXMaximumIndexedPrefixLength,
                                         token.length);
                for (NSUInteger length = 1; length <= maximum; length++) {
                    NSString *prefix = [token substringToIndex:length];
                    NSMutableIndexSet *indexes = mutablePrefixes[prefix];
                    if (!indexes) {
                        indexes = [NSMutableIndexSet indexSet];
                        mutablePrefixes[prefix] = indexes;
                    }
                    [indexes addIndex:entryIndex];
                }
            }
        }

        if (progress && ((entryIndex & 2047) == 0 ||
                         entryIndex + 1 == verified.count)) {
            progress(entryIndex + 1, verified.count);
        }
    }

    if (request.cancelled) {
        return nil;
    }
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

    FLEXRuntimeFastIndex *index = [FLEXRuntimeFastIndex new];
    index.entries = verified.copy;
    index.tokensByEntry = tokensByEntry.copy;
    index.prefixes = prefixes.copy;
    return index;
}

static BOOL FLEXFastEntryMatchesTokens(FLEXRuntimeFastIndex *index,
                                       NSUInteger entryIndex,
                                       NSArray<NSString *> *queryTokens) {
    if (entryIndex >= index.tokensByEntry.count) {
        return NO;
    }
    NSArray<NSString *> *candidateTokens = index.tokensByEntry[entryIndex];
    for (NSString *query in queryTokens) {
        BOOL matched = NO;
        for (NSString *candidate in candidateTokens) {
            if ([candidate hasPrefix:query]) {
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

static NSArray<FLEXHookEntry *> *FLEXQueryFastIndex(
    FLEXRuntimeFastIndex *index,
    NSString *text,
    FLEXRuntimeFastRequest *request
) {
    NSArray<NSString *> *queryTokens = FLEXFastTokens(text);
    if (!queryTokens.count) {
        return index.entries;
    }

    NSMutableIndexSet *candidates = nil;
    for (NSString *queryToken in queryTokens) {
        if (request.cancelled) {
            return nil;
        }
        NSString *lookup = queryToken.length > kFLEXMaximumIndexedPrefixLength
            ? [queryToken substringToIndex:kFLEXMaximumIndexedPrefixLength]
            : queryToken;
        NSIndexSet *matches = index.prefixes[lookup];
        if (!matches.count) {
            return @[];
        }
        if (!candidates) {
            candidates = matches.mutableCopy;
        } else {
            [candidates intersectIndexes:matches];
        }
        if (!candidates.count) {
            return @[];
        }
    }

    NSMutableArray<FLEXHookEntry *> *results =
        [NSMutableArray arrayWithCapacity:candidates.count];
    [candidates enumerateIndexesUsingBlock:^(NSUInteger entryIndex,
                                              BOOL *stop) {
        if (request.cancelled) {
            *stop = YES;
            return;
        }
        if (FLEXFastEntryMatchesTokens(index, entryIndex, queryTokens)) {
            [results addObject:index.entries[entryIndex]];
        }
    }];
    return request.cancelled ? nil : results.copy;
}

@implementation FLEXHookRegistry (AllFLEXingRuntimeSnapshotBridge)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLEXBridgeExchangeInstanceMethods(
            FLEXHookRegistry.class,
            @selector(upsertDiscoveredEntry:),
            @selector(af_runtimeSnapshot_upsertDiscoveredEntry:)
        );
        FLEXBridgeExchangeInstanceMethods(
            FLEXHookRegistry.class,
            @selector(stageEnabled:forEntryIdentifier:),
            @selector(af_runtimeSnapshot_stageEnabled:forEntryIdentifier:)
        );
        FLEXBridgeExchangeInstanceMethods(
            FLEXHookEntryDetailController.class,
            @selector(initWithEntry:),
            @selector(af_runtimeSnapshot_initWithEntry:)
        );
    });
}

- (FLEXHookEntry *)af_runtimeSnapshot_upsertDiscoveredEntry:(FLEXHookEntry *)entry {
    if (!FLEXEntryComesFromRuntimeImageSession(entry)) {
        return [self af_runtimeSnapshot_upsertDiscoveredEntry:entry];
    }

    FLEXHookEntry *existing = [self entryForIdentifier:entry.identifier];
    if (existing) {
        return [self af_runtimeSnapshot_upsertDiscoveredEntry:entry];
    }

    FLEXRuntimeBrowserKind kind = entry.surface == FLEXHookSurfaceObjectiveC
        ? FLEXRuntimeBrowserKindObjectiveC : FLEXRuntimeBrowserKindC;
    if (FLEXEntryCanAppearInRuntimeBrowser(entry, kind, NO)) {
        @synchronized (FLEXTransientRuntimeEntries()) {
            [FLEXTransientRuntimeEntries() setObject:entry forKey:entry.identifier];
        }
    }
    if (!entry.userConfigured) {
        return entry;
    }
    return [self af_runtimeSnapshot_upsertDiscoveredEntry:entry];
}

- (void)af_runtimeSnapshot_stageEnabled:(BOOL)enabled
                     forEntryIdentifier:(NSString *)identifier {
    if (enabled && ![self entryForIdentifier:identifier]) {
        FLEXHookEntry *transient = nil;
        @synchronized (FLEXTransientRuntimeEntries()) {
            transient = [FLEXTransientRuntimeEntries() objectForKey:identifier];
        }
        if (transient) {
            FLEXHookEntry *promoted = FLEXPromotableEntryCopy(transient);
            promoted.userConfigured = YES;
            [self af_runtimeSnapshot_upsertDiscoveredEntry:promoted];
        }
    }
    [self af_runtimeSnapshot_stageEnabled:enabled forEntryIdentifier:identifier];
}

@end

@implementation FLEXHookEntryDetailController (AllFLEXingRuntimeSnapshotBridge)

- (instancetype)af_runtimeSnapshot_initWithEntry:(FLEXHookEntry *)entry {
    FLEXHookEntry *resolved = entry;
    if (FLEXEntryComesFromRuntimeImageSession(entry)) {
        FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
        resolved = [registry entryForIdentifier:entry.identifier];
        if (!resolved) {
            FLEXHookEntry *promoted = FLEXPromotableEntryCopy(entry);
            promoted.userConfigured = NO;
            resolved = [registry af_runtimeSnapshot_upsertDiscoveredEntry:promoted];
        }
    }
    return [self af_runtimeSnapshot_initWithEntry:resolved ?: entry];
}

@end

@implementation FLEXRuntimeBrowserController (AllFLEXingFastSearch)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = FLEXRuntimeBrowserController.class;
        FLEXBridgeExchangeInstanceMethods(
            cls,
            NSSelectorFromString(@"buildSearchIndexForEntries:"),
            @selector(af_fast_buildSearchIndexForEntries:)
        );
        FLEXBridgeExchangeInstanceMethods(
            cls,
            NSSelectorFromString(@"scheduleSearchForText:immediate:"),
            @selector(af_fast_scheduleSearchForText:immediate:)
        );
        FLEXBridgeExchangeInstanceMethods(
            cls,
            NSSelectorFromString(@"refreshCanonicalEntries"),
            @selector(af_fast_refreshCanonicalEntries)
        );
    });
}

- (void)af_fast_buildSearchIndexForEntries:(NSArray<FLEXHookEntry *> *)entries {
    FLEXRuntimeFastRequest *previous = objc_getAssociatedObject(
        self,
        kFLEXFastRequestKey
    );
    previous.cancelled = YES;
    FLEXRuntimeFastRequest *request = [FLEXRuntimeFastRequest new];
    objc_setAssociatedObject(self,
                             kFLEXFastRequestKey,
                             request,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSUInteger generation = FLEXFastAdvanceGeneration(self);

    FLEXRuntimeBrowserKind kind = FLEXRuntimeBrowserKindObjectiveC;
    UISearchController *search = nil;
    UIActivityIndicatorView *spinner = nil;
    UIProgressView *progressView = nil;
    @try {
        kind = [[self valueForKey:@"kind"] integerValue];
        search = [self valueForKey:@"searchController"];
        spinner = [self valueForKey:@"progressSpinner"];
        progressView = [self valueForKey:@"progressView"];
        [self setValue:@YES forKey:@"indexing"];
        [self setValue:@"Indexing verified hook targets" forKey:@"progressPhase"];
        [self setValue:@0 forKey:@"progressCompleted"];
        [self setValue:@(entries.count) forKey:@"progressTotal"];
    } @catch (__unused NSException *exception) {
        [self af_fast_buildSearchIndexForEntries:entries];
        return;
    }

    search.searchBar.userInteractionEnabled = NO;
    progressView.progress = 0;
    [spinner startAnimating];
    [self installNavigationItemsScanning:YES];
    [self updateNavigationStatus];
    [self updateUnavailableConfigurationWithError:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(FLEXRuntimeFastSearchQueue(), ^{
        FLEXRuntimeFastIndex *index = FLEXBuildFastIndex(
            entries,
            kind,
            request,
            ^(NSUInteger completed, NSUInteger total) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) self = weakSelf;
                    if (!self || request.cancelled ||
                        FLEXFastGeneration(self) != generation) {
                        return;
                    }
                    @try {
                        [self setValue:@(completed) forKey:@"progressCompleted"];
                        [self setValue:@(total) forKey:@"progressTotal"];
                    } @catch (__unused NSException *exception) {
                    }
                    progressView.progress = total
                        ? (float)completed / (float)total : 1.0;
                    [self updateNavigationStatus];
                });
            }
        );
        if (!index || request.cancelled) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || request.cancelled ||
                FLEXFastGeneration(self) != generation) {
                return;
            }
            objc_setAssociatedObject(self,
                                     kFLEXFastIndexKey,
                                     index,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @try {
                [self setValue:index.entries forKey:@"allEntries"];
                [self setValue:index.entries forKey:@"filteredEntries"];
                [self setValue:index.entries forKey:@"searchIndex"];
                [self setValue:@NO forKey:@"indexing"];
                [self setValue:@(index.entries.count) forKey:@"progressCompleted"];
                [self setValue:@(index.entries.count) forKey:@"progressTotal"];
            } @catch (__unused NSException *exception) {
            }
            [spinner stopAnimating];
            [self installNavigationItemsScanning:NO];
            search.searchBar.userInteractionEnabled = YES;
            search.searchBar.placeholder = [NSString stringWithFormat:
                @"Search %lu verified target(s)",
                (unsigned long)index.entries.count];
            [self.tableView reloadData];
            [self updateNavigationStatusWithTotalMatches:index.entries.count];
            [self updateUnavailableConfigurationWithError:nil];
        });
    });
}

- (void)af_fast_scheduleSearchForText:(NSString *)text
                             immediate:(BOOL)immediate {
    FLEXRuntimeFastIndex *index = objc_getAssociatedObject(self, kFLEXFastIndexKey);
    if (!index) {
        return;
    }

    FLEXRuntimeFastRequest *previous = objc_getAssociatedObject(
        self,
        kFLEXFastRequestKey
    );
    previous.cancelled = YES;
    FLEXRuntimeFastRequest *request = [FLEXRuntimeFastRequest new];
    objc_setAssociatedObject(self,
                             kFLEXFastRequestKey,
                             request,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSUInteger generation = FLEXFastAdvanceGeneration(self);
    NSTimeInterval delay = immediate ? 0.0 : 0.10;
    NSString *query = [text copy] ?: @"";

    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        FLEXRuntimeFastSearchQueue(),
        ^{
            NSArray<FLEXHookEntry *> *results = FLEXQueryFastIndex(
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
                    FLEXFastGeneration(self) != generation) {
                    return;
                }
                @try {
                    [self setValue:results forKey:@"filteredEntries"];
                } @catch (__unused NSException *exception) {
                    return;
                }
                [self.tableView reloadData];
                [self updateNavigationStatusWithTotalMatches:results.count];
                [self updateUnavailableConfigurationWithError:nil];
            });
        }
    );
}

- (void)af_fast_refreshCanonicalEntries {
    FLEXRuntimeFastIndex *index = objc_getAssociatedObject(self, kFLEXFastIndexKey);
    if (!index.entries.count) {
        return;
    }

    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    NSMutableArray<FLEXHookEntry *> *canonical =
        [NSMutableArray arrayWithCapacity:index.entries.count];
    for (FLEXHookEntry *entry in index.entries) {
        [canonical addObject:[registry entryForIdentifier:entry.identifier] ?: entry];
    }
    index.entries = canonical.copy;
    @try {
        [self setValue:index.entries forKey:@"allEntries"];
    } @catch (__unused NSException *exception) {
    }

    UISearchController *search = nil;
    @try {
        search = [self valueForKey:@"searchController"];
    } @catch (__unused NSException *exception) {
    }
    [self af_fast_scheduleSearchForText:search.searchBar.text ?: @""
                               immediate:YES];
}

@end
