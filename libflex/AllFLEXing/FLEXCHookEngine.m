#import "FLEXCHookEngine.h"

#import "FLEXHookRegistry.h"
#import "FLEXHookPersistence.h"
#import "FLEXHooking.h"
#import "FLEXSymbolRebind.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <string.h>

#define FLEX_C_SLOT_COUNT 48
#define FLEX_C_SLOTS_PER_ABI 8

typedef struct {
    atomic_bool allocated;
    atomic_bool enabled;
    atomic_bool forceBool;
    atomic_llong forceInt64;
    atomic_uintptr_t forcePointer;
    // Raw bit pattern for the secondary-scope typed profiles. For the double and
    // float profiles this holds the IEEE-754 bits; the stub reinterprets it with
    // memcpy so the compiler materializes the value into d0/s0 via a real fmov.
    atomic_ullong forceRaw;
    atomic_ullong hits;
    atomic_ullong overrideHits;
    void *original;
    FLEXHookABI abi;
    char identifier[256];
} FLEXCHookSlot;

static FLEXCHookSlot gFLEXCHookSlots[FLEX_C_SLOT_COUNT];

static void FLEXCHookRecordHit(FLEXCHookSlot *slot, BOOL overridden) {
    atomic_fetch_add_explicit(&slot->hits, 1, memory_order_relaxed);
    if (overridden && atomic_fetch_add_explicit(
            &slot->overrideHits, 1, memory_order_relaxed
        ) == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter
                postNotificationName:FLEXHookRegistryDidChangeNotification
                              object:nil
                            userInfo:@{ @"reason": @"first-observed-c-call" }];
        });
    }
}

static NSString *FLEXCHookUUIDForHeader(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) {
        return @"";
    }
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuidCommand = (const struct uuid_command *)command;
            NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:uuidCommand->uuid];
            return uuid.UUIDString ?: @"";
        }
        if (command->cmdsize < sizeof(struct load_command)) {
            break;
        }
        cursor += command->cmdsize;
    }
    return @"";
}

static BOOL FLEXCHookImagePathMatches(NSString *requested, NSString *loaded) {
    if (requested.length == 0) {
        return YES;
    }
    if ([requested containsString:@"/"]) {
        return [requested isEqualToString:loaded];
    }
    return [requested.lastPathComponent isEqualToString:loaded.lastPathComponent];
}

static const struct mach_header_64 *FLEXCHookLoadedImageHeader(NSString *requested,
                                                               NSString **loadedPath) {
    if (requested.length == 0) {
        return NULL;
    }
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *header = _dyld_get_image_header(index);
        if (!rawPath || !header || header->magic != MH_MAGIC_64) {
            continue;
        }
        NSString *path = [NSString stringWithUTF8String:rawPath];
        if (!FLEXCHookImagePathMatches(requested, path)) {
            continue;
        }
        if (loadedPath) {
            *loadedPath = path;
        }
        return (const struct mach_header_64 *)header;
    }
    return NULL;
}

static BOOL FLEXCHookValidateImageLocator(NSDictionary *locator,
                                          NSString **failureReason) {
    NSString *requested = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : nil;
    if (requested.length == 0) {
        return YES;
    }

    const struct mach_header_64 *header = FLEXCHookLoadedImageHeader(requested, NULL);
    if (!header) {
        if (failureReason) {
            *failureReason = @"Target image is not loaded";
        }
        return NO;
    }

    NSString *expectedUUID = [locator[@"imageUUID"] isKindOfClass:NSString.class]
        ? locator[@"imageUUID"] : nil;
    if (expectedUUID.length) {
        NSString *loadedUUID = FLEXCHookUUIDForHeader(header);
        if (loadedUUID.length == 0 ||
            [expectedUUID caseInsensitiveCompare:loadedUUID] != NSOrderedSame) {
            if (failureReason) {
                *failureReason = @"Target image UUID changed; revalidate the ABI";
            }
            return NO;
        }
    }
    return YES;
}

