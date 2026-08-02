#import "FLEXHookPersistence.h"

NSNotificationName const FLEXHookFlagsDidChangeNotification = @"FLEXHookFlagsDidChangeNotification";

@interface FLEXHookFlag ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSString *detail;
@property (nonatomic, readwrite) BOOL defaultValue;
@end

@implementation FLEXHookFlag
@end

@interface FLEXHookInstallEntry : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) FLEXHookInstallBlock block;
@end

@implementation FLEXHookInstallEntry
@end

@interface FLEXHookPersistence ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) NSMutableArray<FLEXHookFlag *> *mutableFlags;
@property (nonatomic, strong) NSMutableDictionary<NSString *, FLEXHookFlag *> *flagsByIdentifier;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *cachedValues;
@property (nonatomic, strong) NSMutableDictionary<NSString *, FLEXHookInstallEntry *> *installEntries;
@property (nonatomic, strong) NSMutableSet<NSString *> *installedIdentifiers;
@property (nonatomic) BOOL hooksActivated;
@end

@implementation FLEXHookPersistence

+ (instancetype)sharedManager {
    static FLEXHookPersistence *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [FLEXHookPersistence new];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // standardUserDefaults is already isolated by the signed host app's
        // sandbox. A custom app-group suite would require an entitlement and is
        // therefore less reliable for certificate sideloading.
        _defaults = NSUserDefaults.standardUserDefaults;
        _mutableFlags = [NSMutableArray array];
        _flagsByIdentifier = [NSMutableDictionary dictionary];
        _cachedValues = [NSMutableDictionary dictionary];
        _installEntries = [NSMutableDictionary dictionary];
        _installedIdentifiers = [NSMutableSet set];
    }
    return self;
}

- (NSString *)storageKeyForIdentifier:(NSString *)identifier {
    return [@"com.allflexing.flags." stringByAppendingString:identifier];
}

- (void)registerFlag:(NSString *)identifier
                title:(NSString *)title
               detail:(NSString *)detail
         defaultValue:(BOOL)defaultValue {
    if (identifier.length == 0 || title.length == 0) {
        return;
    }

    @synchronized (self) {
        if (self.flagsByIdentifier[identifier]) {
            return;
        }

        FLEXHookFlag *flag = [FLEXHookFlag new];
        flag.identifier = identifier;
        flag.title = title;
        flag.detail = detail ?: @"";
        flag.defaultValue = defaultValue;

        NSString *storageKey = [self storageKeyForIdentifier:identifier];
        id persisted = [self.defaults objectForKey:storageKey];
        BOOL value = persisted ? [persisted boolValue] : defaultValue;

        self.flagsByIdentifier[identifier] = flag;
        self.cachedValues[identifier] = @(value);
        [self.mutableFlags addObject:flag];
    }
}

- (void)registerInstallOnce:(NSString *)identifier
                       title:(NSString *)title
                      detail:(NSString *)detail
                defaultValue:(BOOL)defaultValue
                       block:(FLEXHookInstallBlock)block {
    if (!block) {
        return;
    }

    [self registerFlag:identifier title:title detail:detail defaultValue:defaultValue];

    FLEXHookInstallEntry *entryToInstall = nil;
    @synchronized (self) {
        if (!self.installEntries[identifier]) {
            FLEXHookInstallEntry *entry = [FLEXHookInstallEntry new];
            entry.identifier = identifier;
            entry.block = block;
            self.installEntries[identifier] = entry;
        }

        if (self.hooksActivated && ![self.installedIdentifiers containsObject:identifier]) {
            [self.installedIdentifiers addObject:identifier];
            entryToInstall = self.installEntries[identifier];
        }
    }

    if (entryToInstall) {
        [self installEntry:entryToInstall];
    }
}

- (BOOL)boolForFlag:(NSString *)identifier {
    if (identifier.length == 0) {
        return NO;
    }

    @synchronized (self) {
        NSNumber *cached = self.cachedValues[identifier];
        if (cached) {
            return cached.boolValue;
        }

        FLEXHookFlag *flag = self.flagsByIdentifier[identifier];
        return flag ? flag.defaultValue : NO;
    }
}

- (void)setBool:(BOOL)value forFlag:(NSString *)identifier {
    if (identifier.length == 0) {
        return;
    }

    BOOL changed = NO;
    @synchronized (self) {
        NSNumber *previous = self.cachedValues[identifier];
        changed = !previous || previous.boolValue != value;
        self.cachedValues[identifier] = @(value);
        [self.defaults setBool:value forKey:[self storageKeyForIdentifier:identifier]];
    }

    if (!changed) {
        return;
    }

    dispatch_block_t notification = ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:FLEXHookFlagsDidChangeNotification
                          object:self
                        userInfo:@{ @"identifier": identifier }];
    };
    if (NSThread.isMainThread) {
        notification();
    } else {
        dispatch_async(dispatch_get_main_queue(), notification);
    }
}

- (NSArray<FLEXHookFlag *> *)registeredFlags {
    @synchronized (self) {
        return [self.mutableFlags copy];
    }
}

- (NSString *)storageDomainDescription {
    return NSBundle.mainBundle.bundleIdentifier ?: NSProcessInfo.processInfo.processName ?: @"host app";
}

- (void)activateRegisteredHooks {
    NSArray<FLEXHookInstallEntry *> *entries = nil;
    @synchronized (self) {
        self.hooksActivated = YES;

        NSMutableArray *pending = [NSMutableArray array];
        for (NSString *identifier in self.installEntries) {
            if (![self.installedIdentifiers containsObject:identifier]) {
                [self.installedIdentifiers addObject:identifier];
                [pending addObject:self.installEntries[identifier]];
            }
        }
        entries = [pending copy];
    }

    for (FLEXHookInstallEntry *entry in entries) {
        [self installEntry:entry];
    }
}

- (void)installEntry:(FLEXHookInstallEntry *)entry {
    @try {
        entry.block();
        NSLog(@"[AllFLEXing] install-once hook installed: %@", entry.identifier);
    } @catch (NSException *exception) {
        NSLog(@"[AllFLEXing] install-once hook failed %@: %@", entry.identifier, exception);
    }
}

@end

__attribute__((visibility("default"))) BOOL FLEXFlag(NSString *identifier) {
    return [FLEXHookPersistence.sharedManager boolForFlag:identifier];
}
