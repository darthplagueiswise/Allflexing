#import "FLEXRuntimeBrowserController.h"

#import "FLEXHookRegistry.h"

#import <objc/runtime.h>

const char *FLEXRuntimeSearchABIVersion =
    "AllFLEXing tokenized AND search ABI 2";

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
    for (NSUInteger index = 0; index < source.length; index++) {
        unichar current = [source characterAtIndex:index];
        BOOL alphanumeric = [letters characterIsMember:current] ||
                            [digits characterIsMember:current];
        if (!alphanumeric) {
            [spaced appendString:@" "];
            continue;
        }

        BOOL uppercase = [[NSCharacterSet uppercaseLetterCharacterSet]
            characterIsMember:current];
        if (uppercase && index > 0) {
            unichar previous = [source characterAtIndex:index - 1];
            BOOL previousLowerOrDigit =
                [[NSCharacterSet lowercaseLetterCharacterSet] characterIsMember:previous] ||
                [digits characterIsMember:previous];
            BOOL acronymBoundary = NO;
            if (index + 1 < source.length) {
                unichar next = [source characterAtIndex:index + 1];
                acronymBoundary = [[NSCharacterSet uppercaseLetterCharacterSet]
                    characterIsMember:previous] &&
                    [[NSCharacterSet lowercaseLetterCharacterSet]
                        characterIsMember:next];
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
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length) {
            [tokens addObject:part];
        }
    }
    return [tokens componentsJoinedByString:@" "];
}

static NSArray<NSString *> *FLEXSearchTokens(NSString *source) {
    NSString *normalized = FLEXSearchNormalizedText(source);
    return normalized.length ? [normalized componentsSeparatedByString:@" "] : @[];
}

static void FLEXAppendSearchObject(NSMutableString *target, id object) {
    if ([object isKindOfClass:NSString.class] ||
        [object isKindOfClass:NSNumber.class]) {
        [target appendFormat:@" %@", object];
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id value in object) {
            FLEXAppendSearchObject(target, value);
        }
    } else if ([object isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            (void)stop;
            FLEXAppendSearchObject(target, key);
            FLEXAppendSearchObject(target, value);
        }];
    }
}

static NSInteger FLEXTokenMatchQuality(NSString *query, NSString *candidate) {
    if ([query isEqualToString:candidate]) {
        return 30;
    }
    if (query.length >= 3 && [candidate hasPrefix:query]) {
        // `enable` matches `enabled`, while remaining strict enough to avoid
        // one-character accidental matches.
        return 22;
    }
    if (candidate.length >= 3 && [query hasPrefix:candidate]) {
        return 16;
    }
    if (query.length >= 4 && [candidate containsString:query]) {
        return 10;
    }
    return 0;
}

static NSInteger FLEXSearchScore(FLEXHookEntry *entry,
                                 NSArray<NSString *> *queryTokens,
                                 NSString *normalizedQuery) {
    if (!queryTokens.count) {
        return 1;
    }

    NSMutableString *raw = [NSMutableString string];
    FLEXAppendSearchObject(raw, entry.title);
    FLEXAppendSearchObject(raw, entry.identifier);
    FLEXAppendSearchObject(raw, entry.detail);
    FLEXAppendSearchObject(raw, entry.imageName);
    FLEXAppendSearchObject(raw, entry.locator);
    NSString *normalized = FLEXSearchNormalizedText(raw);
    NSArray<NSString *> *candidateTokens = normalized.length
        ? [normalized componentsSeparatedByString:@" "] : @[];

    NSInteger score = 0;
    for (NSString *queryToken in queryTokens) {
        NSInteger best = 0;
        for (NSString *candidate in candidateTokens) {
            best = MAX(best, FLEXTokenMatchQuality(queryToken, candidate));
        }
        if (best == 0) {
            return -1;
        }
        score += best;
    }

    NSString *title = FLEXSearchNormalizedText(entry.title);
    NSString *identifier = FLEXSearchNormalizedText(entry.identifier);
    NSString *queryCompact = [normalizedQuery stringByReplacingOccurrencesOfString:@" "
                                                                         withString:@""];
    NSString *titleCompact = [title stringByReplacingOccurrencesOfString:@" "
                                                               withString:@""];
    NSString *identifierCompact = [identifier stringByReplacingOccurrencesOfString:@" "
                                                                         withString:@""];
    if ([title isEqualToString:normalizedQuery]) {
        score += 240;
    } else if ([title rangeOfString:normalizedQuery].location != NSNotFound) {
        score += 120;
    } else if (queryCompact.length && [titleCompact containsString:queryCompact]) {
        score += 90;
    }
    if (queryCompact.length && [identifierCompact containsString:queryCompact]) {
        score += 70;
    }
    return score;
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
    });
}