static void *FLEXCHookResolveGlobalSymbol(NSString *symbol) {
    if (symbol.length == 0) {
        return NULL;
    }
    NSString *normalized = [symbol hasPrefix:@"_"]
        ? [symbol substringFromIndex:1] : symbol;
    void *address = dlsym(RTLD_DEFAULT, normalized.UTF8String);
    if (!address) {
        address = dlsym(RTLD_DEFAULT, symbol.UTF8String);
    }
    return address;
}

static void *FLEXCHookResolveSymbolForLocator(NSString *symbol,
                                              NSDictionary *locator) {
    void *address = FLEXCHookResolveGlobalSymbol(symbol);
    if (!address) {
        return NULL;
    }

    NSString *requested = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : nil;
    if (requested.length == 0) {
        return address;
    }

    Dl_info info = {0};
    if (dladdr(address, &info) == 0 || !info.dli_fname) {
        return NULL;
    }
    NSString *resolvedPath = [NSString stringWithUTF8String:info.dli_fname];
    return FLEXCHookImagePathMatches(requested, resolvedPath) ? address : NULL;
}

static bool FLEXCallBool0(NSUInteger index) {
    FLEXCHookSlot *slot = &gFLEXCHookSlots[index];
    BOOL enabled = atomic_load_explicit(&slot->enabled, memory_order_acquire);
    FLEXCHookRecordHit(slot, enabled);
    if (enabled) {
        return atomic_load_explicit(&slot->forceBool, memory_order_relaxed);
    }
    bool (*original)(void) = (bool (*)(void))slot->original;
    return original ? original() : false;
}

static bool FLEXCallBoolPointer(NSUInteger index, void *argument) {
    FLEXCHookSlot *slot = &gFLEXCHookSlots[index];
    BOOL enabled = atomic_load_explicit(&slot->enabled, memory_order_acquire);
    FLEXCHookRecordHit(slot, enabled);
    if (enabled) {
        return atomic_load_explicit(&slot->forceBool, memory_order_relaxed);
    }
    bool (*original)(void *) = (bool (*)(void *))slot->original;
    return original ? original(argument) : false;
}

static int64_t FLEXCallInt64NoArgs(NSUInteger index) {
    FLEXCHookSlot *slot = &gFLEXCHookSlots[index];
    BOOL enabled = atomic_load_explicit(&slot->enabled, memory_order_acquire);
    FLEXCHookRecordHit(slot, enabled);
    if (enabled) {
        return atomic_load_explicit(&slot->forceInt64, memory_order_relaxed);
    }
    int64_t (*original)(void) = (int64_t (*)(void))slot->original;
    return original ? original() : 0;
}

static void *FLEXCallPointerNoArgs(NSUInteger index) {
    FLEXCHookSlot *slot = &gFLEXCHookSlots[index];
    BOOL enabled = atomic_load_explicit(&slot->enabled, memory_order_acquire);
    FLEXCHookRecordHit(slot, enabled);
    if (enabled) {
        return (void *)atomic_load_explicit(&slot->forcePointer, memory_order_relaxed);
    }
    void *(*original)(void) = (void *(*)(void))slot->original;
    return original ? original() : NULL;
}

static double FLEXCallDoubleNoArgs(NSUInteger index) {
    FLEXCHookSlot *slot = &gFLEXCHookSlots[index];
    BOOL enabled = atomic_load_explicit(&slot->enabled, memory_order_acquire);
    FLEXCHookRecordHit(slot, enabled);
    if (enabled) {
        // Reinterpret the stored bits as a double. Returning a double makes the
        // compiler emit the AAPCS64 FP return: the value lands in d0 via fmov.
        uint64_t bits = atomic_load_explicit(&slot->forceRaw, memory_order_relaxed);
        double value = 0;
        memcpy(&value, &bits, sizeof(value));
        return value;
    }
    double (*original)(void) = (double (*)(void))slot->original;
    return original ? original() : 0;
}

