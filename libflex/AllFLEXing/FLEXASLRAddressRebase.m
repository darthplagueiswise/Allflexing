#import "FLEXABIResolver.h"
#import "FLEXCHookEngine.h"
#import "FLEXHookRegistry.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#import <objc/runtime.h>

const char *FLEXASLRAddressRebaseABIVersion =
    "AllFLEXing image-UUID header-plus-offset ASLR rebase ABI 1";

typedef BOOL (*FLEXInstallEntryIMP)(id, SEL, FLEXHookEntry *, NSError **);
typedef void (*FLEXRefreshEntryIMP)(id, SEL, FLEXHookEntry *);
typedef void (*FLEXResolveEntryIMP)(id, SEL, FLEXHookEntry *, void (^)(FLEXABIResolution *));

static FLEXInstallEntryIMP gFLEXNextInstallEntry = NULL;
static FLEXRefreshEntryIMP gFLEXNextRefreshEntry = NULL;
static FLEXResolveEntryIMP gFLEXNextResolveEntry = NULL;

static BOOL FLEXASLRPathMatches(NSString *requested, NSString *loaded) {
    if (!requested.length || !loaded.length) return NO;
    return [requested containsString:@"/"]
        ? [requested isEqualToString:loaded]
        : [requested.lastPathComponent isEqualToString:loaded.lastPathComponent];
}

static NSString *FLEXASLRImageUUID(const struct mach_header_64 *header) {
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

static BOOL FLEXASLRAddressIsExecutable(const struct mach_header_64 *header,
                                        intptr_t slide,
                                        uintptr_t address) {
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
                if (address >= start && address + sizeof(uint32_t) <= end) {
                    return YES;
                }
            }
        }
        cursor += command->cmdsize;
    }
    return NO;
}

static BOOL FLEXASLRRebaseEntry(FLEXHookEntry *entry, NSString **failure) {
    if (!entry || entry.surface != FLEXHookSurfaceCInline) return YES;

    NSDictionary *locator = entry.locator;
    NSString *imagePath = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : nil;
    NSNumber *offsetNumber = [locator[@"offset"] isKindOfClass:NSNumber.class]
        ? locator[@"offset"] : nil;
    if (!imagePath.length || !offsetNumber) {
        // Compatibility entries that predate image-relative locators continue
        // through the next engine, which may resolve an exported symbol.
        return YES;
    }

    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *genericHeader = _dyld_get_image_header(index);
        if (!rawPath || !genericHeader || genericHeader->magic != MH_MAGIC_64) continue;
        NSString *loadedPath = [NSString stringWithUTF8String:rawPath];
        if (!FLEXASLRPathMatches(imagePath, loadedPath)) continue;

        const struct mach_header_64 *header =
            (const struct mach_header_64 *)genericHeader;
        NSString *expectedUUID = [locator[@"imageUUID"]
            isKindOfClass:NSString.class] ? locator[@"imageUUID"] : nil;
        if (expectedUUID.length) {
            NSString *currentUUID = FLEXASLRImageUUID(header);
            if (!currentUUID.length ||
                [expectedUUID caseInsensitiveCompare:currentUUID] != NSOrderedSame) {
                if (failure) *failure = @"Image UUID changed; rescan and resolve the ABI again";
                return NO;
            }
        }

        uintptr_t base = (uintptr_t)header;
        unsigned long long rawOffset = offsetNumber.unsignedLongLongValue;
        if (rawOffset > UINTPTR_MAX - base) {
            if (failure) *failure = @"Image-relative function offset overflowed";
            return NO;
        }
        uintptr_t currentAddress = base + (uintptr_t)rawOffset;
        intptr_t slide = _dyld_get_image_vmaddr_slide(index);
        if (!FLEXASLRAddressIsExecutable(header, slide, currentAddress)) {
            if (failure) *failure = @"Rebased target is outside the current image executable segments";
            return NO;
        }

        NSMutableDictionary *updated = locator.mutableCopy;
        updated[@"address"] = @(currentAddress);
        updated[@"rebasedFromOffset"] = @YES;
        updated[@"loadedImagePath"] = loadedPath;
        entry.locator = updated.copy;
        return YES;
    }

    if (failure) *failure = @"Selected Mach-O image is not currently loaded";
    return NO;
}

