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
    "AllFLEXing persistence app-group defaults atomic-mirror ABI 2";

static NSString *const kFLEXPersistencePrefix = @"com.allflexing.";
static NSString *const kFLEXPersistenceLastWriteKey =
    @"com.allflexing.persistence.lastWrite.v2";
static NSInteger const kFLEXPersistenceSchema = 2;
static const void *kFLEXPersistenceQueueSpecific = &kFLEXPersistenceQueueSpecific;

@interface FLEXPersistenceStore ()
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) NSUserDefaults *standardDefaults;
@property (nonatomic, nullable) NSUserDefaults *groupDefaults;
@property (nonatomic, copy, readwrite) NSString *storageDescription;
@property (nonatomic, copy, readwrite) NSString *hostScope;
@property (nonatomic, copy, readwrite, nullable) NSString *applicationGroupIdentifier;
@property (nonatomic, readwrite) BOOL usesApplicationGroup;
@property (nonatomic, copy, readwrite, nullable) NSString *lastError;
@property (nonatomic, nullable) NSURL *sandboxMirrorURL;
@property (nonatomic, nullable) NSURL *groupMirrorURL;
@property (nonatomic) NSUInteger scheduledGeneration;
@property (nonatomic) BOOL restoring;
@end

@implementation FLEXPersistenceStore

+ (void)load {
    @autoreleasepool {
        // +load runs before the loader/registry constructors. This lets a newer
        // App Group or file snapshot repopulate standardUserDefaults before the
        // runtime registry reads its desired state.
        (void)self.sharedStore;
    }
}

+ (instancetype)sharedStore {
    static FLEXPersistenceStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [FLEXPersistenceStore new];
    });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }

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
    _sandboxMirrorURL = [self sandboxMirrorURL];
    [self configureApplicationGroup];
    [self restoreNewestSnapshot];

    // Consolidate/migrate the selected state into every writable backend.
    [self synchronizeNow];
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
    return [@"com.allflexing.persistence.snapshot.v2."
        stringByAppendingString:self.hostScope];
}

- (NSArray<NSString *> *)entitledApplicationGroups {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) {
        return @[];
    }
    CFErrorRef error = NULL;
    CFTypeRef rawValue = SecTaskCopyValueForEntitlement(
        task,
        CFSTR("com.apple.security.application-groups"),
        &error
    );
    CFRelease(task);
    if (error) {
        CFRelease(error);
    }
    if (!rawValue) {
        return @[];
    }
    id value = CFBridgingRelease(rawValue);
    if (![value isKindOfClass:NSArray.class]) {
        return @[];
    }
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
        if (!container) {
            continue;
        }
        NSURL *directory = [[[container URLByAppendingPathComponent:@"Library"
                                                         isDirectory:YES]
            URLByAppendingPathComponent:@"Application Support"
                            isDirectory:YES]
            URLByAppendingPathComponent:@"AllFLEXing"
                            isDirectory:YES];
        NSError *directoryError = nil;
        if (![fileManager createDirectoryAtURL:directory
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&directoryError]) {
            continue;
        }

        NSURL *probe = [directory URLByAppendingPathComponent:@".write-probe"];
        NSData *probeData = [@"ok" dataUsingEncoding:NSUTF8StringEncoding];
        NSError *probeError = nil;
        BOOL writable = [probeData writeToURL:probe
                                      options:NSDataWritingAtomic
                                        error:&probeError];
        if (!writable) {
            continue;
        }
        [fileManager removeItemAtURL:probe error:nil];

        NSUserDefaults *suite = [[NSUserDefaults alloc]
            initWithSuiteName:identifier];
        if (!suite) {
            continue;
        }
        self.applicationGroupIdentifier = identifier;
        self.groupDefaults = suite;
        self.groupMirrorURL = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"state-%@.plist", self.hostScope]];
        self.usesApplicationGroup = YES;
        self.storageDescription = [NSString stringWithFormat:
            @"App Group %@ + host NSUserDefaults + atomic sandbox/group mirrors",
            identifier];
        return;
    }

    self.usesApplicationGroup = NO;
    self.storageDescription =
        @"Host NSUserDefaults + atomic sandbox mirror (no valid App Group entitlement)";
}

- (NSURL *)sandboxMirrorURL {
    NSError *error = nil;
    NSURL *applicationSupport = [NSFileManager.defaultManager
        URLForDirectory:NSApplicationSupportDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil
                 create:YES
                  error:&error];
    if (!applicationSupport) {
        NSString *library = NSSearchPathForDirectoriesInDomains(
            NSLibraryDirectory,
            NSUserDomainMask,
            YES
        ).firstObject;
        applicationSupport = [[NSURL fileURLWithPath:library ?: NSTemporaryDirectory()
                                         isDirectory:YES]
            URLByAppendingPathComponent:@"Application Support"
                            isDirectory:YES];
    }
    NSURL *directory = [applicationSupport
        URLByAppendingPathComponent:@"AllFLEXing"
                        isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    return [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"state-%@.plist", self.hostScope]];
}

