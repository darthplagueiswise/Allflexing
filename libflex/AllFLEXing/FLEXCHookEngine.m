#import "FLEXCHookEngine.h"

#import "FLEXHookRegistry.h"
#import "FLEXHookPersistence.h"
#import "FLEXHooking.h"
#import "FLEXSymbolRebind.h"

#import <dlfcn.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>
#import <string.h>

#define FLEX_C_SLOT_COUNT 32
#define FLEX_C_SLOTS_PER_ABI 8

typedef struct {
    atomic_bool allocated;
    atomic_bool enabled;
    atomic_bool forceBool;
    atomic_llong forceInt64;
    atomic_uintptr_t forcePointer;
    atomic_ullong hits;
    void *original;
    FLEXHookABI abi;
    char identifier[256];
} FLEXCHookSlot;

static FLEXCHookSlot gFLEXCHookSlots[FLEX_C_SLOT_COUNT];

static bool FLEXCallBool0(NSUInteger index) {
    FLEXCHookSlot *slot = &gFLEXCHookSlots[index];
    bool (*original)(void) = (bool (*)(void))slot->original;
    bool native = original ? original() : false;
    atomic_fetch_add_explicit(&slot->hits, 1, memory_order_relaxed);
    return atomic_load_explicit(&slot->enabled, memory_order_acquire)
        ? atomic_load_explicit(&slot->forceBool, memory_order_relaxed)
        : native;
}

static bool FLEXCallBoolPointer(NSUInteger index, void *argument) {
    FLEXCHookSlot *slot = &gFLEXCHookSlots[index];
    bool (*original)(void *) = (bool (*)(void *))slot->original;
    bool native = original ? original(argument) : false;
    atomic_fetch_add_explicit(&slot->hits, 1, memory_order_relaxed);
    return atomic_load_explicit(&slot->enabled, memory_order_acquire)
        ? atomic_load_explicit(&slot->forceBool, memory_order_relaxed)
        : native;
}

static int64_t FLEXCallInt64NoArgs(NSUInteger index) {
    FLEXCHookSlot *slot = &gFLEXCHookSlots[index];
    int64_t (*original)(void) = (int64_t (*)(void))slot->original;
    int64_t native = original ? original() : 0;
    atomic_fetch_add_explicit(&slot->hits, 1, memory_order_relaxed);
    return atomic_load_explicit(&slot->enabled, memory_order_acquire)
        ? atomic_load_explicit(&slot->forceInt64, memory_order_relaxed)
        : native;
}

static void *FLEXCallPointerNoArgs(NSUInteger index) {
    FLEXCHookSlot *slot = &gFLEXCHookSlots[index];
    void *(*original)(void) = (void *(*)(void))slot->original;
    void *native = original ? original() : NULL;
    atomic_fetch_add_explicit(&slot->hits, 1, memory_order_relaxed);
    return atomic_load_explicit(&slot->enabled, memory_order_acquire)
        ? (void *)atomic_load_explicit(&slot->forcePointer, memory_order_relaxed)
        : native;
}

#define FLEX_BOOL0_STUB(N, INDEX) static bool FLEXCBool0_##N(void) { return FLEXCallBool0(INDEX); }
#define FLEX_BOOLPTR_STUB(N, INDEX) static bool FLEXCBoolPointer_##N(void *arg) { return FLEXCallBoolPointer(INDEX, arg); }
#define FLEX_INT64_STUB(N, INDEX) static int64_t FLEXCInt64_##N(void) { return FLEXCallInt64NoArgs(INDEX); }
#define FLEX_POINTER_STUB(N, INDEX) static void *FLEXCPointer_##N(void) { return FLEXCallPointerNoArgs(INDEX); }

FLEX_BOOL0_STUB(0, 0) FLEX_BOOL0_STUB(1, 1) FLEX_BOOL0_STUB(2, 2) FLEX_BOOL0_STUB(3, 3)
FLEX_BOOL0_STUB(4, 4) FLEX_BOOL0_STUB(5, 5) FLEX_BOOL0_STUB(6, 6) FLEX_BOOL0_STUB(7, 7)
FLEX_BOOLPTR_STUB(0, 8) FLEX_BOOLPTR_STUB(1, 9) FLEX_BOOLPTR_STUB(2, 10) FLEX_BOOLPTR_STUB(3, 11)
FLEX_BOOLPTR_STUB(4, 12) FLEX_BOOLPTR_STUB(5, 13) FLEX_BOOLPTR_STUB(6, 14) FLEX_BOOLPTR_STUB(7, 15)
FLEX_INT64_STUB(0, 16) FLEX_INT64_STUB(1, 17) FLEX_INT64_STUB(2, 18) FLEX_INT64_STUB(3, 19)
FLEX_INT64_STUB(4, 20) FLEX_INT64_STUB(5, 21) FLEX_INT64_STUB(6, 22) FLEX_INT64_STUB(7, 23)
FLEX_POINTER_STUB(0, 24) FLEX_POINTER_STUB(1, 25) FLEX_POINTER_STUB(2, 26) FLEX_POINTER_STUB(3, 27)
FLEX_POINTER_STUB(4, 28) FLEX_POINTER_STUB(5, 29) FLEX_POINTER_STUB(6, 30) FLEX_POINTER_STUB(7, 31)

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