static float FLEXCallFloatNoArgs(NSUInteger index) {
    FLEXCHookSlot *slot = &gFLEXCHookSlots[index];
    BOOL enabled = atomic_load_explicit(&slot->enabled, memory_order_acquire);
    FLEXCHookRecordHit(slot, enabled);
    if (enabled) {
        // Low 32 bits hold the float pattern; returning a float emits the s0
        // return move (fmov s0, wN).
        uint64_t bits = atomic_load_explicit(&slot->forceRaw, memory_order_relaxed);
        uint32_t narrow = (uint32_t)bits;
        float value = 0;
        memcpy(&value, &narrow, sizeof(value));
        return value;
    }
    float (*original)(void) = (float (*)(void))slot->original;
    return original ? original() : 0;
}

#define FLEX_BOOL0_STUB(N, INDEX) static bool FLEXCBool0_##N(void) { return FLEXCallBool0(INDEX); }
#define FLEX_BOOLPTR_STUB(N, INDEX) static bool FLEXCBoolPointer_##N(void *arg) { return FLEXCallBoolPointer(INDEX, arg); }
#define FLEX_INT64_STUB(N, INDEX) static int64_t FLEXCInt64_##N(void) { return FLEXCallInt64NoArgs(INDEX); }
#define FLEX_POINTER_STUB(N, INDEX) static void *FLEXCPointer_##N(void) { return FLEXCallPointerNoArgs(INDEX); }
#define FLEX_DOUBLE_STUB(N, INDEX) static double FLEXCDouble_##N(void) { return FLEXCallDoubleNoArgs(INDEX); }
#define FLEX_FLOAT_STUB(N, INDEX) static float FLEXCFloat_##N(void) { return FLEXCallFloatNoArgs(INDEX); }

FLEX_BOOL0_STUB(0, 0) FLEX_BOOL0_STUB(1, 1) FLEX_BOOL0_STUB(2, 2) FLEX_BOOL0_STUB(3, 3)
FLEX_BOOL0_STUB(4, 4) FLEX_BOOL0_STUB(5, 5) FLEX_BOOL0_STUB(6, 6) FLEX_BOOL0_STUB(7, 7)
FLEX_BOOLPTR_STUB(0, 8) FLEX_BOOLPTR_STUB(1, 9) FLEX_BOOLPTR_STUB(2, 10) FLEX_BOOLPTR_STUB(3, 11)
FLEX_BOOLPTR_STUB(4, 12) FLEX_BOOLPTR_STUB(5, 13) FLEX_BOOLPTR_STUB(6, 14) FLEX_BOOLPTR_STUB(7, 15)
FLEX_INT64_STUB(0, 16) FLEX_INT64_STUB(1, 17) FLEX_INT64_STUB(2, 18) FLEX_INT64_STUB(3, 19)
FLEX_INT64_STUB(4, 20) FLEX_INT64_STUB(5, 21) FLEX_INT64_STUB(6, 22) FLEX_INT64_STUB(7, 23)
FLEX_POINTER_STUB(0, 24) FLEX_POINTER_STUB(1, 25) FLEX_POINTER_STUB(2, 26) FLEX_POINTER_STUB(3, 27)
FLEX_POINTER_STUB(4, 28) FLEX_POINTER_STUB(5, 29) FLEX_POINTER_STUB(6, 30) FLEX_POINTER_STUB(7, 31)
FLEX_DOUBLE_STUB(0, 32) FLEX_DOUBLE_STUB(1, 33) FLEX_DOUBLE_STUB(2, 34) FLEX_DOUBLE_STUB(3, 35)
FLEX_DOUBLE_STUB(4, 36) FLEX_DOUBLE_STUB(5, 37) FLEX_DOUBLE_STUB(6, 38) FLEX_DOUBLE_STUB(7, 39)
FLEX_FLOAT_STUB(0, 40) FLEX_FLOAT_STUB(1, 41) FLEX_FLOAT_STUB(2, 42) FLEX_FLOAT_STUB(3, 43)
FLEX_FLOAT_STUB(4, 44) FLEX_FLOAT_STUB(5, 45) FLEX_FLOAT_STUB(6, 46) FLEX_FLOAT_STUB(7, 47)

