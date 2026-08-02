#import "FLEXCHookEntryDetailController.h"
#import "FLEXCHookEngine.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"
#import "FLEXRuntimeBrowserController.h"
#import "FLEXRuntimeSearchSemantics.h"
#import "FLEXSymbolRebind.h"

#import <objc/runtime.h>
#import <string.h>

// Compatibility markers retained for the Mach-O verifier. This module is the
// sole owner of the corresponding runtime behavior.
const char *FLEXStableRuntimeControllerABIVersion =
    "AllFLEXing single-owner type-safe runtime controller ABI 1";
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
static const char *FLEXStableIndexPhase =
    "Indexing complete image snapshot";

static const void *kFLEXStableIndexKey = &kFLEXStableIndexKey;
static const void *kFLEXStableRequestKey = &kFLEXStableRequestKey;
static const void *kFLEXStableGenerationKey = &kFLEXStableGenerationKey;

typedef void (*FLEXDetailChooserIMP)(id object,
                                     SEL selector,
                                     UITableViewCell *cell);

static FLEXDetailChooserIMP gFLEXOriginalABIChooser = NULL;
static FLEXDetailChooserIMP gFLEXOriginalBackendChooser = NULL;

@interface FLEXStableSearchRequest : NSObject
@property (atomic) BOOL cancelled;
@end
@implementation FLEXStableSearchRequest
@end

@interface FLEXStableSearchIndex : NSObject
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *entries;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *tokensByEntry;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *characters;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *bigrams;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *trigrams;
@property (nonatomic, copy) NSArray *compatibilityRecords;
@end
@implementation FLEXStableSearchIndex
@end

@interface FLEXRuntimeBrowserController (AllFLEXingStablePrivate)
- (void)installNavigationItemsScanning:(BOOL)scanning;
- (void)updateNavigationStatus;
- (void)updateNavigationStatusWithTotalMatches:(NSUInteger)totalMatches;
- (void)updateUnavailableConfigurationWithError:(NSError * _Nullable)error;
@end

static dispatch_queue_t FLEXStableSearchQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.allflexing.runtime-search.single-owner",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_USER_INITIATED,
                0
            )
        );
    });
    return queue;
}

