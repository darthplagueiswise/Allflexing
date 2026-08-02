#import "FLEXCHookEngine.h"
#import "FLEXHookRegistry.h"
#import "FLEXRuntimeBrowserController.h"

#import <objc/runtime.h>

const char *FLEXRuntimeSearchCompletenessABIVersion =
    "AllFLEXing complete-image substring-index search ABI 1";

static const void *kFLEXCompleteIndexKey = &kFLEXCompleteIndexKey;
static const void *kFLEXCompleteRequestKey = &kFLEXCompleteRequestKey;
static const void *kFLEXCompleteGenerationKey = &kFLEXCompleteGenerationKey;

typedef NS_ENUM(NSUInteger, FLEXSearchGramKind) {
    FLEXSearchGramKindCharacter = 1,
    FLEXSearchGramKindBigram = 2,
    FLEXSearchGramKindTrigram = 3,
};

@interface FLEXCompleteSearchRequest : NSObject
@property (atomic) BOOL cancelled;
@end
@implementation FLEXCompleteSearchRequest
@end

@interface FLEXCompleteSearchIndex : NSObject
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *entries;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *tokensByEntry;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *characters;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *bigrams;
@property (nonatomic, copy) NSDictionary<NSString *, NSIndexSet *> *trigrams;
@end
@implementation FLEXCompleteSearchIndex
@end

static dispatch_queue_t FLEXCompleteSearchQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.allflexing.runtime-search.complete-image",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_USER_INITIATED,
                0
            )
        );
    });
    return queue;
}

static NSString *FLEXCompleteNormalizedText(NSString *source) {
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
    NSMutableArray<NSString *> *tokens = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts) {
        if (part.length) [tokens addObject:part];
    }
    return [tokens componentsJoinedByString:@" "];
}

static NSArray<NSString *> *FLEXCompleteTokens(NSString *source) {
    NSString *normalized = FLEXCompleteNormalizedText(source);
    return normalized.length
        ? [normalized componentsSeparatedByString:@" "] : @[];
}

static void FLEXCompleteAppend(NSMutableString *raw, id value) {
    if ([value isKindOfClass:NSString.class] && [value length]) {
        [raw appendString:value];
        [raw appendString:@" "];
    } else if ([value isKindOfClass:NSNumber.class]) {
        [raw appendString:[value stringValue]];
        [raw appendString:@" "];
    }
}

