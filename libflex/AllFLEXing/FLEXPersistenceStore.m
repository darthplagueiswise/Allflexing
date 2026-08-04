#import "FLEXPersistenceStore.h"

#import "FLEXHookRegistry.h"

#import <Security/Security.h>
#if __has_include(<Security/SecTask.h>)
#import <Security/SecTask.h>
#else
typedef struct CF_BRIDGED_TYPE(id) __SecTask *SecTaskRef;
extern SecTaskRef _Nullable SecTaskCreateFromSelf(CFAllocatorRef _Nullable allocator);
extern CFTypeRef _Nullable SecTaskCopyValueForEntitlement(
    SecTaskRef task,
    CFStringRef entitlement,
    CFErrorRef _Nullable * _Nullable error
);
#endif

const char *FLEXPersistenceStoreABIVersion =
    "AllFLEXing persistence app-group defaults atomic-mirror ABI 3";
const char *FLEXPersistenceSafeLaunchABIVersion =
    "AllFLEXing read-only persistence discovery ABI 1";
const char *FLEXPersistenceKeychainABIVersion =
    "AllFLEXing confirmed-state Keychain App Group mirror ABI 1";

static NSString *const kFLEXPersistencePrefix = @"com.allflexing.";
static NSString *const kFLEXPersistenceLastWriteKey =
    @"com.allflexing.persistence.lastWrite.v3";
static NSString *const kFLEXPersistenceLegacyLastWriteKey =
    @"com.allflexing.persistence.lastWrite.v2";
static NSString *const kFLEXPersistenceKeychainService =
    @"com.allflexing.persistence.snapshot";
static NSInteger const kFLEXPersistenceSchema = 3;
static const void *kFLEXPersistenceQueueSpecific = &kFLEXPersistenceQueueSpecific;

@interface FLEXPersistenceStore ()
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) NSUserDefaults *standardDefaults;
@property (nonatomic, nullable) NSUserDefaults *groupDefaults;
@property (nonatomic, copy, readwrite) NSString *storageDescription;
@property (nonatomic, copy, readwrite) NSString *hostScope;
@property (nonatomic, copy, readwrite, nullable) NSString *applicationGroupIdentifier;
@property (nonatomic, readwrite) BOOL usesApplicationGroup;
@property (nonatomic, readwrite) BOOL usesKeychain;
@property (nonatomic, copy, readwrite) NSString *keychainService;
@property (nonatomic, copy, readwrite) NSString *keychainAccount;
@property (nonatomic, copy, readwrite, nullable) NSString *keychainAccessGroup;
@property (nonatomic, readwrite) NSInteger lastKeychainStatus;
@property (nonatomic, copy, readwrite, nullable) NSString *lastError;
@property (nonatomic, nullable) NSURL *sandboxMirrorURL;
@property (nonatomic, nullable) NSURL *groupMirrorURL;
@property (nonatomic) NSUInteger scheduledGeneration;
@property (nonatomic) BOOL restoring;
@property (nonatomic) BOOL needsKeychainMigration;
@end

@implementation FLEXPersistenceStore

+ (instancetype)sharedStore {
    static FLEXPersistenceStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Deliberately lazy. The loader creates this store only after the user
        // opens Runtime Workspace, never from +load or launch activation.
        store = [FLEXPersistenceStore new];
    });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _queue = dispatch_queue_create(
        "com.allflexing.persistence-store",
        DISPATCH_QUEUE_SERIAL
    );
    dispatch_queue_set_specific(
        _queue,
        kFLEXPersistenceQueueSpecific,
        (void *)kFLEXPersistenceQueueSpecific,
        NULL
    );
    _standardDefaults = NSUserDefaults.standardUserDefaults;
    _hostScope = [self.class sanitizedScope:
        NSBundle.mainBundle.bundleIdentifier.length
            ? NSBundle.mainBundle.bundleIdentifier
            : NSProcessInfo.processInfo.processName];
    _keychainService = kFLEXPersistenceKeychainService;
    _keychainAccount = _hostScope;
    _lastKeychainStatus = errSecItemNotFound;

    // Discovery and restore remain read-only. No directory or Keychain item is
    // created merely because the Workspace initialized the store.
    _sandboxMirrorURL = [self createSandboxMirrorURL];
    [self configureApplicationGroup];
    [self restoreNewestSnapshot];
    [self refreshStorageDescription];

    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(registryDidChange:)
               name:FLEXHookRegistryDidChangeNotification
             object:nil];

    // Migrate an existing confirmed v2 snapshot only after the Workspace has
    // explicitly opened. This never runs from launch/+load.
    if (self.needsKeychainMigration) {
        [self synchronizeSoon];
    }
    return self;
}