static id FLEXStableValue(id object, NSString *key) {
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void FLEXStableSetValue(id object, NSString *key, id value) {
    @try {
        [object setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
    }
}

static NSString *FLEXStableNormalizedText(NSString *source) {
    return FLEXRuntimeSearchNormalizedText(source);
}

static NSArray<NSString *> *FLEXStableTokens(NSString *source) {
    return FLEXRuntimeSearchQueryTokens(source);
}

static void FLEXStableAddSearchValue(NSMutableArray *values, id value) {
    if ([value isKindOfClass:NSString.class] && [value length]) {
        [values addObject:value];
    } else if ([value isKindOfClass:NSNumber.class]) {
        [values addObject:[value stringValue]];
    }
}

static const char *FLEXStableSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static FLEXHookABI FLEXStableObjectiveCABI(Method method) {
    if (!method) return FLEXHookABIUnknown;

    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (*FLEXStableSkipQualifiers(returnType) != 'B') {
        return FLEXHookABIUnknown;
    }

    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount == 2) {
        return FLEXHookABIObjCBoolNoArguments;
    }
    if (argumentCount != 3) {
        return FLEXHookABIUnknown;
    }

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *code = FLEXStableSkipQualifiers(argumentType);
    if (*code == '@' || *code == '#' || *code == ':') {
        return FLEXHookABIObjCBoolObjectArgument;
    }
    if (strchr("BcCsSiIlLqQ", *code)) {
        return FLEXHookABIObjCBoolIntegerArgument;
    }
    return FLEXHookABIUnknown;
}

static BOOL FLEXStableImageMatches(NSString *requested, const char *rawLoaded) {
    if (!requested.length || !rawLoaded) return YES;
    NSString *loaded = [NSString stringWithUTF8String:rawLoaded];
    if (!loaded.length) return NO;
    if ([requested containsString:@"/"]) {
        return [requested isEqualToString:loaded];
    }
    return [requested.lastPathComponent isEqualToString:loaded.lastPathComponent];
}

static BOOL FLEXStableObjectiveCEntry(FLEXHookEntry *entry) {
    if (!entry || entry.surface != FLEXHookSurfaceObjectiveC ||
        !FLEXMSHookMessageProviderAvailable()) {
        return NO;
    }

    NSDictionary *locator = [entry.locator isKindOfClass:NSDictionary.class]
        ? entry.locator : nil;
    NSString *className = [locator[@"class"] isKindOfClass:NSString.class]
        ? locator[@"class"] : nil;
    NSString *selectorName = [locator[@"selector"] isKindOfClass:NSString.class]
        ? locator[@"selector"] : nil;
    if (!className.length || !selectorName.length) return NO;

    Class targetClass = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    if (!targetClass || !selector) return NO;

    NSString *requestedImage = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : nil;
    if (!FLEXStableImageMatches(requestedImage, class_getImageName(targetClass))) {
        return NO;
    }

    BOOL classMethod = [locator[@"classMethod"] boolValue];
    Method method = classMethod
        ? class_getClassMethod(targetClass, selector)
        : class_getInstanceMethod(targetClass, selector);
    FLEXHookABI abi = FLEXStableObjectiveCABI(method);
    if (abi == FLEXHookABIUnknown) return NO;

    entry.abi = abi;
    entry.backend = FLEXHookBackendObjectiveCElleKit;
    entry.available = YES;
    entry.hookable = YES;
    entry.stale = NO;
    entry.lastError = nil;

    NSMutableDictionary *updated = [locator mutableCopy]
        ?: [NSMutableDictionary dictionary];
    updated[@"abiEvidence"] = [NSString stringWithUTF8String:FLEXOperationalABIEvidence];
    updated[@"backendEvidence"] = [NSString stringWithUTF8String:FLEXOperationalProviderEvidence];
    entry.locator = updated.copy;
    return YES;
}

static BOOL FLEXStableCEntry(FLEXHookEntry *entry) {
    if (!entry || !entry.available || entry.stale) return NO;

    if (entry.surface == FLEXHookSurfaceCImport) {
        NSUInteger bindSlots = [entry.locator[@"bindSlots"] unsignedIntegerValue];
        if (!bindSlots || !FLEXEmbeddedFishhookAvailable()) return NO;
        entry.backend = FLEXHookBackendFishhook;
        entry.hookable = entry.abi != FLEXHookABIUnknown;
        return YES;
    }

    if (entry.surface == FLEXHookSurfaceCInline) {
        NSString *source = [entry.locator[@"source"] isKindOfClass:NSString.class]
            ? entry.locator[@"source"] : nil;
        BOOL imageScoped = [source isEqualToString:@"mach-o-symbol-table"] ||
                           [source isEqualToString:@"LC_FUNCTION_STARTS"];
        BOOL hasAddressEvidence = [entry.locator[@"address"] unsignedLongLongValue] != 0 ||
                                  [entry.locator[@"offset"] unsignedLongLongValue] != 0;
        if (!imageScoped || !hasAddressEvidence ||
            !FLEXMSHookFunctionProviderAvailable()) {
            return NO;
        }
        entry.backend = FLEXHookBackendInlineElleKit;
        entry.hookable = entry.abi != FLEXHookABIUnknown;
        return YES;
    }

    return NO;
}

static NSArray<FLEXHookEntry *> *FLEXStableProjection(
    FLEXRuntimeBrowserKind kind,
    NSArray<FLEXHookEntry *> *entries
) {
    NSMutableArray<FLEXHookEntry *> *projected =
        [NSMutableArray arrayWithCapacity:entries.count];
    for (FLEXHookEntry *entry in entries ?: @[]) {
        BOOL accepted = kind == FLEXRuntimeBrowserKindObjectiveC
            ? FLEXStableObjectiveCEntry(entry)
            : FLEXStableCEntry(entry);
        if (accepted) [projected addObject:entry];
    }
    return projected.copy;
}

static void FLEXStableAddPosting(
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *map,
    NSString *gram,
    NSUInteger entryIndex
) {
    if (!gram.length) return;
    NSMutableIndexSet *indexes = map[gram];
    if (!indexes) {
        indexes = [NSMutableIndexSet indexSet];
        map[gram] = indexes;
    }
    [indexes addIndex:entryIndex];
}

static void FLEXStableIndexToken(
    NSString *token,
    NSUInteger entryIndex,
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
            FLEXStableAddPosting(characters, character, entryIndex);
        }
        if (position + 2 <= token.length) {
            NSString *bigram = [token substringWithRange:NSMakeRange(position, 2)];
            if (![seenBigrams containsObject:bigram]) {
                [seenBigrams addObject:bigram];
                FLEXStableAddPosting(bigrams, bigram, entryIndex);
            }
        }
        if (position + 3 <= token.length) {
            NSString *trigram = [token substringWithRange:NSMakeRange(position, 3)];
            if (![seenTrigrams containsObject:trigram]) {
                [seenTrigrams addObject:trigram];
                FLEXStableAddPosting(trigrams, trigram, entryIndex);
            }
        }
    }
}