static void *const gFLEXBool0Replacements[FLEX_C_SLOTS_PER_ABI] = {
    (void *)FLEXCBool0_0, (void *)FLEXCBool0_1, (void *)FLEXCBool0_2, (void *)FLEXCBool0_3,
    (void *)FLEXCBool0_4, (void *)FLEXCBool0_5, (void *)FLEXCBool0_6, (void *)FLEXCBool0_7,
};
static void *const gFLEXBoolPointerReplacements[FLEX_C_SLOTS_PER_ABI] = {
    (void *)FLEXCBoolPointer_0, (void *)FLEXCBoolPointer_1,
    (void *)FLEXCBoolPointer_2, (void *)FLEXCBoolPointer_3,
    (void *)FLEXCBoolPointer_4, (void *)FLEXCBoolPointer_5,
    (void *)FLEXCBoolPointer_6, (void *)FLEXCBoolPointer_7,
};
static void *const gFLEXInt64Replacements[FLEX_C_SLOTS_PER_ABI] = {
    (void *)FLEXCInt64_0, (void *)FLEXCInt64_1, (void *)FLEXCInt64_2, (void *)FLEXCInt64_3,
    (void *)FLEXCInt64_4, (void *)FLEXCInt64_5, (void *)FLEXCInt64_6, (void *)FLEXCInt64_7,
};
static void *const gFLEXPointerReplacements[FLEX_C_SLOTS_PER_ABI] = {
    (void *)FLEXCPointer_0, (void *)FLEXCPointer_1, (void *)FLEXCPointer_2, (void *)FLEXCPointer_3,
    (void *)FLEXCPointer_4, (void *)FLEXCPointer_5, (void *)FLEXCPointer_6, (void *)FLEXCPointer_7,
};
static void *const gFLEXDoubleReplacements[FLEX_C_SLOTS_PER_ABI] = {
    (void *)FLEXCDouble_0, (void *)FLEXCDouble_1, (void *)FLEXCDouble_2, (void *)FLEXCDouble_3,
    (void *)FLEXCDouble_4, (void *)FLEXCDouble_5, (void *)FLEXCDouble_6, (void *)FLEXCDouble_7,
};
static void *const gFLEXFloatReplacements[FLEX_C_SLOTS_PER_ABI] = {
    (void *)FLEXCFloat_0, (void *)FLEXCFloat_1, (void *)FLEXCFloat_2, (void *)FLEXCFloat_3,
    (void *)FLEXCFloat_4, (void *)FLEXCFloat_5, (void *)FLEXCFloat_6, (void *)FLEXCFloat_7,
};

static NSRange FLEXSlotRangeForABI(FLEXHookABI abi) {
    switch (abi) {
        case FLEXHookABICBoolNoArguments: return NSMakeRange(0, FLEX_C_SLOTS_PER_ABI);
        case FLEXHookABICBoolPointerArgument: return NSMakeRange(8, FLEX_C_SLOTS_PER_ABI);
        case FLEXHookABICInt64NoArguments: return NSMakeRange(16, FLEX_C_SLOTS_PER_ABI);
        case FLEXHookABICPointerNoArguments: return NSMakeRange(24, FLEX_C_SLOTS_PER_ABI);
        case FLEXHookABICDoubleNoArguments: return NSMakeRange(32, FLEX_C_SLOTS_PER_ABI);
        case FLEXHookABICFloatNoArguments: return NSMakeRange(40, FLEX_C_SLOTS_PER_ABI);
        default: return NSMakeRange(NSNotFound, 0);
    }
}