+ (NSString *)sanitizedScope:(NSString *)value {
    NSString *source = value.length ? value : @"host";
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    NSMutableString *result = [NSMutableString stringWithCapacity:source.length];
    for (NSUInteger index = 0; index < source.length; index++) {
        unichar character = [source characterAtIndex:index];
        [result appendString:[allowed characterIsMember:character]
            ? [NSString stringWithCharacters:&character length:1]
            : @"_"];
    }
    return result.length ? result : @"host";
}

- (NSString *)snapshotDefaultsKey {
    return [@"com.allflexing.persistence.snapshot.v3."
        stringByAppendingString:self.hostScope];
}

- (NSString *)legacySnapshotDefaultsKey {
    return [@"com.allflexing.persistence.snapshot.v2."
        stringByAppendingString:self.hostScope];
}

- (NSArray<NSString *> *)entitledApplicationGroups {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return @[];

    CFErrorRef error = NULL;
    CFTypeRef rawValue = SecTaskCopyValueForEntitlement(
        task,
        CFSTR("com.apple.security.application-groups"),
        &error
    );
    CFRelease(task);
    if (error) CFRelease(error);
    if (!rawValue) return @[];

    id value = CFBridgingRelease(rawValue);
    if (![value isKindOfClass:NSArray.class]) return @[];

    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (id candidate in (NSArray *)value) {
        if ([candidate isKindOfClass:NSString.class] &&
            [candidate hasPrefix:@"group."]) {
            [groups addObject:candidate];
        }
    }
    return groups.copy;
}

- (void)configureApplicationGroup {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (NSString *identifier in self.entitledApplicationGroups) {
        NSURL *container = [fileManager
            containerURLForSecurityApplicationGroupIdentifier:identifier];
        if (!container) continue;

        NSUserDefaults *suite = [[NSUserDefaults alloc]
            initWithSuiteName:identifier];
        if (!suite) continue;

        NSURL *directory = [[[container URLByAppendingPathComponent:@"Library"
                                                         isDirectory:YES]
            URLByAppendingPathComponent:@"Application Support"
                            isDirectory:YES]
            URLByAppendingPathComponent:@"AllFLEXing"
                            isDirectory:YES];
        self.applicationGroupIdentifier = identifier;
        self.groupDefaults = suite;
        self.groupMirrorURL = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"state-%@.plist", self.hostScope]];
        self.usesApplicationGroup = YES;

        // App Group identifiers are also valid Keychain access groups when the
        // effective signature contains the entitlement. The identifier is
        // discovered from the current host at runtime; nothing is hard-coded to
        // a particular IPA, Team ID or bundle.
        self.keychainAccessGroup = identifier;
        return;
    }

    self.usesApplicationGroup = NO;
    self.keychainAccessGroup = nil;
}

- (void)refreshStorageDescription {
    NSString *keychain = self.usesKeychain
        ? (self.keychainAccessGroup.length
            ? [NSString stringWithFormat:@"Keychain %@", self.keychainAccessGroup]
            : @"host default Keychain access group")
        : [NSString stringWithFormat:@"Keychain unavailable (%ld)",
            (long)self.lastKeychainStatus];
    if (self.usesApplicationGroup) {
        self.storageDescription = [NSString stringWithFormat:
            @"%@ + App Group %@ + host defaults + atomic mirrors",
            keychain,
            self.applicationGroupIdentifier];
    } else {
        self.storageDescription = [NSString stringWithFormat:
            @"%@ + host defaults + atomic sandbox mirror",
            keychain];
    }
}

- (NSURL *)createSandboxMirrorURL {
    NSString *library = NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory,
        NSUserDomainMask,
        YES
    ).firstObject;
    NSURL *libraryURL = [NSURL fileURLWithPath:
        library.length ? library : NSTemporaryDirectory()
                                 isDirectory:YES];
    NSURL *directory = [[libraryURL
        URLByAppendingPathComponent:@"Application Support"
                        isDirectory:YES]
        URLByAppendingPathComponent:@"AllFLEXing"
                        isDirectory:YES];
    return [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"state-%@.plist", self.hostScope]];
}

