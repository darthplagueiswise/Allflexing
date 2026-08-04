#import "FLEXCHookEngine.h"

#import "FLEXHookPersistence.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <string.h>

const char *FLEXAddressCHookEngineABIVersion =
    "AllFLEXing image-UUID executable-address C hook engine ABI 1";

#define FLEX_ADDRESS_SLOT_COUNT 32
#define FLEX_ADDRESS_SLOTS_PER_ABI 8

typedef struct {
    atomic_bool allocated;
    atomic_bool enabled;
    atomic_bool forceBool;
    atomic_llong forceInt64;
    atomic_uintptr_t forcePointer;
    atomic_ullong hits;
    atomic_ullong overrideHits;
    void *original;
    FLEXHookABI abi;
    char identifier[256];
} FLEXAddressHookSlot;

static FLEXAddressHookSlot gFLEXAddressSlots[FLEX_ADDRESS_SLOT_COUNT];

static NSError *FLEXAddressHookError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"FLEXAddressCHookEngine"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey:
                               message ?: @"Unknown address-hook error"}];
}

static BOOL FLEXAddressPathMatches(NSString *requested, NSString *loaded) {
    if (!requested.length || !loaded.length) return NO;
    if ([requested containsString:@"/"]) {
        return [requested isEqualToString:loaded];
    }
    return [requested.lastPathComponent isEqualToString:loaded.lastPathComponent];
}

static NSString *FLEXAddressUUID(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) return @"";
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuidCommand =
                (const struct uuid_command *)command;
            NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:uuidCommand->uuid];
            return uuid.UUIDString ?: @"";
        }
        cursor += command->cmdsize;
    }
    return @"";
}

static BOOL FLEXAddressFindImage(NSString *requested,
                                 const struct mach_header_64 **headerOut,
                                 intptr_t *slideOut,
                                 NSString **pathOut) {
    if (!requested.length) return NO;
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *header = _dyld_get_image_header(index);
        if (!rawPath || !header || header->magic != MH_MAGIC_64) continue;
        NSString *loadedPath = [NSString stringWithUTF8String:rawPath];
        if (!FLEXAddressPathMatches(requested, loadedPath)) continue;
        if (headerOut) *headerOut = (const struct mach_header_64 *)header;
        if (slideOut) *slideOut = _dyld_get_image_vmaddr_slide(index);
        if (pathOut) *pathOut = loadedPath;
        return YES;
    }
    return NO;
}

static BOOL FLEXAddressIsExecutable(const struct mach_header_64 *header,
                                    intptr_t slide,
                                    uintptr_t address,
                                    NSUInteger functionSize) {
    if (!header || !address) return NO;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if ((segment->initprot & VM_PROT_EXECUTE) && segment->vmsize) {
                uintptr_t start = (uintptr_t)(segment->vmaddr + slide);
                uintptr_t end = start + (uintptr_t)segment->vmsize;
                uintptr_t requestedEnd = functionSize > 0
                    ? address + functionSize : address + sizeof(uint32_t);
                if (address >= start && requestedEnd > address && requestedEnd <= end) {
                    return YES;
                }
            }
        }
        cursor += command->cmdsize;
    }
    return NO;
}

static BOOL FLEXAddressResolveEntry(FLEXHookEntry *entry,
                                    void **addressOut,
                                    NSString **failureOut) {
    NSDictionary *locator = entry.locator;
    NSNumber *addressNumber = [locator[@"address"] isKindOfClass:NSNumber.class]
        ? locator[@"address"] : nil;
    NSString *imagePath = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : nil;
    if (!addressNumber.unsignedLongLongValue || !imagePath.length) {
        if (failureOut) *failureOut = @"The runtime entry has no image-scoped address";
        return NO;
    }

    const struct mach_header_64 *header = NULL;
    intptr_t slide = 0;
    if (!FLEXAddressFindImage(imagePath, &header, &slide, NULL)) {
        if (failureOut) *failureOut = @"The selected Mach-O image is no longer loaded";
        return NO;
    }

    NSString *expectedUUID = [locator[@"imageUUID"] isKindOfClass:NSString.class]
        ? locator[@"imageUUID"] : nil;
    if (expectedUUID.length) {
        NSString *loadedUUID = FLEXAddressUUID(header);
        if (!loadedUUID.length ||
            [expectedUUID caseInsensitiveCompare:loadedUUID] != NSOrderedSame) {
            if (failureOut) *failureOut = @"The selected image UUID changed; rescan and resolve ABI again";
            return NO;
        }
    }

    uintptr_t address = (uintptr_t)addressNumber.unsignedLongLongValue;
    NSUInteger functionSize = [locator[@"functionSize"] unsignedIntegerValue];
    if (!FLEXAddressIsExecutable(header, slide, address, functionSize)) {
        if (failureOut) *failureOut = @"The recorded target is outside the executable segments of the selected image";
        return NO;
    }

    if (addressOut) *addressOut = (void *)address;
    return YES;
}