static void FLEXCompleteAddPosting(
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

static void FLEXCompleteIndexToken(
    NSString *token,
    NSUInteger entryIndex,
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *characters,
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *bigrams,
    NSMutableDictionary<NSString *, NSMutableIndexSet *> *trigrams
) {
    if (!token.length) return;
    NSMutableSet<NSString *> *seenCharacters = [NSMutableSet set];
    NSMutableSet<NSString *> *seenBigrams = [NSMutableSet set];
    NSMutableSet<NSString *> *seenTrigrams = [NSMutableSet set];
    for (NSUInteger index = 0; index < token.length; index++) {
        NSString *character = [token substringWithRange:NSMakeRange(index, 1)];
        if (![seenCharacters containsObject:character]) {
            [seenCharacters addObject:character];
            FLEXCompleteAddPosting(characters, character, entryIndex);
        }
        if (index + 2 <= token.length) {
            NSString *bigram = [token substringWithRange:NSMakeRange(index, 2)];
            if (![seenBigrams containsObject:bigram]) {
                [seenBigrams addObject:bigram];
                FLEXCompleteAddPosting(bigrams, bigram, entryIndex);
            }
        }
        if (index + 3 <= token.length) {
            NSString *trigram = [token substringWithRange:NSMakeRange(index, 3)];
            if (![seenTrigrams containsObject:trigram]) {
                [seenTrigrams addObject:trigram];
                FLEXCompleteAddPosting(trigrams, trigram, entryIndex);
            }
        }
    }
}

static NSDictionary<NSString *, NSIndexSet *> *FLEXCompleteFreezePostings(
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

static FLEXCompleteSearchIndex *FLEXCompleteBuildIndex(
    NSArray<FLEXHookEntry *> *sourceEntries,
    FLEXCompleteSearchRequest *request,
    void (^progress)(NSUInteger completed, NSUInteger total)
) {
    NSArray<FLEXHookEntry *> *entries = [sourceEntries sortedArrayUsingComparator:^NSComparisonResult(
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
            NSMutableString *raw = [NSMutableString string];
            FLEXCompleteAppend(raw, entry.title);
            FLEXCompleteAppend(raw, entry.detail);
            FLEXCompleteAppend(raw, entry.imageName);
            FLEXCompleteAppend(raw, entry.identifier);
            if ([entry.locator isKindOfClass:NSDictionary.class]) {
                for (NSString *key in locatorKeys) {
                    FLEXCompleteAppend(raw, entry.locator[key]);
                }
            }
            NSArray<NSString *> *tokens = FLEXCompleteTokens(raw);
            [tokensByEntry addObject:tokens];
            for (NSString *token in [NSSet setWithArray:tokens]) {
                FLEXCompleteIndexToken(token,
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

    FLEXCompleteSearchIndex *index = [FLEXCompleteSearchIndex new];
    index.entries = entries;
    index.tokensByEntry = tokensByEntry.copy;
    index.characters = FLEXCompleteFreezePostings(characters);
    index.bigrams = FLEXCompleteFreezePostings(bigrams);
    index.trigrams = FLEXCompleteFreezePostings(trigrams);
    return index;
}

static NSIndexSet *FLEXCompletePostingForQueryToken(
    FLEXCompleteSearchIndex *index,
    NSString *token
) {
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

static BOOL FLEXCompleteEntryMatches(
    FLEXCompleteSearchIndex *index,
    NSUInteger entryIndex,
    NSArray<NSString *> *queryTokens
) {
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

static NSArray<FLEXHookEntry *> *FLEXCompleteQueryIndex(
    FLEXCompleteSearchIndex *index,
    NSString *text,
    FLEXCompleteSearchRequest *request
) {
    NSArray<NSString *> *queryTokens = FLEXCompleteTokens(text);
    if (!queryTokens.count) return index.entries;

    NSMutableIndexSet *candidates = nil;
    for (NSString *queryToken in queryTokens) {
        if (request.cancelled) return nil;
        NSIndexSet *posting = FLEXCompletePostingForQueryToken(index, queryToken);
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
        if (FLEXCompleteEntryMatches(index, entryIndex, queryTokens)) {
            [results addObject:index.entries[entryIndex]];
        }
    }];
    return request.cancelled ? nil : results.copy;
}

static NSUInteger FLEXCompleteGeneration(id controller) {
    return [objc_getAssociatedObject(controller, kFLEXCompleteGenerationKey)
        unsignedIntegerValue];
}

static NSUInteger FLEXCompleteAdvanceGeneration(id controller) {
    NSUInteger generation = FLEXCompleteGeneration(controller) + 1;
    objc_setAssociatedObject(controller,
                             kFLEXCompleteGenerationKey,
                             @(generation),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return generation;
}

static void FLEXCompleteSetValue(id object, NSString *key, id value) {
    @try {
        [object setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
    }
}

static id FLEXCompleteValue(id object, NSString *key) {
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void FLEXCompleteBuild(id object, SEL selector, NSArray<FLEXHookEntry *> *entries) {
    (void)selector;
    FLEXRuntimeBrowserController *controller = object;
    FLEXCompleteSearchRequest *previous = objc_getAssociatedObject(
        controller,
        kFLEXCompleteRequestKey
    );
    previous.cancelled = YES;
    FLEXCompleteSearchRequest *request = [FLEXCompleteSearchRequest new];
    objc_setAssociatedObject(controller,
                             kFLEXCompleteRequestKey,
                             request,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSUInteger generation = FLEXCompleteAdvanceGeneration(controller);

    UISearchController *search = FLEXCompleteValue(controller, @"searchController");
    UIActivityIndicatorView *spinner = FLEXCompleteValue(controller, @"progressSpinner");
    UIProgressView *progressView = FLEXCompleteValue(controller, @"progressView");
    FLEXCompleteSetValue(controller, @"indexing", @YES);
    FLEXCompleteSetValue(controller, @"progressPhase", @"Indexing complete image snapshot");
    FLEXCompleteSetValue(controller, @"progressCompleted", @0);
    FLEXCompleteSetValue(controller, @"progressTotal", @(entries.count));
    search.searchBar.userInteractionEnabled = NO;
    progressView.progress = 0;
    [spinner startAnimating];
    if ([controller respondsToSelector:NSSelectorFromString(@"installNavigationItemsScanning:")]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(controller,
            NSSelectorFromString(@"installNavigationItemsScanning:"), YES);
    }
    if ([controller respondsToSelector:NSSelectorFromString(@"updateNavigationStatus")]) {
        ((void (*)(id, SEL))objc_msgSend)(controller,
            NSSelectorFromString(@"updateNavigationStatus"));
    }

    __weak FLEXRuntimeBrowserController *weakController = controller;
    dispatch_async(FLEXCompleteSearchQueue(), ^{
        FLEXCompleteSearchIndex *index = FLEXCompleteBuildIndex(
            entries ?: @[],
            request,
            ^(NSUInteger completed, NSUInteger total) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    FLEXRuntimeBrowserController *strongController = weakController;
                    if (!strongController || request.cancelled ||
                        FLEXCompleteGeneration(strongController) != generation) return;
                    FLEXCompleteSetValue(strongController,
                                         @"progressCompleted",
                                         @(completed));
                    FLEXCompleteSetValue(strongController,
                                         @"progressTotal",
                                         @(total));
                    progressView.progress = total
                        ? (float)completed / (float)total : 1.0;
                    if ([strongController respondsToSelector:
                            NSSelectorFromString(@"updateNavigationStatus")]) {
                        ((void (*)(id, SEL))objc_msgSend)(strongController,
                            NSSelectorFromString(@"updateNavigationStatus"));
                    }
                });
            }
        );
        if (!index || request.cancelled) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            FLEXRuntimeBrowserController *strongController = weakController;
            if (!strongController || request.cancelled ||
                FLEXCompleteGeneration(strongController) != generation) return;
            objc_setAssociatedObject(strongController,
                                     kFLEXCompleteIndexKey,
                                     index,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            FLEXCompleteSetValue(strongController, @"allEntries", index.entries);
            FLEXCompleteSetValue(strongController, @"filteredEntries", index.entries);
            FLEXCompleteSetValue(strongController, @"searchIndex", index.entries);
            FLEXCompleteSetValue(strongController, @"indexing", @NO);
            FLEXCompleteSetValue(strongController,
                                 @"progressCompleted",
                                 @(index.entries.count));
            FLEXCompleteSetValue(strongController,
                                 @"progressTotal",
                                 @(index.entries.count));
            [spinner stopAnimating];
            if ([strongController respondsToSelector:
                    NSSelectorFromString(@"installNavigationItemsScanning:")]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(strongController,
                    NSSelectorFromString(@"installNavigationItemsScanning:"), NO);
            }
            search.searchBar.userInteractionEnabled = YES;
            search.searchBar.placeholder = [NSString stringWithFormat:
                @"Search %lu entries in selected image",
                (unsigned long)index.entries.count];
            [strongController.tableView reloadData];
            if ([strongController respondsToSelector:
                    NSSelectorFromString(@"updateNavigationStatusWithTotalMatches:")]) {
                ((void (*)(id, SEL, NSUInteger))objc_msgSend)(strongController,
                    NSSelectorFromString(@"updateNavigationStatusWithTotalMatches:"),
                    index.entries.count);
            }
            if ([strongController respondsToSelector:
                    NSSelectorFromString(@"updateUnavailableConfigurationWithError:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(strongController,
                    NSSelectorFromString(@"updateUnavailableConfigurationWithError:"), nil);
            }
        });
    });
}

static void FLEXCompleteSchedule(id object,
                                 SEL selector,
                                 NSString *text,
                                 BOOL immediate) {
    (void)selector;
    FLEXRuntimeBrowserController *controller = object;
    FLEXCompleteSearchIndex *index = objc_getAssociatedObject(
        controller,
        kFLEXCompleteIndexKey
    );
    if (!index) return;

    FLEXCompleteSearchRequest *previous = objc_getAssociatedObject(
        controller,
        kFLEXCompleteRequestKey
    );
    previous.cancelled = YES;
    FLEXCompleteSearchRequest *request = [FLEXCompleteSearchRequest new];
    objc_setAssociatedObject(controller,
                             kFLEXCompleteRequestKey,
                             request,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSUInteger generation = FLEXCompleteAdvanceGeneration(controller);
    NSString *query = [text copy] ?: @"";
    NSTimeInterval delay = immediate ? 0.0 : 0.10;

    __weak FLEXRuntimeBrowserController *weakController = controller;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        FLEXCompleteSearchQueue(),
        ^{
            NSArray<FLEXHookEntry *> *results = FLEXCompleteQueryIndex(
                index,
                query,
                request
            );
            if (!results || request.cancelled) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                FLEXRuntimeBrowserController *strongController = weakController;
                if (!strongController || request.cancelled ||
                    FLEXCompleteGeneration(strongController) != generation) return;
                FLEXCompleteSetValue(strongController,
                                     @"filteredEntries",
                                     results);
                [strongController.tableView reloadData];
                if ([strongController respondsToSelector:
                        NSSelectorFromString(@"updateNavigationStatusWithTotalMatches:")]) {
                    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(strongController,
                        NSSelectorFromString(@"updateNavigationStatusWithTotalMatches:"),
                        results.count);
                }
                if ([strongController respondsToSelector:
                        NSSelectorFromString(@"updateUnavailableConfigurationWithError:")]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(strongController,
                        NSSelectorFromString(@"updateUnavailableConfigurationWithError:"), nil);
                }
            });
        }
    );
}

static void FLEXCompleteRefresh(id object, SEL selector) {
    (void)selector;
    FLEXRuntimeBrowserController *controller = object;
    FLEXCompleteSearchIndex *index = objc_getAssociatedObject(
        controller,
        kFLEXCompleteIndexKey
    );
    if (!index.entries.count) return;

    FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
    NSMutableArray<FLEXHookEntry *> *canonical =
        [NSMutableArray arrayWithCapacity:index.entries.count];
    for (FLEXHookEntry *entry in index.entries) {
        [canonical addObject:[registry entryForIdentifier:entry.identifier] ?: entry];
    }
    index.entries = canonical.copy;
    FLEXCompleteSetValue(controller, @"allEntries", index.entries);
    UISearchController *search = FLEXCompleteValue(controller, @"searchController");
    FLEXCompleteSchedule(controller,
                         NSSelectorFromString(@"scheduleSearchForText:immediate:"),
                         search.searchBar.text ?: @"",
                         YES);
}

static void FLEXCompleteInstallIMP(Class cls, SEL selector, IMP implementation) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method) method_setImplementation(method, implementation);
}

static void FLEXInstallCompleteRuntimeSearch(void) {
    Class cls = FLEXRuntimeBrowserController.class;
    FLEXCompleteInstallIMP(cls,
        NSSelectorFromString(@"buildSearchIndexForEntries:"),
        (IMP)FLEXCompleteBuild);
    FLEXCompleteInstallIMP(cls,
        NSSelectorFromString(@"af_fast_buildSearchIndexForEntries:"),
        (IMP)FLEXCompleteBuild);
    FLEXCompleteInstallIMP(cls,
        NSSelectorFromString(@"scheduleSearchForText:immediate:"),
        (IMP)FLEXCompleteSchedule);
    FLEXCompleteInstallIMP(cls,
        NSSelectorFromString(@"af_fast_scheduleSearchForText:immediate:"),
        (IMP)FLEXCompleteSchedule);
    FLEXCompleteInstallIMP(cls,
        NSSelectorFromString(@"refreshCanonicalEntries"),
        (IMP)FLEXCompleteRefresh);
    FLEXCompleteInstallIMP(cls,
        NSSelectorFromString(@"af_fast_refreshCanonicalEntries"),
        (IMP)FLEXCompleteRefresh);
}

__attribute__((constructor))
static void FLEXRuntimeSearchCompletenessBootstrap(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            FLEXInstallCompleteRuntimeSearch();
        });
    });
}