- (NSDictionary<NSString *, id> *)allFLEXingValues {
    NSDictionary<NSString *, id> *domain = self.standardDefaults.dictionaryRepresentation;
    NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionary];
    [domain enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if ([key hasPrefix:kFLEXPersistencePrefix] &&
            ![key isEqualToString:kFLEXPersistenceLastWriteKey] &&
            ![key isEqualToString:kFLEXPersistenceLegacyLastWriteKey]) {
            values[key] = value;
        }
    }];
    return values.copy;
}

- (NSTimeInterval)currentTimestamp {
    NSTimeInterval timestamp = [self.standardDefaults
        doubleForKey:kFLEXPersistenceLastWriteKey];
    if (timestamp <= 0) {
        timestamp = [self.standardDefaults
            doubleForKey:kFLEXPersistenceLegacyLastWriteKey];
    }
    return timestamp;
}

- (NSDictionary *)currentDefaultsSnapshot {
    return @{
        @"schema": @(kFLEXPersistenceSchema),
        @"timestamp": @([self currentTimestamp]),
        @"host": self.hostScope,
        @"values": self.allFLEXingValues,
    };
}

- (nullable NSDictionary *)snapshotFromURL:(NSURL *)URL {
    if (!URL) return nil;
    NSData *data = [NSData dataWithContentsOfURL:URL options:0 error:nil];
    if (!data.length) return nil;
    id object = [NSPropertyListSerialization
        propertyListWithData:data
                     options:NSPropertyListImmutable
                      format:NULL
                       error:nil];
    return [self validSnapshot:object] ? object : nil;
}