static BOOL FLEXASLRInstallEntry(id object,
                                 SEL selector,
                                 FLEXHookEntry *entry,
                                 NSError **error) {
    NSString *failure = nil;
    if (!FLEXASLRRebaseEntry(entry, &failure)) {
        if (error) {
            *error = [NSError errorWithDomain:@"FLEXASLRAddressRebase"
                                          code:1
                                      userInfo:@{NSLocalizedDescriptionKey:
                                          failure ?: @"Unable to rebase C target"}];
        }
        return NO;
    }
    return gFLEXNextInstallEntry
        ? gFLEXNextInstallEntry(object, selector, entry, error)
        : NO;
}

static void FLEXASLRRefreshEntry(id object,
                                 SEL selector,
                                 FLEXHookEntry *entry) {
    NSString *failure = nil;
    if (!FLEXASLRRebaseEntry(entry, &failure)) {
        entry.available = NO;
        entry.hookable = NO;
        entry.stale = YES;
        entry.lastError = failure;
        return;
    }
    if (gFLEXNextRefreshEntry) {
        gFLEXNextRefreshEntry(object, selector, entry);
    }
}

static void FLEXASLRResolveEntry(id object,
                                 SEL selector,
                                 FLEXHookEntry *entry,
                                 void (^completion)(FLEXABIResolution *)) {
    FLEXHookEntry *rebased = [entry copy];
    NSString *failure = nil;
    if (!FLEXASLRRebaseEntry(rebased, &failure)) {
        FLEXABIResolution *resolution = [FLEXABIResolution new];
        resolution.abi = FLEXHookABIUnknown;
        resolution.backend = FLEXHookBackendNone;
        resolution.confidence = FLEXABIResolutionConfidenceUnknown;
        resolution.symbolResolved = NO;
        resolution.canAutoApply = NO;
        resolution.summary = @"Unknown · Unknown ABI · No backend";
        resolution.evidence = failure.length ? @[failure] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(resolution);
        });
        return;
    }
    if (gFLEXNextResolveEntry) {
        gFLEXNextResolveEntry(object, selector, rebased, completion);
    }
}

static void FLEXInstallASLRRebase(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cEngineMeta = object_getClass(FLEXCHookEngine.class);
        Method install = class_getInstanceMethod(
            cEngineMeta,
            @selector(installEntry:error:)
        );
        Method refresh = class_getInstanceMethod(
            cEngineMeta,
            @selector(refreshAvailabilityForEntry:)
        );
        if (install) {
            gFLEXNextInstallEntry = (FLEXInstallEntryIMP)
                method_getImplementation(install);
            method_setImplementation(install, (IMP)FLEXASLRInstallEntry);
        }
        if (refresh) {
            gFLEXNextRefreshEntry = (FLEXRefreshEntryIMP)
                method_getImplementation(refresh);
            method_setImplementation(refresh, (IMP)FLEXASLRRefreshEntry);
        }

        Class resolverMeta = object_getClass(FLEXABIResolver.class);
        Method resolve = class_getInstanceMethod(
            resolverMeta,
            @selector(resolveEntry:completion:)
        );
        if (resolve) {
            gFLEXNextResolveEntry = (FLEXResolveEntryIMP)
                method_getImplementation(resolve);
            method_setImplementation(resolve, (IMP)FLEXASLRResolveEntry);
        }
    });
}

__attribute__((constructor))
static void FLEXASLRAddressRebaseBootstrap(void) {
    // Run after Objective-C +load categories have established the provider and
    // address-engine chains, then wrap their final implementations once.
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            FLEXInstallASLRRebase();
        });
    });
}