static NSDictionary<NSString *, NSIndexSet *> *FLEXStableFreeze(
    NSDictionary<NSString *, NSMutableIndexSet *> *mutablePostings
) {
    NSMutableDictionary<NSString *, NSIndexSet *> *result =
        [NSMutableDictionary dictionaryWithCapacity:mutablePostings.count];
    [mutablePostings enumerateKeysAndObjectsUsingBlock:^(
        NSString *key,
        NSMutableIndexSet *indexes,
        BOOL *stop
    ) {
        (void)stop;
        result[key] = indexes.copy;
    }];
    return result.copy;
}

static id FLEXStableCompatibilityRecord(FLEXHookEntry *entry,
                                        NSString *normalized,
                                        NSArray<NSString *> *tokens) {
    Class recordClass = NSClassFromString(@"FLEXRuntimeSearchRecord");
    if (!recordClass) return nil;
    id record = [recordClass new];
    @try {
        [record setValue:entry forKey:@"entry"];
        [record setValue:normalized forKey:@"normalizedText"];
        [record setValue:tokens forKey:@"tokens"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return record;
}

static FLEXStableSearchIndex *FLEXStableBuildIndex(
    NSArray<FLEXHookEntry *> *sourceEntries,
    FLEXRuntimeBrowserKind kind,
    FLEXStableSearchRequest *request,
    void (^progress)(NSUInteger completed, NSUInteger total)
) {
    NSArray<FLEXHookEntry *> *entries = [FLEXStableProjection(kind, sourceEntries)
        sortedArrayUsingComparator:^NSComparisonResult(
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
        [NSMutableArray arrayWithCapacity:entries.count];
    NSMutableArray *compatibilityRecords =
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
            NSMutableArray *searchValues = [NSMutableArray array];
            FLEXStableAddSearchValue(searchValues, entry.title);
            FLEXStableAddSearchValue(searchValues, entry.detail);
            FLEXStableAddSearchValue(searchValues, entry.imageName);
            FLEXStableAddSearchValue(searchValues, entry.identifier);
            for (NSString *key in locatorKeys) {
                FLEXStableAddSearchValue(searchValues, entry.locator[key]);
            }

            NSArray<NSString *> *tokens =
                FLEXRuntimeSearchSemanticTokensForValues(searchValues);
            NSString *normalized = [tokens componentsJoinedByString:@" "];
            [tokensByEntry addObject:tokens];
            id compatibilityRecord = FLEXStableCompatibilityRecord(
                entry,
                normalized,
                tokens
            );
            if (compatibilityRecord) [compatibilityRecords addObject:compatibilityRecord];
            for (NSString *token in [NSSet setWithArray:tokens]) {
                FLEXStableIndexToken(token,
                                     entryIndex,
                                     characters,
                                     bigrams,
                                     trigrams);
            }
        }
        if (progress && ((entryIndex & 1023) == 0 ||
                         entryIndex + 1 == entries.count)) {
            progress(entryIndex + 1, entries.count);
        }
    }
    if (request.cancelled) return nil;

    FLEXStableSearchIndex *index = [FLEXStableSearchIndex new];
    index.entries = entries;
    index.tokensByEntry = tokensByEntry.copy;
    index.characters = FLEXStableFreeze(characters);
    index.bigrams = FLEXStableFreeze(bigrams);
    index.trigrams = FLEXStableFreeze(trigrams);
    index.compatibilityRecords = compatibilityRecords.copy;
    return index;
}

static NSIndexSet *FLEXStablePostingForToken(FLEXStableSearchIndex *index,
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

static BOOL FLEXStableEntryMatches(FLEXStableSearchIndex *index,
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

static NSArray<FLEXHookEntry *> *FLEXStableQuery(
    FLEXStableSearchIndex *index,
    NSString *text,
    FLEXStableSearchRequest *request
) {
    NSArray<NSString *> *queryTokens = FLEXStableTokens(text);
    if (!queryTokens.count) return index.entries;

    NSMutableIndexSet *candidates = nil;
    for (NSString *queryToken in queryTokens) {
        if (request.cancelled) return nil;
        NSIndexSet *posting = FLEXStablePostingForToken(index, queryToken);
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
        if (FLEXStableEntryMatches(index, entryIndex, queryTokens)) {
            [results addObject:index.entries[entryIndex]];
        }
    }];
    return request.cancelled ? nil : results.copy;
}

static NSUInteger FLEXStableGeneration(id controller) {
    return [objc_getAssociatedObject(controller, kFLEXStableGenerationKey)
        unsignedIntegerValue];
}

static NSUInteger FLEXStableAdvanceGeneration(id controller) {
    NSUInteger generation = FLEXStableGeneration(controller) + 1;
    objc_setAssociatedObject(controller,
                             kFLEXStableGenerationKey,
                             @(generation),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return generation;
}

static void FLEXStableBuild(id object,
                            SEL selector,
                            NSArray<FLEXHookEntry *> *entries) {
    (void)selector;
    FLEXRuntimeBrowserController *controller = object;
    FLEXStableSearchRequest *previous = objc_getAssociatedObject(
        controller,
        kFLEXStableRequestKey
    );
    previous.cancelled = YES;
    FLEXStableSearchRequest *request = [FLEXStableSearchRequest new];
    objc_setAssociatedObject(controller,
                             kFLEXStableRequestKey,
                             request,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSUInteger generation = FLEXStableAdvanceGeneration(controller);

    FLEXRuntimeBrowserKind kind = (FLEXRuntimeBrowserKind)[
        FLEXStableValue(controller, @"kind") integerValue
    ];
    UISearchController *search = FLEXStableValue(controller, @"searchController");
    UIActivityIndicatorView *spinner = FLEXStableValue(controller, @"progressSpinner");
    UIProgressView *progressView = FLEXStableValue(controller, @"progressView");

    FLEXStableSetValue(controller, @"indexing", @YES);
    FLEXStableSetValue(controller,
                       @"progressPhase",
                       [NSString stringWithUTF8String:FLEXStableIndexPhase]);
    FLEXStableSetValue(controller, @"progressCompleted", @0);
    FLEXStableSetValue(controller, @"progressTotal", @(entries.count));
    search.searchBar.userInteractionEnabled = NO;
    progressView.progress = 0;
    [spinner startAnimating];
    [controller installNavigationItemsScanning:YES];
    [controller updateNavigationStatus];
    [controller updateUnavailableConfigurationWithError:nil];

    __weak FLEXRuntimeBrowserController *weakController = controller;
    dispatch_async(FLEXStableSearchQueue(), ^{
        FLEXStableSearchIndex *index = FLEXStableBuildIndex(
            entries ?: @[],
            kind,
            request,
            ^(NSUInteger completed, NSUInteger total) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    FLEXRuntimeBrowserController *strongController = weakController;
                    if (!strongController || request.cancelled ||
                        FLEXStableGeneration(strongController) != generation) return;
                    FLEXStableSetValue(strongController,
                                       @"progressCompleted",
                                       @(completed));
                    FLEXStableSetValue(strongController,
                                       @"progressTotal",
                                       @(total));
                    progressView.progress = total
                        ? (float)completed / (float)total : 1.0;
                    [strongController updateNavigationStatus];
                });
            }
        );
        if (!index || request.cancelled) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            FLEXRuntimeBrowserController *strongController = weakController;
            if (!strongController || request.cancelled ||
                FLEXStableGeneration(strongController) != generation) return;

            objc_setAssociatedObject(strongController,
                                     kFLEXStableIndexKey,
                                     index,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            FLEXStableSetValue(strongController, @"allEntries", index.entries);
            FLEXStableSetValue(strongController, @"filteredEntries", index.entries);
            // Keep the controller's declared invariant. Any fallback path that
            // reads searchIndex receives FLEXRuntimeSearchRecord instances,
            // never FLEXHookEntry objects.
            FLEXStableSetValue(strongController,
                               @"searchIndex",
                               index.compatibilityRecords);
            FLEXStableSetValue(strongController, @"indexing", @NO);
            FLEXStableSetValue(strongController,
                               @"progressCompleted",
                               @(index.entries.count));
            FLEXStableSetValue(strongController,
                               @"progressTotal",
                               @(index.entries.count));
            [spinner stopAnimating];
            [strongController installNavigationItemsScanning:NO];
            search.searchBar.userInteractionEnabled = YES;
            search.searchBar.placeholder = [NSString stringWithFormat:
                @"Search %lu supported target(s)",
                (unsigned long)index.entries.count];
            [strongController.tableView reloadData];
            [strongController updateNavigationStatusWithTotalMatches:index.entries.count];
            [strongController updateUnavailableConfigurationWithError:nil];
        });
    });
}

static void FLEXStableSchedule(id object,
                               SEL selector,
                               NSString *text,
                               BOOL immediate) {
    (void)selector;
    FLEXRuntimeBrowserController *controller = object;
    FLEXStableSearchIndex *index = objc_getAssociatedObject(
        controller,
        kFLEXStableIndexKey
    );
    if (!index) return;

    FLEXStableSearchRequest *previous = objc_getAssociatedObject(
        controller,
        kFLEXStableRequestKey
    );
    previous.cancelled = YES;
    FLEXStableSearchRequest *request = [FLEXStableSearchRequest new];
    objc_setAssociatedObject(controller,
                             kFLEXStableRequestKey,
                             request,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSUInteger generation = FLEXStableAdvanceGeneration(controller);
    NSString *query = [text copy] ?: @"";
    NSTimeInterval delay = immediate ? 0.0 : 0.10;

    __weak FLEXRuntimeBrowserController *weakController = controller;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        FLEXStableSearchQueue(),
        ^{
            NSArray<FLEXHookEntry *> *results = FLEXStableQuery(
                index,
                query,
                request
            );
            if (!results || request.cancelled) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                FLEXRuntimeBrowserController *strongController = weakController;
                if (!strongController || request.cancelled ||
                    FLEXStableGeneration(strongController) != generation) return;
                FLEXStableSetValue(strongController,
                                   @"filteredEntries",
                                   results);
                [strongController.tableView reloadData];
                [strongController updateNavigationStatusWithTotalMatches:results.count];
                [strongController updateUnavailableConfigurationWithError:nil];
            });
        }
    );
}