static NSRange FLEXSlotRangeForABI(FLEXHookABI abi) {
    switch (abi) {
        case FLEXHookABICBoolNoArguments: return NSMakeRange(0, FLEX_C_SLOTS_PER_ABI);
        case FLEXHookABICBoolPointerArgument: return NSMakeRange(8, FLEX_C_SLOTS_PER_ABI);
        case FLEXHookABICInt64NoArguments: return NSMakeRange(16, FLEX_C_SLOTS_PER_ABI);
        case FLEXHookABICPointerNoArguments: return NSMakeRange(24, FLEX_C_SLOTS_PER_ABI);
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
            atomic_init(&slot->forceInt64, entry.forceValue ? 1 : 0);
            atomic_init(&slot->forcePointer, entry.forceValue ? 1 : 0);
            atomic_init(&slot->hits, 0);
            atomic_store_explicit(&slot->allocated, true, memory_order_release);
            entry.runtimeSlot = (NSInteger)index;
            return (NSInteger)index;
        }
    }
    return NSNotFound;
}

@implementation FLEXCHookEngine

+ (void *)resolveSymbol:(NSString *)symbol {
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

+ (BOOL)installEntry:(FLEXHookEntry *)entry error:(NSError **)error {
    if (!entry || entry.abi == FLEXHookABIUnknown) {
        if (error) {
            *error = [NSError errorWithDomain:@"FLEXCHookEngine"
                                          code:1
                                      userInfo:@{NSLocalizedDescriptionKey: @"C ABI is unknown"}];
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

    void *original = NULL;
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
                                           original:&original];
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
        void *address = [self resolveSymbol:symbol];
        if (address && FLEXMSHookProviderAvailable()) {
            installed = FLEXHookFunctionIfAvailable(address, replacement, &original);
        }
    }

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

    slot->original = original;
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
    atomic_store_explicit(&slot->forceBool, entry.forceValue, memory_order_relaxed);
    atomic_store_explicit(&slot->forceInt64, entry.forceValue ? 1 : 0, memory_order_relaxed);
    atomic_store_explicit(&slot->forcePointer, entry.forceValue ? 1 : 0, memory_order_relaxed);
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

+ (void)refreshAvailabilityForEntry:(FLEXHookEntry *)entry {
    if (!entry) {
        return;
    }
    BOOL hasBind = [entry.locator[@"bindSlots"] unsignedIntegerValue] > 0;
    BOOL hasAddress = [self resolveSymbol:entry.locator[@"symbol"]] != NULL;
    FLEXHookBackend backend = entry.backend;
    if (backend == FLEXHookBackendAuto) {
        backend = hasBind ? FLEXHookBackendFishhook : FLEXHookBackendInlineElleKit;
    }

    if (backend == FLEXHookBackendFishhook) {
        entry.available = hasBind;
        entry.hookable = entry.available && entry.abi != FLEXHookABIUnknown &&
                         FLEXFlag(@"engine.fishhook");
    } else if (backend == FLEXHookBackendInlineElleKit) {
        entry.available = hasAddress && FLEXMSHookProviderAvailable();
        entry.hookable = entry.available && entry.abi != FLEXHookABIUnknown &&
                         FLEXFlag(@"engine.inline_ellekit");
    } else {
        entry.available = NO;
        entry.hookable = NO;
    }
    entry.stale = !entry.available;
    if (!entry.available) {
        entry.lastError = backend == FLEXHookBackendFishhook
            ? @"No imported bind slot is available"
            : @"Symbol address or ElleKit provider is unavailable";
    } else if (entry.abi == FLEXHookABIUnknown) {
        entry.lastError = nil;
    } else {
        entry.lastError = nil;
    }
}

@end