static BOOL FLEXAddressEntryUsesEngine(FLEXHookEntry *entry) {
    return entry &&
        entry.surface == FLEXHookSurfaceCInline &&
        [entry.locator[@"address"] isKindOfClass:NSNumber.class] &&
        [entry.locator[@"image"] isKindOfClass:NSString.class];
}

static NSRange FLEXAddressSlotRange(FLEXHookABI abi) {
    switch (abi) {
        case FLEXHookABICBoolNoArguments:
            return NSMakeRange(0, FLEX_ADDRESS_SLOTS_PER_ABI);
        case FLEXHookABICBoolPointerArgument:
            return NSMakeRange(8, FLEX_ADDRESS_SLOTS_PER_ABI);
        case FLEXHookABICInt64NoArguments:
            return NSMakeRange(16, FLEX_ADDRESS_SLOTS_PER_ABI);
        case FLEXHookABICPointerNoArguments:
            return NSMakeRange(24, FLEX_ADDRESS_SLOTS_PER_ABI);
        default:
            return NSMakeRange(NSNotFound, 0);
    }
}

static FLEXAddressHookSlot *FLEXAddressExistingSlot(FLEXHookEntry *entry,
                                                    NSInteger *indexOut) {
    if (!entry.identifier.length) return NULL;
    for (NSUInteger index = 0; index < FLEX_ADDRESS_SLOT_COUNT; index++) {
        FLEXAddressHookSlot *slot = &gFLEXAddressSlots[index];
        if (atomic_load_explicit(&slot->allocated, memory_order_acquire) &&
            strcmp(slot->identifier, entry.identifier.UTF8String) == 0) {
            if (indexOut) *indexOut = (NSInteger)index;
            return slot;
        }
    }
    return NULL;
}

static NSInteger FLEXAddressReserveSlot(FLEXHookEntry *entry) {
    NSInteger existingIndex = NSNotFound;
    if (FLEXAddressExistingSlot(entry, &existingIndex)) return existingIndex;

    NSRange range = FLEXAddressSlotRange(entry.abi);
    if (range.location == NSNotFound) return NSNotFound;
    @synchronized (FLEXCHookEngine.class) {
        for (NSUInteger index = range.location; index < NSMaxRange(range); index++) {
            FLEXAddressHookSlot *slot = &gFLEXAddressSlots[index];
            if (atomic_load_explicit(&slot->allocated, memory_order_acquire)) continue;
            memset(slot, 0, sizeof(*slot));
            slot->abi = entry.abi;
            strlcpy(slot->identifier,
                    entry.identifier.UTF8String,
                    sizeof(slot->identifier));
            atomic_init(&slot->enabled, false);
            atomic_init(&slot->forceBool, entry.forceValue);
            atomic_init(&slot->forceInt64, entry.forceValue ? 1 : 0);
            atomic_init(&slot->forcePointer, 0);
            atomic_init(&slot->hits, 0);
            atomic_init(&slot->overrideHits, 0);
            atomic_store_explicit(&slot->allocated, true, memory_order_release);
            return (NSInteger)index;
        }
    }
    return NSNotFound;
}

static void FLEXAddressRecordHit(FLEXAddressHookSlot *slot, BOOL overridden) {
    atomic_fetch_add_explicit(&slot->hits, 1, memory_order_relaxed);
    if (overridden && atomic_fetch_add_explicit(
            &slot->overrideHits, 1, memory_order_relaxed) == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:FLEXHookRegistryDidChangeNotification
                              object:nil
                            userInfo:@{@"reason": @"first-observed-address-c-call"}];
        });
    }
}