- (BOOL)validSnapshot:(id)object {
    if (![object isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *snapshot = object;
    NSInteger schema = [snapshot[@"schema"] integerValue];
    return (schema == 2 || schema == kFLEXPersistenceSchema) &&
           [snapshot[@"host"] isEqualToString:self.hostScope] &&
           [snapshot[@"values"] isKindOfClass:NSDictionary.class];
}

- (NSMutableDictionary *)keychainQueryForAccessGroup:(nullable NSString *)accessGroup {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: self.keychainService,
        (__bridge id)kSecAttrAccount: self.keychainAccount,
    } mutableCopy];
    if (accessGroup.length) {
        query[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    }
    return query;
}

- (nullable NSDictionary *)keychainSnapshotForAccessGroup:(nullable NSString *)accessGroup
                                                   status:(OSStatus *)statusOut {
    NSMutableDictionary *query = [self keychainQueryForAccessGroup:accessGroup];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef rawResult = NULL;
    OSStatus status = SecItemCopyMatching(
        (__bridge CFDictionaryRef)query,
        &rawResult
    );
    if (statusOut) *statusOut = status;
    if (status != errSecSuccess || !rawResult) {
        if (rawResult) CFRelease(rawResult);
        return nil;
    }

    id result = CFBridgingRelease(rawResult);
    if (![result isKindOfClass:NSData.class]) return nil;
    id object = [NSPropertyListSerialization
        propertyListWithData:result
                     options:NSPropertyListImmutable
                      format:NULL
                       error:nil];
    return [self validSnapshot:object] ? object : nil;
}

- (nullable NSDictionary *)readKeychainSnapshot {
    OSStatus status = errSecItemNotFound;
    NSDictionary *snapshot = nil;

    if (self.keychainAccessGroup.length) {
        snapshot = [self keychainSnapshotForAccessGroup:self.keychainAccessGroup
                                                 status:&status];
    }
    if (!snapshot) {
        // Omitting kSecAttrAccessGroup is intentionally generic: Keychain
        // Services searches the access groups granted to the current host and
        // uses the host's default group for new items.
        snapshot = [self keychainSnapshotForAccessGroup:nil status:&status];
    }

    self.lastKeychainStatus = status;
    self.usesKeychain = status == errSecSuccess || status == errSecItemNotFound;
    [self refreshStorageDescription];
    return snapshot;
}

- (void)addCandidateSnapshot:(NSDictionary *)snapshot
                      source:(NSString *)source
                    priority:(NSInteger)priority
                          to:(NSMutableArray<NSDictionary *> *)candidates {
    if (![self validSnapshot:snapshot]) return;
    [candidates addObject:@{
        @"snapshot": snapshot,
        @"source": source,
        @"priority": @(priority),
    }];
}

- (void)restoreNewestSnapshot {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSDictionary *current = self.currentDefaultsSnapshot;
    [self addCandidateSnapshot:current source:@"defaults" priority:10 to:candidates];

    NSDictionary *keychain = [self readKeychainSnapshot];
    [self addCandidateSnapshot:keychain source:@"keychain" priority:100 to:candidates];

    id groupSnapshot = [self.groupDefaults objectForKey:self.snapshotDefaultsKey];
    [self addCandidateSnapshot:groupSnapshot source:@"group-defaults-v3" priority:40 to:candidates];
    id legacyGroupSnapshot = [self.groupDefaults objectForKey:self.legacySnapshotDefaultsKey];
    [self addCandidateSnapshot:legacyGroupSnapshot source:@"group-defaults-v2" priority:35 to:candidates];

    [self addCandidateSnapshot:[self snapshotFromURL:self.sandboxMirrorURL]
                        source:@"sandbox-file"
                      priority:30
                            to:candidates];
    [self addCandidateSnapshot:[self snapshotFromURL:self.groupMirrorURL]
                        source:@"group-file"
                      priority:45
                            to:candidates];

    NSDictionary *winner = [candidates sortedArrayUsingComparator:^NSComparisonResult(
        NSDictionary *left,
        NSDictionary *right
    ) {
        NSDictionary *leftSnapshot = left[@"snapshot"];
        NSDictionary *rightSnapshot = right[@"snapshot"];
        NSComparisonResult timeResult = [rightSnapshot[@"timestamp"]
            compare:leftSnapshot[@"timestamp"]];
        if (timeResult != NSOrderedSame) return timeResult;
        return [right[@"priority"] compare:left[@"priority"]];
    }].firstObject;
    if (!winner) return;

    NSDictionary *newest = winner[@"snapshot"];
    NSString *source = winner[@"source"];
    BOOL sourceIsDefaults = [source isEqualToString:@"defaults"];
    BOOL valuesDiffer = ![newest[@"values"] isEqual:current[@"values"]];
    BOOL timestampNewer = [newest[@"timestamp"] doubleValue] >
        [current[@"timestamp"] doubleValue];

    if (!sourceIsDefaults && (valuesDiffer || timestampNewer ||
        [source isEqualToString:@"keychain"])) {
        self.restoring = YES;
        NSDictionary<NSString *, id> *values = newest[@"values"];
        NSDictionary<NSString *, id> *existing = self.standardDefaults.dictionaryRepresentation;
        for (NSString *key in existing) {
            if ([key hasPrefix:kFLEXPersistencePrefix] &&
                ![key isEqualToString:kFLEXPersistenceLastWriteKey] &&
                ![key isEqualToString:kFLEXPersistenceLegacyLastWriteKey] &&
                !values[key]) {
                [self.standardDefaults removeObjectForKey:key];
            }
        }
        [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            (void)stop;
            [self.standardDefaults setObject:value forKey:key];
        }];
        [self.standardDefaults setDouble:[newest[@"timestamp"] doubleValue]
                                  forKey:kFLEXPersistenceLastWriteKey];
        self.restoring = NO;
    }

    self.needsKeychainMigration = keychain == nil &&
        [newest[@"timestamp"] doubleValue] > 0;
}

- (NSDictionary *)freshSnapshot {
    NSTimeInterval timestamp = NSDate.date.timeIntervalSince1970;
    [self.standardDefaults setDouble:timestamp forKey:kFLEXPersistenceLastWriteKey];
    return @{
        @"schema": @(kFLEXPersistenceSchema),
        @"timestamp": @(timestamp),
        @"host": self.hostScope,
        @"values": self.allFLEXingValues,
    };
}

- (BOOL)writeSnapshot:(NSDictionary *)snapshot toURL:(NSURL *)URL error:(NSError **)error {
    if (!URL) return YES;

    NSURL *directory = URL.URLByDeletingLastPathComponent;
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager
            createDirectoryAtURL:directory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&directoryError]) {
        if (error) *error = directoryError;
        return NO;
    }

    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:snapshot
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:error];
    if (!data) return NO;
    return [data writeToURL:URL options:NSDataWritingAtomic error:error];
}