- (void)af_search_viewDidLoad {
    [self af_search_viewDidLoad];
    self.tableView.estimatedRowHeight = 62.0;
    @try {
        UISearchController *search = [self valueForKey:@"searchController"];
        search.searchBar.searchTextField.font = FLEXScaledRuntimeFont(
            14.0,
            UIFontWeightRegular,
            UIFontTextStyleBody,
            18.0
        );
    } @catch (__unused NSException *exception) {
    }
}

- (void)af_tokenizedReloadEntries {
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
    NSArray<NSString *> *queryTokens = FLEXSearchTokens(query);
    NSMutableArray<NSDictionary *> *ranked = [NSMutableArray array];

    for (FLEXHookEntry *entry in FLEXHookRegistry.sharedRegistry.entries) {
        BOOL surfaceMatches = kind == FLEXRuntimeBrowserKindObjectiveC
            ? entry.surface == FLEXHookSurfaceObjectiveC
            : (entry.surface == FLEXHookSurfaceCImport ||
               entry.surface == FLEXHookSurfaceCInline);
        if (!surfaceMatches) {
            continue;
        }
        NSInteger score = FLEXSearchScore(entry, queryTokens, normalizedQuery);
        if (score < 0) {
            continue;
        }
        [ranked addObject:@{ @"entry": entry, @"score": @(score) }];
    }

    [ranked sortUsingComparator:^NSComparisonResult(NSDictionary *left,
                                                     NSDictionary *right) {
        NSInteger leftScore = [left[@"score"] integerValue];
        NSInteger rightScore = [right[@"score"] integerValue];
        if (leftScore != rightScore) {
            return leftScore > rightScore ? NSOrderedAscending : NSOrderedDescending;
        }
        FLEXHookEntry *leftEntry = left[@"entry"];
        FLEXHookEntry *rightEntry = right[@"entry"];
        return [leftEntry.title localizedCaseInsensitiveCompare:rightEntry.title];
    }];

    NSMutableArray<FLEXHookEntry *> *entries =
        [NSMutableArray arrayWithCapacity:ranked.count];
    for (NSDictionary *record in ranked) {
        [entries addObject:record[@"entry"]];
    }
    @try {
        [self setValue:entries.copy forKey:@"filteredEntries"];
    } @catch (__unused NSException *exception) {
        [self af_tokenizedReloadEntries];
        return;
    }
    [self.tableView reloadData];
    [self updateNavigationStatus];
    [self updateUnavailableConfiguration];
}

- (UITableViewCell *)af_search_tableView:(UITableView *)tableView
                   cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self af_search_tableView:tableView
                               cellForRowAtIndexPath:indexPath];
    id configuration = cell.contentConfiguration;
    if ([configuration isKindOfClass:UIListContentConfiguration.class]) {
        UIListContentConfiguration *content = [configuration copy];
        content.textProperties.font = FLEXScaledRuntimeFont(
            14.5,
            UIFontWeightMedium,
            UIFontTextStyleBody,
            18.0
        );
        content.secondaryTextProperties.font = FLEXScaledRuntimeFont(
            11.5,
            UIFontWeightRegular,
            UIFontTextStyleCaption1,
            15.0
        );
        content.secondaryTextProperties.numberOfLines = 3;
        cell.contentConfiguration = content;
    }
    return cell;
}

@end