static bool FLEXAddressCallBool0(NSUInteger index) {
    FLEXAddressHookSlot *slot = &gFLEXAddressSlots[index];
    BOOL enabled = atomic_load_explicit(&slot->enabled, memory_order_acquire);
    FLEXAddressRecordHit(slot, enabled);
    if (enabled) return atomic_load_explicit(&slot->forceBool, memory_order_relaxed);
    bool (*original)(void) = (bool (*)(void))slot->original;
    return original ? original() : false;
}

static bool FLEXAddressCallBoolPointer(NSUInteger index, void *argument) {
    FLEXAddressHookSlot *slot = &gFLEXAddressSlots[index];
    BOOL enabled = atomic_load_explicit(&slot->enabled, memory_order_acquire);
    FLEXAddressRecordHit(slot, enabled);
    if (enabled) return atomic_load_explicit(&slot->forceBool, memory_order_relaxed);
    bool (*original)(void *) = (bool (*)(void *))slot->original;
    return original ? original(argument) : false;
}

static int64_t FLEXAddressCallInt64(NSUInteger index) {
    FLEXAddressHookSlot *slot = &gFLEXAddressSlots[index];
    BOOL enabled = atomic_load_explicit(&slot->enabled, memory_order_acquire);
    FLEXAddressRecordHit(slot, enabled);
    if (enabled) return atomic_load_explicit(&slot->forceInt64, memory_order_relaxed);
    int64_t (*original)(void) = (int64_t (*)(void))slot->original;
    return original ? original() : 0;
}

static void *FLEXAddressCallPointer(NSUInteger index) {
    FLEXAddressHookSlot *slot = &gFLEXAddressSlots[index];
    BOOL enabled = atomic_load_explicit(&slot->enabled, memory_order_acquire);
    FLEXAddressRecordHit(slot, enabled);
    if (enabled) {
        return (void *)atomic_load_explicit(&slot->forcePointer,
                                            memory_order_relaxed);
    }
    void *(*original)(void) = (void *(*)(void))slot->original;
    return original ? original() : NULL;
}

#define FLEX_ADDR_BOOL0(N) static bool FLEXAddressBool0_##N(void) { return FLEXAddressCallBool0(N); }
#define FLEX_ADDR_BOOLPTR(N) static bool FLEXAddressBoolPointer_##N(void *arg) { return FLEXAddressCallBoolPointer((N) + 8, arg); }
#define FLEX_ADDR_INT64(N) static int64_t FLEXAddressInt64_##N(void) { return FLEXAddressCallInt64((N) + 16); }
#define FLEX_ADDR_POINTER(N) static void *FLEXAddressPointer_##N(void) { return FLEXAddressCallPointer((N) + 24); }

FLEX_ADDR_BOOL0(0) FLEX_ADDR_BOOL0(1) FLEX_ADDR_BOOL0(2) FLEX_ADDR_BOOL0(3)
FLEX_ADDR_BOOL0(4) FLEX_ADDR_BOOL0(5) FLEX_ADDR_BOOL0(6) FLEX_ADDR_BOOL0(7)
FLEX_ADDR_BOOLPTR(0) FLEX_ADDR_BOOLPTR(1) FLEX_ADDR_BOOLPTR(2) FLEX_ADDR_BOOLPTR(3)
FLEX_ADDR_BOOLPTR(4) FLEX_ADDR_BOOLPTR(5) FLEX_ADDR_BOOLPTR(6) FLEX_ADDR_BOOLPTR(7)
FLEX_ADDR_INT64(0) FLEX_ADDR_INT64(1) FLEX_ADDR_INT64(2) FLEX_ADDR_INT64(3)
FLEX_ADDR_INT64(4) FLEX_ADDR_INT64(5) FLEX_ADDR_INT64(6) FLEX_ADDR_INT64(7)
FLEX_ADDR_POINTER(0) FLEX_ADDR_POINTER(1) FLEX_ADDR_POINTER(2) FLEX_ADDR_POINTER(3)
FLEX_ADDR_POINTER(4) FLEX_ADDR_POINTER(5) FLEX_ADDR_POINTER(6) FLEX_ADDR_POINTER(7)