- (OSStatus)writeKeychainData:(NSData *)data
                  accessGroup:(nullable NSString *)accessGroup {
    NSMutableDictionary *query = [self keychainQueryForAccessGroup:accessGroup];
    NSDictionary *updates = @{
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible:
            (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
    };

    OSStatus status = SecItemUpdate(
        (__bridge CFDictionaryRef)query,
        (__bridge CFDictionaryRef)updates
    );
    if (status == errSecItemNotFound) {
        [query addEntriesFromDictionary:updates];
        query[(__bridge id)kSecAttrLabel] = @"AllFLEXing confirmed runtime state";
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
        if (status == errSecDuplicateItem) {
            status = SecItemUpdate(
                (__bridge CFDictionaryRef)[self keychainQueryForAccessGroup:accessGroup],
                (__bridge CFDictionaryRef)updates
            );
        }
    }
    return status;
}

- (BOOL)writeSnapshotToKeychain:(NSDictionary *)snapshot {
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:snapshot
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:&serializationError];
    if (!data) {
        self.lastError = serializationError.localizedDescription;
        self.usesKeychain = NO;
        return NO;
    }

    OSStatus status = errSecItemNotFound;
    if (self.keychainAccessGroup.length) {
        status = [self writeKeychainData:data accessGroup:self.keychainAccessGroup];
    }
    if (!self.keychainAccessGroup.length ||
        status == errSecMissingEntitlement ||
        status == errSecItemNotFound) {
        status = [self writeKeychainData:data accessGroup:nil];
    }

    self.lastKeychainStatus = status;
    self.usesKeychain = status == errSecSuccess;
    self.needsKeychainMigration = !self.usesKeychain;
    [self refreshStorageDescription];
    return status == errSecSuccess;
}

- (NSString *)keychainErrorDescription:(OSStatus)status {
    CFStringRef message = SecCopyErrorMessageString(status, NULL);
    if (!message) {
        return [NSString stringWithFormat:@"Keychain error %ld", (long)status];
    }
    return CFBridgingRelease(message);
}

- (BOOL)performSynchronization {
    NSDictionary *snapshot = [self freshSnapshot];
    BOOL success = YES;
    NSError *firstError = nil;

    if (![self writeSnapshotToKeychain:snapshot]) {
        success = NO;
        firstError = [NSError errorWithDomain:@"FLEXPersistenceStore.Keychain"
                                         code:self.lastKeychainStatus
                                     userInfo:@{
            NSLocalizedDescriptionKey:
                [self keychainErrorDescription:(OSStatus)self.lastKeychainStatus]
        }];
    }

    if (self.groupDefaults) {
        [self.groupDefaults setObject:snapshot forKey:self.snapshotDefaultsKey];
    }

    NSError *sandboxError = nil;
    if (![self writeSnapshot:snapshot toURL:self.sandboxMirrorURL error:&sandboxError]) {
        success = NO;
        if (!firstError) firstError = sandboxError;
    }
    NSError *groupError = nil;
    if (![self writeSnapshot:snapshot toURL:self.groupMirrorURL error:&groupError]) {
        success = NO;
        if (!firstError) firstError = groupError;
    }
    self.lastError = firstError.localizedDescription;
    return success;
}

- (BOOL)synchronizeNow {
    __block BOOL success = NO;
    if (dispatch_get_specific(kFLEXPersistenceQueueSpecific)) {
        success = [self performSynchronization];
    } else {
        dispatch_sync(self.queue, ^{
            success = [self performSynchronization];
        });
    }
    return success;
}

- (void)synchronizeSoon {
    dispatch_async(self.queue, ^{
        self.scheduledGeneration += 1;
        NSUInteger generation = self.scheduledGeneration;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
            self.queue,
            ^{
                if (generation != self.scheduledGeneration) return;
                [self performSynchronization];
            }
        );
    });
}

- (void)registryDidChange:(NSNotification *)notification {
    NSString *reason = [notification.userInfo[@"reason"]
        isKindOfClass:NSString.class] ? notification.userInfo[@"reason"] : @"";
    static NSSet<NSString *> *committedReasons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        committedReasons = [NSSet setWithArray:@[
            @"apply-finish",
            @"runtime-toggle-applied",
            @"runtime-verification-failed",
        ]];
    });
    if ([committedReasons containsObject:reason]) {
        [self synchronizeSoon];
    }
}

@end