static void FLEXStableRefresh(id object, SEL selector) {
    (void)selector;
    FLEXRuntimeBrowserController *controller = object;
    FLEXStableSearchIndex *index = objc_getAssociatedObject(
        controller,
        kFLEXStableIndexKey
    );
    if (!index.entries.count) return;

    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    NSMutableArray<FLEXHookEntry *> *canonical =
        [NSMutableArray arrayWithCapacity:index.entries.count];
    NSMutableArray *compatibilityRecords =
        [NSMutableArray arrayWithCapacity:index.entries.count];
    Class recordClass = NSClassFromString(@"FLEXRuntimeSearchRecord");

    for (NSUInteger entryIndex = 0; entryIndex < index.entries.count; entryIndex++) {
        FLEXHookEntry *entry = index.entries[entryIndex];
        FLEXHookEntry *resolved = [registry entryForIdentifier:entry.identifier] ?: entry;
        [canonical addObject:resolved];
        if (recordClass && entryIndex < index.tokensByEntry.count) {
            NSArray<NSString *> *tokens = index.tokensByEntry[entryIndex];
            id record = FLEXStableCompatibilityRecord(
                resolved,
                [tokens componentsJoinedByString:@" "],
                tokens
            );
            if (record) [compatibilityRecords addObject:record];
        }
    }
    index.entries = canonical.copy;
    index.compatibilityRecords = compatibilityRecords.copy;
    FLEXStableSetValue(controller, @"allEntries", index.entries);
    FLEXStableSetValue(controller, @"searchIndex", index.compatibilityRecords);

    UISearchController *search = FLEXStableValue(controller, @"searchController");
    FLEXStableSchedule(controller,
                       NSSelectorFromString(@"scheduleSearchForText:immediate:"),
                       search.searchBar.text ?: @"",
                       YES);
}