static void *const gFLEXAddressBool0Replacements[8] = {
    (void *)FLEXAddressBool0_0, (void *)FLEXAddressBool0_1,
    (void *)FLEXAddressBool0_2, (void *)FLEXAddressBool0_3,
    (void *)FLEXAddressBool0_4, (void *)FLEXAddressBool0_5,
    (void *)FLEXAddressBool0_6, (void *)FLEXAddressBool0_7,
};
static void *const gFLEXAddressBoolPointerReplacements[8] = {
    (void *)FLEXAddressBoolPointer_0, (void *)FLEXAddressBoolPointer_1,
    (void *)FLEXAddressBoolPointer_2, (void *)FLEXAddressBoolPointer_3,
    (void *)FLEXAddressBoolPointer_4, (void *)FLEXAddressBoolPointer_5,
    (void *)FLEXAddressBoolPointer_6, (void *)FLEXAddressBoolPointer_7,
};
static void *const gFLEXAddressInt64Replacements[8] = {
    (void *)FLEXAddressInt64_0, (void *)FLEXAddressInt64_1,
    (void *)FLEXAddressInt64_2, (void *)FLEXAddressInt64_3,
    (void *)FLEXAddressInt64_4, (void *)FLEXAddressInt64_5,
    (void *)FLEXAddressInt64_6, (void *)FLEXAddressInt64_7,
};
static void *const gFLEXAddressPointerReplacements[8] = {
    (void *)FLEXAddressPointer_0, (void *)FLEXAddressPointer_1,
    (void *)FLEXAddressPointer_2, (void *)FLEXAddressPointer_3,
    (void *)FLEXAddressPointer_4, (void *)FLEXAddressPointer_5,
    (void *)FLEXAddressPointer_6, (void *)FLEXAddressPointer_7,
};

static void *FLEXAddressReplacement(NSInteger index, FLEXHookABI abi) {
    NSRange range = FLEXAddressSlotRange(abi);
    if (range.location == NSNotFound || !NSLocationInRange(index, range)) return NULL;
    NSUInteger local = (NSUInteger)index - range.location;
    switch (abi) {
        case FLEXHookABICBoolNoArguments:
            return gFLEXAddressBool0Replacements[local];
        case FLEXHookABICBoolPointerArgument:
            return gFLEXAddressBoolPointerReplacements[local];
        case FLEXHookABICInt64NoArguments:
            return gFLEXAddressInt64Replacements[local];
        case FLEXHookABICPointerNoArguments:
            return gFLEXAddressPointerReplacements[local];
        default:
            return NULL;
    }
}

@interface FLEXCHookEngine (AllFLEXingAddressEngine)
+ (BOOL)af_address_installEntry:(FLEXHookEntry *)entry error:(NSError **)error;
+ (void)af_address_setEnabled:(BOOL)enabled forEntry:(FLEXHookEntry *)entry;
+ (NSUInteger)af_address_hitCountForEntry:(FLEXHookEntry *)entry;
+ (NSUInteger)af_address_overrideHitCountForEntry:(FLEXHookEntry *)entry;
+ (void)af_address_refreshAvailabilityForEntry:(FLEXHookEntry *)entry;
@end

@implementation FLEXCHookEngine (AllFLEXingAddressEngine)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class meta = object_getClass(FLEXCHookEngine.class);
        NSArray<NSArray<NSString *> *> *pairs = @[
            @[@"installEntry:error:", @"af_address_installEntry:error:"],
            @[@"setEnabled:forEntry:", @"af_address_setEnabled:forEntry:"],
            @[@"hitCountForEntry:", @"af_address_hitCountForEntry:"],
            @[@"overrideHitCountForEntry:", @"af_address_overrideHitCountForEntry:"],
            @[@"refreshAvailabilityForEntry:", @"af_address_refreshAvailabilityForEntry:"],
        ];
        for (NSArray<NSString *> *pair in pairs) {
            Method original = class_getInstanceMethod(meta,
                NSSelectorFromString(pair[0]));
            Method replacement = class_getInstanceMethod(meta,
                NSSelectorFromString(pair[1]));
            if (original && replacement) method_exchangeImplementations(original, replacement);
        }
    });
}

