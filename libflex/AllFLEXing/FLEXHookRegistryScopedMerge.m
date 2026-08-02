#import "FLEXHookRegistry.h"

@interface FLEXHookRegistry (AllFLEXingScopedMergePrivate)
@property (nonatomic) NSMutableArray<FLEXHookEntry *> *mutableEntries;
@property (nonatomic) NSMutableDictionary<NSString *, FLEXHookEntry *> *entriesByIdentifier;
- (void)persistEntries;
- (void)postChange:(NSString *)reason;
@end

static BOOL FLEXEntryBelongsToScannedPaths(FLEXHookEntry *entry,
                                           NSSet<NSString *> *paths,
                                           NSSet<NSString *> *names) {
    NSString *path = [entry.locator[@"image"] isKindOfClass:NSString.class]
        ? entry.locator[@"image"] : nil;
    if (path.length && [paths containsObject:path]) {
        return YES;
    }
    NSString *name = path.lastPathComponent.length
        ? path.lastPathComponent : entry.imageName;
    return name.length && [names containsObject:name];
}

@implementation FLEXHookRegistry (AllFLEXingScopedMerge)

- (NSArray<FLEXHookEntry *> *)mergeDiscoveredEntries:(NSArray<FLEXHookEntry *> *)entries
                                              surface:(FLEXHookSurface)surface
                                           imagePaths:(NSArray<NSString *> *)imagePaths {
    NSSet<NSString *> *paths = [NSSet setWithArray:imagePaths ?: @[]];
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    for (NSString *path in paths) {
        if (path.lastPathComponent.length) {
            [names addObject:path.lastPathComponent];
        }
    }

    NSMutableArray<FLEXHookEntry *> *resolvedEntries =
        [NSMutableArray arrayWithCapacity:entries.count];
    @synchronized (self) {
        for (FLEXHookEntry *existing in self.mutableEntries) {
            if (existing.surface == surface && !existing.userConfigured &&
                FLEXEntryBelongsToScannedPaths(existing, paths, names)) {
                existing.available = NO;
                existing.hookable = NO;
                existing.stale = YES;
                existing.lastError = @"Not found in the latest selected-image scan";
            }
        }

        for (FLEXHookEntry *discovered in entries) {
            if (!discovered.identifier.length) {
                continue;
            }
            FLEXHookEntry *existing = self.entriesByIdentifier[discovered.identifier];
            if (!existing) {
                self.entriesByIdentifier[discovered.identifier] = discovered;
                [self.mutableEntries addObject:discovered];
                [resolvedEntries addObject:discovered];
                continue;
            }

            NSString *previousUUID = [existing.locator[@"imageUUID"]
                isKindOfClass:NSString.class] ? existing.locator[@"imageUUID"] : nil;
            NSString *newUUID = [discovered.locator[@"imageUUID"]
                isKindOfClass:NSString.class] ? discovered.locator[@"imageUUID"] : nil;
            BOOL identityChanged = existing.userConfigured &&
                previousUUID.length && newUUID.length &&
                [previousUUID caseInsensitiveCompare:newUUID] != NSOrderedSame;

            existing.title = discovered.title;
            existing.detail = discovered.detail;
            existing.imageName = discovered.imageName;
            existing.surface = discovered.surface;
            existing.locator = discovered.locator;
            existing.available = discovered.available;
            existing.stale = discovered.stale;

            if (identityChanged) {
                existing.abi = FLEXHookABIUnknown;
                existing.backend = discovered.backend;
                existing.desiredEnabled = NO;
                existing.pendingEnabled = NO;
                existing.effectiveEnabled = NO;
                existing.hookable = NO;
                existing.stale = YES;
                existing.lastError = @"Selected image UUID changed; resolve ABI again";
            } else {
                if (!existing.userConfigured || existing.abi == FLEXHookABIUnknown) {
                    existing.abi = discovered.abi;
                }
                if (!existing.userConfigured || existing.backend == FLEXHookBackendNone ||
                    existing.backend == FLEXHookBackendAuto) {
                    existing.backend = discovered.backend;
                }
                existing.hookable = existing.available &&
                    existing.abi != FLEXHookABIUnknown &&
                    existing.backend != FLEXHookBackendNone &&
                    existing.backend != FLEXHookBackendAuto &&
                    existing.backend != FLEXHookBackendDobby;
                existing.lastError = existing.hookable
                    ? nil : discovered.lastError;
            }
            [resolvedEntries addObject:existing];
        }

        [self.mutableEntries sortUsingComparator:^NSComparisonResult(
            FLEXHookEntry *left,
            FLEXHookEntry *right
        ) {
            if (left.surface != right.surface) {
                return left.surface < right.surface
                    ? NSOrderedAscending : NSOrderedDescending;
            }
            NSComparisonResult imageResult =
                [left.imageName localizedCaseInsensitiveCompare:right.imageName];
            return imageResult == NSOrderedSame
                ? [left.title localizedCaseInsensitiveCompare:right.title]
                : imageResult;
        }];
    }

    [self persistEntries];
    [self postChange:@"selected-image-scan"];
    return resolvedEntries.copy;
}

@end