static void *FLEXReplacementForSlot(NSUInteger slotIndex, FLEXHookABI abi) {
    NSRange range = FLEXSlotRangeForABI(abi);
    if (range.location == NSNotFound || !NSLocationInRange(slotIndex, range)) {
        return NULL;
    }
    NSUInteger local = slotIndex - range.location;
    switch (abi) {
        case FLEXHookABICBoolNoArguments: return gFLEXBool0Replacements[local];
        case FLEXHookABICBoolPointerArgument: return gFLEXBoolPointerReplacements[local];
        case FLEXHookABICInt64NoArguments: return gFLEXInt64Replacements[local];
        case FLEXHookABICPointerNoArguments: return gFLEXPointerReplacements[local];
        case FLEXHookABICDoubleNoArguments: return gFLEXDoubleReplacements[local];
        case FLEXHookABICFloatNoArguments: return gFLEXFloatReplacements[local];
        default: return NULL;
    }
}

static NSInteger FLEXReserveSlot(FLEXHookEntry *entry) {
    if (entry.runtimeSlot != NSNotFound &&
        entry.runtimeSlot >= 0 && entry.runtimeSlot < FLEX_C_SLOT_COUNT) {
        FLEXCHookSlot *slot = &gFLEXCHookSlots[entry.runtimeSlot];
        if (atomic_load_explicit(&slot->allocated, memory_order_acquire) &&
            strcmp(slot->identifier, entry.identifier.UTF8String) == 0) {
            return entry.runtimeSlot;
        }
    }

    NSRange range = FLEXSlotRangeForABI(entry.abi);
    if (range.location == NSNotFound) {
        return NSNotFound;
    }

    @synchronized (FLEXCHookEngine.class) {
        for (NSUInteger index = range.location; index < NSMaxRange(range); index++) {
            FLEXCHookSlot *slot = &gFLEXCHookSlots[index];
            if (atomic_load_explicit(&slot->allocated, memory_order_acquire)) {
                if (strcmp(slot->identifier, entry.identifier.UTF8String) == 0) {
                    entry.runtimeSlot = (NSInteger)index;
                    return (NSInteger)index;
                }
                continue;
            }

            memset(slot, 0, sizeof(*slot));
            slot->abi = entry.abi;
            strlcpy(slot->identifier, entry.identifier.UTF8String, sizeof(slot->identifier));
            atomic_init(&slot->enabled, false);
            atomic_init(&slot->forceBool, entry.forceValue);
            atomic_init(&slot->forceInt64, (long long)entry.forceRawValue);
            atomic_init(&slot->forcePointer, (uintptr_t)entry.forceRawValue);
            atomic_init(&slot->forceRaw, entry.forceRawValue);
            atomic_init(&slot->hits, 0);
            atomic_init(&slot->overrideHits, 0);
            atomic_store_explicit(&slot->allocated, true, memory_order_release);
            entry.runtimeSlot = (NSInteger)index;
            return (NSInteger)index;
        }
    }
    return NSNotFound;
}

@implementation FLEXCHookEngine

+ (void *)resolveSymbol:(NSString *)symbol {
    return FLEXCHookResolveGlobalSymbol(symbol);
}