+ (BOOL)af_address_installEntry:(FLEXHookEntry *)entry error:(NSError **)error {
    if (!FLEXAddressEntryUsesEngine(entry)) {
        return [self af_address_installEntry:entry error:error];
    }
    if (entry.abi == FLEXHookABIUnknown) {
        if (error) *error = FLEXAddressHookError(1, @"C ABI is unknown");
        return NO;
    }

    [self refreshAvailabilityForEntry:entry];
    if (!entry.available || !entry.hookable) {
        if (error) *error = FLEXAddressHookError(2,
            entry.lastError ?: @"Address target failed runtime validation");
        return NO;
    }

    void *address = NULL;
    NSString *failure = nil;
    if (!FLEXAddressResolveEntry(entry, &address, &failure)) {
        if (error) *error = FLEXAddressHookError(3, failure);
        return NO;
    }

    NSInteger slotIndex = FLEXAddressReserveSlot(entry);
    void *replacement = FLEXAddressReplacement(slotIndex, entry.abi);
    if (slotIndex == NSNotFound || !replacement) {
        if (error) *error = FLEXAddressHookError(4,
            @"No typed address-hook replacement slot is available");
        return NO;
    }

    FLEXAddressHookSlot *slot = &gFLEXAddressSlots[slotIndex];
    slot->original = NULL;
    BOOL installed = FLEXHookFunctionIfAvailable(
        address,
        replacement,
        &slot->original
    );
    if (!installed || !slot->original || slot->original == replacement) {
        if (error) *error = FLEXAddressHookError(5,
            @"MSHookFunction did not produce a valid trampoline for the image-scoped address");
        return NO;
    }

    entry.original = slot->original;
    entry.runtimeSlot = slotIndex;
    entry.backend = FLEXHookBackendInlineElleKit;
    entry.installed = YES;
    entry.stale = NO;
    entry.lastError = nil;
    [self setEnabled:entry.pendingEnabled forEntry:entry];
    return YES;
}

+ (void)af_address_setEnabled:(BOOL)enabled forEntry:(FLEXHookEntry *)entry {
    FLEXAddressHookSlot *slot = FLEXAddressExistingSlot(entry, NULL);
    if (!slot) {
        [self af_address_setEnabled:enabled forEntry:entry];
        return;
    }
    atomic_store_explicit(&slot->forceBool, entry.forceValue,
                          memory_order_relaxed);
    atomic_store_explicit(&slot->forceInt64, entry.forceValue ? 1 : 0,
                          memory_order_relaxed);
    atomic_store_explicit(&slot->forcePointer, 0, memory_order_relaxed);
    atomic_store_explicit(&slot->enabled, enabled, memory_order_release);
}

+ (NSUInteger)af_address_hitCountForEntry:(FLEXHookEntry *)entry {
    FLEXAddressHookSlot *slot = FLEXAddressExistingSlot(entry, NULL);
    if (!slot) return [self af_address_hitCountForEntry:entry];
    return (NSUInteger)atomic_load_explicit(&slot->hits, memory_order_relaxed);
}

+ (NSUInteger)af_address_overrideHitCountForEntry:(FLEXHookEntry *)entry {
    FLEXAddressHookSlot *slot = FLEXAddressExistingSlot(entry, NULL);
    if (!slot) return [self af_address_overrideHitCountForEntry:entry];
    return (NSUInteger)atomic_load_explicit(&slot->overrideHits,
                                            memory_order_relaxed);
}

+ (void)af_address_refreshAvailabilityForEntry:(FLEXHookEntry *)entry {
    if (!FLEXAddressEntryUsesEngine(entry)) {
        [self af_address_refreshAvailabilityForEntry:entry];
        return;
    }

    void *address = NULL;
    NSString *failure = nil;
    BOOL validAddress = FLEXAddressResolveEntry(entry, &address, &failure);
    BOOL provider = FLEXMSHookFunctionProviderAvailable();
    BOOL engineEnabled = FLEXFlag(@"engine.inline_ellekit");
    entry.available = validAddress && provider;
    entry.hookable = entry.available && engineEnabled &&
                     entry.abi != FLEXHookABIUnknown;
    entry.stale = !validAddress;
    if (!validAddress) {
        entry.lastError = failure;
    } else if (!provider) {
        entry.lastError = @"MSHookFunction provider is unavailable";
    } else if (!engineEnabled) {
        entry.lastError = @"Inline ElleKit engine is disabled";
    } else if (entry.abi == FLEXHookABIUnknown) {
        entry.lastError = nil;
    } else {
        entry.lastError = nil;
    }
}

@end