static FLEXHookEntry *FLEXStablePromoteDetailEntry(id controller) {
    FLEXHookEntry *entry = FLEXStableValue(controller, @"entry");
    if (!entry.identifier.length) return entry;
    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    FLEXHookEntry *existing = [registry entryForIdentifier:entry.identifier];
    if (existing) return existing;

    FLEXHookEntry *promoted = [entry copy];
    promoted.userConfigured = YES;
    FLEXHookEntry *resolved = [registry upsertDiscoveredEntry:promoted] ?: promoted;
    FLEXStableSetValue(controller, @"entry", resolved);
    return resolved;
}

static void FLEXStablePresentABIChooser(id object,
                                        SEL selector,
                                        UITableViewCell *cell) {
    (void)FLEXStablePromoteDetailEntry(object);
    if (gFLEXOriginalABIChooser) {
        gFLEXOriginalABIChooser(object, selector, cell);
    }
}

static void FLEXStablePresentBackendChooser(id object,
                                            SEL selector,
                                            UITableViewCell *cell) {
    (void)FLEXStablePromoteDetailEntry(object);
    if (gFLEXOriginalBackendChooser) {
        gFLEXOriginalBackendChooser(object, selector, cell);
    }
}

static void FLEXStableInstallMethod(Class cls, SEL selector, IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (method) method_setImplementation(method, replacement);
}