- (NSDictionary<NSString *, id> *)allFLEXingValues {
    NSDictionary<NSString *, id> *domain = self.standardDefaults.dictionaryRepresentation;
    NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionary];
    [domain enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if ([key hasPrefix:kFLEXPersistencePrefix] &&
            ![key isEqualToString:kFLEXPersistenceLastWriteKey]) {
            values[key] = value;
        }
    }];
    return values.copy;
}

- (NSDictionary *)currentDefaultsSnapshot {
    NSTimeInterval timestamp = [self.standardDefaults
        doubleForKey:kFLEXPersistenceLastWriteKey];
    return @{
        @"schema": @(kFLEXPersistenceSchema),
        @"timestamp": @(timestamp),
        @"host": self.hostScope,
        @"values": self.allFLEXingValues,
    };
}

- (nullable NSDictionary *)snapshotFromURL:(NSURL *)URL {
    if (!URL) {
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:URL options:0 error:nil];
    if (!data.length) {
        return nil;
    }
    id object = [NSPropertyListSerialization
        propertyListWithData:data
                     options:NSPropertyListImmutable
                      format:NULL
                       error:nil];
    return [self validSnapshot:object] ? object : nil;
}

- (BOOL)validSnapshot:(id)object {
    if (![object isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSDictionary *snapshot = object;
    return [snapshot[@"schema"] integerValue] == kFLEXPersistenceSchema &&
           [snapshot[@"host"] isEqualToString:self.hostScope] &&
           [snapshot[@"values"] isKindOfClass:NSDictionary.class];
}

- (void)restoreNewestSnapshot {
    NSMutableArray<NSDictionary *> *snapshots = [NSMutableArray array];
    NSDictionary *current = self.currentDefaultsSnapshot;
    if ([self validSnapshot:current]) {
        [snapshots addObject:current];
    }
    id groupSnapshot = [self.groupDefaults objectForKey:self.snapshotDefaultsKey];
    if ([self validSnapshot:groupSnapshot]) {
        [snapshots addObject:groupSnapshot];
    }
    NSDictionary *sandboxSnapshot = [self snapshotFromURL:self.sandboxMirrorURL];
    if (sandboxSnapshot) {
        [snapshots addObject:sandboxSnapshot];
    }
    NSDictionary *groupFileSnapshot = [self snapshotFromURL:self.groupMirrorURL];
    if (groupFileSnapshot) {
        [snapshots addObject:groupFileSnapshot];
    }
    NSDictionary *newest = [snapshots sortedArrayUsingComparator:^NSComparisonResult(
        NSDictionary *left,
        NSDictionary *right
    ) {
        return [right[@"timestamp"] compare:left[@"timestamp"]];
    }].firstObject;
    if (!newest || [newest[@"timestamp"] doubleValue] <=
        [current[@"timestamp"] doubleValue]) {
        return;
    }

    self.restoring = YES;
    NSDictionary<NSString *, id> *values = newest[@"values"];
    NSDictionary<NSString *, id> *existing = self.standardDefaults.dictionaryRepresentation;
    for (NSString *key in existing) {
        if ([key hasPrefix:kFLEXPersistencePrefix] &&
            ![key isEqualToString:kFLEXPersistenceLastWriteKey] &&
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
    [self.standardDefaults synchronize];
    self.restoring = NO;
}

- (NSDictionary *)freshSnapshot {
    NSTimeInterval timestamp = NSDate.date.timeIntervalSince1970;
    [self.standardDefaults setDouble:timestamp forKey:kFLEXPersistenceLastWriteKey];
    [self.standardDefaults synchronize];
    return @{
        @"schema": @(kFLEXPersistenceSchema),
        @"timestamp": @(timestamp),
        @"host": self.hostScope,
        @"values": self.allFLEXingValues,
    };
}

- (BOOL)writeSnapshot:(NSDictionary *)snapshot toURL:(NSURL *)URL error:(NSError **)error {
    if (!URL) {
        return YES;
    }
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:snapshot
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:error];
    if (!data) {
        return NO;
    }
    return [data writeToURL:URL options:NSDataWritingAtomic error:error];
}

- (BOOL)performSynchronization {
    NSDictionary *snapshot = [self freshSnapshot];
    BOOL success = YES;
    NSError *firstError = nil;

    if (self.groupDefaults) {
        [self.groupDefaults setObject:snapshot forKey:self.snapshotDefaultsKey];
        if (![self.groupDefaults synchronize]) {
            success = NO;
        }
    }

    NSError *sandboxError = nil;
    if (![self writeSnapshot:snapshot toURL:self.sandboxMirrorURL error:&sandboxError]) {
        success = NO;
        firstError = sandboxError;
    }
    NSError *groupError = nil;
    if (![self writeSnapshot:snapshot toURL:self.groupMirrorURL error:&groupError]) {
        success = NO;
        if (!firstError) {
            firstError = groupError;
        }
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
                if (generation != self.scheduledGeneration) {
                    return;
                }
                [self performSynchronization];
            }
        );
    });
}

@end
