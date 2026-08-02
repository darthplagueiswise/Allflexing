#import "FLEXCHookEngine.h"

#import "FLEXHookRegistry.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>

static NSString *FLEXResolverImageUUID(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) return @"";
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid =
                (const struct uuid_command *)command;
            NSUUID *value = [[NSUUID alloc] initWithUUIDBytes:uuid->uuid];
            return value.UUIDString ?: @"";
        }
        cursor += command->cmdsize;
    }
    return @"";
}

static BOOL FLEXResolverPathMatches(NSString *requested, NSString *loaded) {
    if (!requested.length || !loaded.length) return NO;
    return [requested containsString:@"/"]
        ? [requested isEqualToString:loaded]
        : [requested.lastPathComponent isEqualToString:loaded.lastPathComponent];
}

@implementation FLEXCHookEngine (AllFLEXingAddressResolverAPI)

+ (void *)resolveAddressForEntry:(FLEXHookEntry *)entry {
    NSNumber *addressNumber = [entry.locator[@"address"]
        isKindOfClass:NSNumber.class] ? entry.locator[@"address"] : nil;
    NSString *requestedPath = [entry.locator[@"image"]
        isKindOfClass:NSString.class] ? entry.locator[@"image"] : nil;
    if (!addressNumber.unsignedLongLongValue || !requestedPath.length) return NULL;

    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *genericHeader = _dyld_get_image_header(index);
        if (!rawPath || !genericHeader || genericHeader->magic != MH_MAGIC_64) continue;
        NSString *loadedPath = [NSString stringWithUTF8String:rawPath];
        if (!FLEXResolverPathMatches(requestedPath, loadedPath)) continue;

        const struct mach_header_64 *header =
            (const struct mach_header_64 *)genericHeader;
        NSString *expectedUUID = [entry.locator[@"imageUUID"]
            isKindOfClass:NSString.class] ? entry.locator[@"imageUUID"] : nil;
        if (expectedUUID.length) {
            NSString *loadedUUID = FLEXResolverImageUUID(header);
            if (!loadedUUID.length ||
                [expectedUUID caseInsensitiveCompare:loadedUUID] != NSOrderedSame) {
                return NULL;
            }
        }

        uintptr_t address = (uintptr_t)addressNumber.unsignedLongLongValue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(index);
        const uint8_t *cursor = (const uint8_t *)(header + 1);
        for (uint32_t commandIndex = 0;
             commandIndex < header->ncmds;
             commandIndex++) {
            const struct load_command *command =
                (const struct load_command *)cursor;
            if (command->cmdsize < sizeof(struct load_command)) break;
            if (command->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *segment =
                    (const struct segment_command_64 *)command;
                if ((segment->initprot & VM_PROT_EXECUTE) && segment->vmsize) {
                    uintptr_t start = (uintptr_t)(segment->vmaddr + slide);
                    uintptr_t end = start + (uintptr_t)segment->vmsize;
                    if (address >= start && address + sizeof(uint32_t) <= end) {
                        return (void *)address;
                    }
                }
            }
            cursor += command->cmdsize;
        }
        return NULL;
    }
    return NULL;
}

@end