+ (BOOL)installEntry:(FLEXHookEntry *)entry error:(NSError **)error {
    if (!entry || entry.abi == FLEXHookABIUnknown) {
        if (error) {
            *error = [NSError errorWithDomain:@"FLEXCHookEngine"
                                          code:1
                                      userInfo:@{NSLocalizedDescriptionKey: @"C ABI is unknown"}];
        }
        return NO;
    }

    [self refreshAvailabilityForEntry:entry];
    if (!entry.available || !entry.hookable) {
        if (error) {
            *error = [NSError errorWithDomain:@"FLEXCHookEngine"
                                          code:7
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          entry.lastError ?: @"C target failed runtime validation"}];
        }
        return NO;
    }

    NSInteger slotIndex = FLEXReserveSlot(entry);
    if (slotIndex == NSNotFound) {
        if (error) {
            *error = [NSError errorWithDomain:@"FLEXCHookEngine"
                                          code:2
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"No typed C replacement slot is available"}];
        }
        return NO;
    }

    FLEXCHookSlot *slot = &gFLEXCHookSlots[slotIndex];
    void *replacement = FLEXReplacementForSlot((NSUInteger)slotIndex, entry.abi);
    NSString *symbol = [entry.locator[@"symbol"] isKindOfClass:NSString.class]
        ? entry.locator[@"symbol"] : nil;
    if (!replacement || symbol.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"FLEXCHookEngine"
                                          code:3
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          @"C locator or replacement is invalid"}];
        }
        return NO;
    }

    FLEXHookBackend backend = entry.backend;
    if (backend == FLEXHookBackendAuto) {
        backend = [entry.locator[@"bindSlots"] unsignedIntegerValue] > 0
            ? FLEXHookBackendFishhook : FLEXHookBackendInlineElleKit;
    }

    slot->original = NULL;
    BOOL installed = NO;
    if (backend == FLEXHookBackendFishhook) {
        if (!FLEXFlag(@"engine.fishhook")) {
            if (error) {
                *error = [NSError errorWithDomain:@"FLEXCHookEngine"
                                              code:5
                                          userInfo:@{NSLocalizedDescriptionKey:
                                              @"fishhook engine is disabled"}];
            }
            return NO;
        }
        NSString *image = [entry.locator[@"image"] isKindOfClass:NSString.class]
            ? entry.locator[@"image"] : nil;
        installed = [FLEXSymbolRebind rebindSymbol:symbol
                                      inImageNamed:image
                                        replacement:replacement
                                           original:&slot->original];
    } else if (backend == FLEXHookBackendInlineElleKit) {
        if (!FLEXFlag(@"engine.inline_ellekit")) {
            if (error) {
                *error = [NSError errorWithDomain:@"FLEXCHookEngine"
                                              code:6
                                          userInfo:@{NSLocalizedDescriptionKey:
                                              @"Inline ElleKit engine is disabled"}];
            }
            return NO;
        }
        void *address = FLEXCHookResolveSymbolForLocator(symbol, entry.locator);
        if (address && FLEXMSHookFunctionProviderAvailable()) {
            installed = FLEXHookFunctionIfAvailable(address, replacement, &slot->original);
        }
    }

    void *original = slot->original;
    if (!installed || !original || original == replacement) {
        if (error) {
            NSString *description = backend == FLEXHookBackendFishhook
                ? @"fishhook found no validated import slot/original"
                : @"MSHookFunction did not produce a valid trampoline";
            *error = [NSError errorWithDomain:@"FLEXCHookEngine"
                                          code:4
                                      userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        return NO;
    }

    entry.original = original;
    entry.backend = backend;
    entry.installed = YES;
    entry.stale = NO;
    [self setEnabled:entry.pendingEnabled forEntry:entry];
    return YES;
}

+ (void)setEnabled:(BOOL)enabled forEntry:(FLEXHookEntry *)entry {
    if (!entry || entry.runtimeSlot == NSNotFound ||
        entry.runtimeSlot < 0 || entry.runtimeSlot >= FLEX_C_SLOT_COUNT) {
        return;
    }
    FLEXCHookSlot *slot = &gFLEXCHookSlots[entry.runtimeSlot];
    // Bool profiles keep using forceValue; the typed profiles read forceRawValue
    // (signed/unsigned int, pointer bits, or IEEE-754 double/float bits). All are
    // published before enabling so the stub never reads a stale value.
    atomic_store_explicit(&slot->forceBool, entry.forceValue, memory_order_relaxed);
    switch (entry.abi) {
        case FLEXHookABICInt64NoArguments:
            atomic_store_explicit(&slot->forceInt64,
                (long long)entry.forceRawValue, memory_order_relaxed);
            break;
        case FLEXHookABICPointerNoArguments:
            atomic_store_explicit(&slot->forcePointer,
                (uintptr_t)entry.forceRawValue, memory_order_relaxed);
            break;
        case FLEXHookABICDoubleNoArguments:
        case FLEXHookABICFloatNoArguments:
            atomic_store_explicit(&slot->forceRaw,
                entry.forceRawValue, memory_order_relaxed);
            break;
        default:
            // Bool profiles: mirror the bool into the int64 lane for callers that
            // read it, and keep the pointer lane at NULL (never a fabricated
            // address).
            atomic_store_explicit(&slot->forceInt64,
                entry.forceValue ? 1 : 0, memory_order_relaxed);
            atomic_store_explicit(&slot->forcePointer, 0, memory_order_relaxed);
            break;
    }
    atomic_store_explicit(&slot->enabled, enabled, memory_order_release);
}

+ (NSUInteger)hitCountForEntry:(FLEXHookEntry *)entry {
    if (!entry || entry.runtimeSlot == NSNotFound ||
        entry.runtimeSlot < 0 || entry.runtimeSlot >= FLEX_C_SLOT_COUNT) {
        return 0;
    }
    return (NSUInteger)atomic_load_explicit(
        &gFLEXCHookSlots[entry.runtimeSlot].hits,
        memory_order_relaxed
    );
}

+ (NSUInteger)overrideHitCountForEntry:(FLEXHookEntry *)entry {
    if (!entry || entry.runtimeSlot == NSNotFound ||
        entry.runtimeSlot < 0 || entry.runtimeSlot >= FLEX_C_SLOT_COUNT) {
        return 0;
    }
    return (NSUInteger)atomic_load_explicit(
        &gFLEXCHookSlots[entry.runtimeSlot].overrideHits,
        memory_order_relaxed
    );
}

+ (void)refreshAvailabilityForEntry:(FLEXHookEntry *)entry {
    if (!entry) {
        return;
    }
    NSString *imageFailure = nil;
    BOOL imageValid = FLEXCHookValidateImageLocator(entry.locator, &imageFailure);
    BOOL hasBind = imageValid &&
        [entry.locator[@"bindSlots"] unsignedIntegerValue] > 0;
    BOOL hasAddress = imageValid &&
        FLEXCHookResolveSymbolForLocator(entry.locator[@"symbol"], entry.locator) != NULL;
    FLEXHookBackend backend = entry.backend;
    if (backend == FLEXHookBackendAuto) {
        backend = hasBind ? FLEXHookBackendFishhook : FLEXHookBackendInlineElleKit;
    }

    if (backend == FLEXHookBackendFishhook) {
        entry.available = hasBind;
        entry.hookable = entry.available && entry.abi != FLEXHookABIUnknown &&
                         FLEXFlag(@"engine.fishhook");
    } else if (backend == FLEXHookBackendInlineElleKit) {
        entry.available = hasAddress && FLEXMSHookFunctionProviderAvailable();
        entry.hookable = entry.available && entry.abi != FLEXHookABIUnknown &&
                         FLEXFlag(@"engine.inline_ellekit");
    } else {
        entry.available = NO;
        entry.hookable = NO;
    }
    entry.stale = !entry.available;
    if (!entry.available) {
        entry.lastError = imageFailure ?: (backend == FLEXHookBackendFishhook
            ? @"No imported bind slot is available"
            : @"Symbol address or ElleKit provider is unavailable");
    } else if (entry.abi == FLEXHookABIUnknown) {
        entry.lastError = nil;
    } else {
        entry.lastError = nil;
    }
}

@end