static void FLEXInstallStableRuntimeController(void) {
    Class browserClass = FLEXRuntimeBrowserController.class;
    FLEXStableInstallMethod(browserClass,
        NSSelectorFromString(@"buildSearchIndexForEntries:"),
        (IMP)FLEXStableBuild);
    FLEXStableInstallMethod(browserClass,
        NSSelectorFromString(@"scheduleSearchForText:immediate:"),
        (IMP)FLEXStableSchedule);
    FLEXStableInstallMethod(browserClass,
        NSSelectorFromString(@"refreshCanonicalEntries"),
        (IMP)FLEXStableRefresh);

    // The bridge's +load exchanged initWithEntry: with its alias. Restore the
    // original initializer directly; opening any row is read-only and cannot
    // synchronously post a registry notification while navigation is pushing.
    Class detailClass = FLEXHookEntryDetailController.class;
    Method detailInitializer = class_getInstanceMethod(
        detailClass,
        @selector(initWithEntry:)
    );
    Method originalInitializerAlias = class_getInstanceMethod(
        detailClass,
        NSSelectorFromString(@"af_runtimeSnapshot_initWithEntry:")
    );
    if (detailInitializer && originalInitializerAlias) {
        method_setImplementation(
            detailInitializer,
            method_getImplementation(originalInitializerAlias)
        );
    }

    Method abiChooser = class_getInstanceMethod(
        detailClass,
        NSSelectorFromString(@"presentABIChooserFromCell:")
    );
    if (abiChooser) {
        gFLEXOriginalABIChooser = (FLEXDetailChooserIMP)
            method_getImplementation(abiChooser);
        method_setImplementation(abiChooser, (IMP)FLEXStablePresentABIChooser);
    }
    Method backendChooser = class_getInstanceMethod(
        detailClass,
        NSSelectorFromString(@"presentBackendChooserFromCell:")
    );
    if (backendChooser) {
        gFLEXOriginalBackendChooser = (FLEXDetailChooserIMP)
            method_getImplementation(backendChooser);
        method_setImplementation(backendChooser, (IMP)FLEXStablePresentBackendChooser);
    }
}

__attribute__((constructor))
static void FLEXStableRuntimeControllerBootstrap(void) {
    // All Objective-C +load exchanges have completed. One main-queue turn is
    // sufficient because no other compiled module owns these selectors.
    dispatch_async(dispatch_get_main_queue(), ^{
        FLEXInstallStableRuntimeController();
    });
}
