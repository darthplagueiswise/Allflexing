#import "FLEXPersistenceStore.h"

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
    "AllFLEXing host-scoped Keychain App Group persistence ABI 1";
const char *FLEXPersistenceHostIsolationABIVersion =
    "AllFLEXing no cross-host runtime catalog persistence ABI 1";

static NSString *const kFLEXPersistencePrefix = @"com.allflexing.";
static NSString *const kFLEXLegacyRegistryKey = @"com.allflexing.registry.v1";
static NSString *const kFLEXPersistenceLastWriteKey =
    @"com.allflexing.persistence.lastWrite.host.v1";
static NSString *const kFLEXPersistenceKeychainService =
    @"com.allflexing.persistence.snapshot.host.v1";
static NSInteger const kFLEXPersistenceSchema = 1;
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
@property (nonatomic, copy, readwrite, nullable) NSString *lastError;
@property (nonatomic, nullable) NSURL *sandboxMirrorURL;
@property (nonatomic, nullable) NSURL *groupMirrorURL;
@property (nonatomic) NSUInteger scheduledGeneration;
@end

@implementation FLEXPersistenceStore

+ (instancetype)sharedStore {
    static FLEXPersistenceStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [FLEXPersistenceStore new];
    });
    return store;
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
    _sandboxMirrorURL = [self sandboxMirrorURLCandidate];
    [self configureApplicationGroup];
    [self restoreNewestSnapshot];
    [self refreshStorageDescription];
    return self;
}

- (NSString *)snapshotDefaultsKey {
    return [@"com.allflexing.persistence.snapshot.host.v1."
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
        return;
    }
    self.usesApplicationGroup = NO;
}

- (NSURL *)sandboxMirrorURLCandidate {
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

- (void)refreshStorageDescription {
    NSString *keychain = self.usesKeychain
        ? @"host default Keychain access group"
        : @"Keychain unavailable";
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

- (NSDictionary<NSString *, id> *)persistableValues {
    NSDictionary<NSString *, id> *domain = self.standardDefaults.dictionaryRepresentation;
    NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionary];
    [domain enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if (![key hasPrefix:kFLEXPersistencePrefix] ||
            [key isEqualToString:kFLEXPersistenceLastWriteKey] ||
            [key isEqualToString:kFLEXLegacyRegistryKey]) {
            return;
        }
        values[key] = value;
    }];
    return values.copy;
}

- (NSDictionary *)currentDefaultsSnapshot {
    return @{
        @"schema": @(kFLEXPersistenceSchema),
        @"timestamp": @([self.standardDefaults
            doubleForKey:kFLEXPersistenceLastWriteKey]),
        @"host": self.hostScope,
        @"values": self.persistableValues,
    };
}

- (BOOL)validSnapshot:(id)object {
    if (![object isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *snapshot = object;
    return [snapshot[@"schema"] integerValue] == kFLEXPersistenceSchema &&
           [snapshot[@"host"] isEqualToString:self.hostScope] &&
           [snapshot[@"values"] isKindOfClass:NSDictionary.class];
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

- (NSMutableDictionary *)keychainQuery {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kFLEXPersistenceKeychainService,
        (__bridge id)kSecAttrAccount: self.hostScope,
    } mutableCopy];
}

- (nullable NSDictionary *)readKeychainSnapshot {
    NSMutableDictionary *query = self.keychainQuery;
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef rawResult = NULL;
    OSStatus status = SecItemCopyMatching(
        (__bridge CFDictionaryRef)query,
        &rawResult
    );
    self.usesKeychain = status == errSecSuccess || status == errSecItemNotFound;
    [self refreshStorageDescription];
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

- (void)addSnapshot:(NSDictionary *)snapshot
          priority:(NSInteger)priority
                 to:(NSMutableArray<NSDictionary *> *)candidates {
    if (![self validSnapshot:snapshot]) return;
    [candidates addObject:@{
        @"snapshot": snapshot,
        @"priority": @(priority),
    }];
}

- (BOOL)restoreNewestSnapshot {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSDictionary *current = self.currentDefaultsSnapshot;
    [self addSnapshot:current priority:10 to:candidates];
    [self addSnapshot:self.readKeychainSnapshot priority:100 to:candidates];

    id groupSnapshot = [self.groupDefaults objectForKey:self.snapshotDefaultsKey];
    [self addSnapshot:groupSnapshot priority:50 to:candidates];
    [self addSnapshot:[self snapshotFromURL:self.sandboxMirrorURL]
              priority:30
                    to:candidates];
    [self addSnapshot:[self snapshotFromURL:self.groupMirrorURL]
              priority:40
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

    // The unscoped v1 registry is deliberately never imported. It is the only
    // historic key capable of turning another host's discovered runtime rows
    // into a local catalogue.
    [self.standardDefaults removeObjectForKey:kFLEXLegacyRegistryKey];
    if (!winner) return NO;

    NSDictionary *newest = winner[@"snapshot"];
    NSDictionary<NSString *, id> *values = newest[@"values"];
    BOOL shouldRestore = ![values isEqual:current[@"values"]] ||
        [newest[@"timestamp"] doubleValue] >
            [current[@"timestamp"] doubleValue];
    if (!shouldRestore) return NO;

    NSDictionary<NSString *, id> *existing = self.standardDefaults.dictionaryRepresentation;
    for (NSString *key in existing) {
        if ([key hasPrefix:kFLEXPersistencePrefix] &&
            ![key isEqualToString:kFLEXPersistenceLastWriteKey] &&
            ![key isEqualToString:kFLEXLegacyRegistryKey] &&
            !values[key]) {
            [self.standardDefaults removeObjectForKey:key];
        }
    }
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if (![key isEqualToString:kFLEXLegacyRegistryKey]) {
            [self.standardDefaults setObject:value forKey:key];
        }
    }];
    [self.standardDefaults setDouble:[newest[@"timestamp"] doubleValue]
                              forKey:kFLEXPersistenceLastWriteKey];
    return YES;
}

- (NSDictionary *)freshSnapshot {
    NSTimeInterval timestamp = NSDate.date.timeIntervalSince1970;
    [self.standardDefaults setDouble:timestamp forKey:kFLEXPersistenceLastWriteKey];
    return @{
        @"schema": @(kFLEXPersistenceSchema),
        @"timestamp": @(timestamp),
        @"host": self.hostScope,
        @"values": self.persistableValues,
    };
}

- (BOOL)writeKeychainSnapshot:(NSDictionary *)snapshot error:(NSError **)error {
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:snapshot
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:error];
    if (!data) return NO;

    NSMutableDictionary *query = self.keychainQuery;
    OSStatus status = SecItemUpdate(
        (__bridge CFDictionaryRef)query,
        (__bridge CFDictionaryRef)@{
            (__bridge id)kSecValueData: data,
            (__bridge id)kSecAttrAccessible:
                (__bridge id)kSecAttrAccessibleAfterFirstUnlock,
        }
    );
    if (status == errSecItemNotFound) {
        query[(__bridge id)kSecValueData] = data;
        query[(__bridge id)kSecAttrAccessible] =
            (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    self.usesKeychain = status == errSecSuccess;
    if (status != errSecSuccess && error) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                      code:status
                                  userInfo:nil];
    }
    [self refreshStorageDescription];
    return status == errSecSuccess;
}

- (BOOL)writeSnapshot:(NSDictionary *)snapshot
                toURL:(NSURL *)URL
                 error:(NSError **)error {
    if (!URL) return YES;
    NSURL *directory = URL.URLByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager
            createDirectoryAtURL:directory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:error]) {
        return NO;
    }
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:snapshot
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:error];
    return data && [data writeToURL:URL options:NSDataWritingAtomic error:error];
}

- (BOOL)performSynchronization {
    NSDictionary *snapshot = self.freshSnapshot;
    BOOL success = YES;
    NSError *firstError = nil;

    NSError *keychainError = nil;
    if (![self writeKeychainSnapshot:snapshot error:&keychainError]) {
        success = NO;
        firstError = keychainError;
    }
    if (self.groupDefaults) {
        [self.groupDefaults setObject:snapshot forKey:self.snapshotDefaultsKey];
    }

    NSError *sandboxError = nil;
    if (![self writeSnapshot:snapshot
                       toURL:self.sandboxMirrorURL
                       error:&sandboxError]) {
        success = NO;
        if (!firstError) firstError = sandboxError;
    }
    NSError *groupError = nil;
    if (![self writeSnapshot:snapshot
                       toURL:self.groupMirrorURL
                       error:&groupError]) {
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
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
            self.queue,
            ^{
                if (generation == self.scheduledGeneration) {
                    [self performSynchronization];
                }
            }
        );
    });
}

@end
