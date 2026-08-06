#import "FLEXRuntimeHostIdentity.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>

const char *FLEXRuntimeHostIsolationABIVersion =
    "AllFLEXing current-host image identity ABI 1";

static NSString *FLEXSanitizedScope(NSString *value) {
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

NSString *FLEXCurrentHostBundleIdentifier(void) {
    return NSBundle.mainBundle.bundleIdentifier.length
        ? NSBundle.mainBundle.bundleIdentifier
        : (NSProcessInfo.processInfo.processName ?: @"host");
}

NSString *FLEXCurrentHostScope(void) {
    return FLEXSanitizedScope(FLEXCurrentHostBundleIdentifier());
}

static NSString *FLEXUUIDForHeader(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) return @"";
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuid = (const struct uuid_command *)command;
            NSUUID *value = [[NSUUID alloc] initWithUUIDBytes:uuid->uuid];
            return value.UUIDString ?: @"";
        }
        cursor += command->cmdsize;
    }
    return @"";
}

NSString *FLEXRuntimeImageUUIDAtPath(NSString *path) {
    if (!path.length) return @"";
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *genericHeader = _dyld_get_image_header(index);
        if (!rawPath || !genericHeader || genericHeader->magic != MH_MAGIC_64) continue;
        NSString *candidate = [NSString stringWithUTF8String:rawPath];
        if (![candidate isEqualToString:path]) continue;
        return FLEXUUIDForHeader((const struct mach_header_64 *)genericHeader);
    }
    return @"";
}

NSString *FLEXCurrentHostExecutableUUID(void) {
    return FLEXRuntimeImageUUIDAtPath(NSBundle.mainBundle.executablePath ?: @"");
}

BOOL FLEXRuntimeImageIsAllowedHostImage(NSString *path) {
    if (!path.length) return NO;
    NSString *mainExecutable = NSBundle.mainBundle.executablePath;
    if (mainExecutable.length && [path isEqualToString:mainExecutable]) return YES;

    NSString *frameworks = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Frameworks"];
    NSString *prefix = [frameworks stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) return NO;

    // Embedded app frameworks are accepted. Plain injected dylibs in
    // Frameworks are intentionally excluded so one tweak cannot become the
    // runtime catalogue of every host app.
    for (NSString *component in path.pathComponents) {
        if ([component.pathExtension caseInsensitiveCompare:@"framework"] ==
            NSOrderedSame) {
            return YES;
        }
    }
    return NO;
}

NSDictionary<NSString *, id> *
FLEXLocatorByAddingCurrentHostIdentity(NSDictionary<NSString *, id> *locator) {
    NSMutableDictionary<NSString *, id> *result = [locator mutableCopy]
        ?: [NSMutableDictionary dictionary];
    result[@"hostBundleIdentifier"] = FLEXCurrentHostBundleIdentifier();
    result[@"hostExecutableUUID"] = FLEXCurrentHostExecutableUUID();
    NSString *image = [result[@"image"] isKindOfClass:NSString.class]
        ? result[@"image"] : @"";
    if (image.length) {
        result[@"imageUUID"] = FLEXRuntimeImageUUIDAtPath(image);
    }
    return result.copy;
}

BOOL FLEXLocatorMatchesCurrentHost(NSDictionary<NSString *, id> *locator) {
    if (![locator isKindOfClass:NSDictionary.class]) return NO;
    NSString *host = [locator[@"hostBundleIdentifier"] isKindOfClass:NSString.class]
        ? locator[@"hostBundleIdentifier"] : @"";
    NSString *hostUUID = [locator[@"hostExecutableUUID"] isKindOfClass:NSString.class]
        ? locator[@"hostExecutableUUID"] : @"";
    if (![host isEqualToString:FLEXCurrentHostBundleIdentifier()] ||
        !hostUUID.length ||
        [hostUUID caseInsensitiveCompare:FLEXCurrentHostExecutableUUID()] != NSOrderedSame) {
        return NO;
    }

    NSString *image = [locator[@"image"] isKindOfClass:NSString.class]
        ? locator[@"image"] : @"";
    NSString *savedImageUUID = [locator[@"imageUUID"] isKindOfClass:NSString.class]
        ? locator[@"imageUUID"] : @"";
    if (!image.length || !savedImageUUID.length ||
        !FLEXRuntimeImageIsAllowedHostImage(image)) {
        return NO;
    }
    NSString *currentImageUUID = FLEXRuntimeImageUUIDAtPath(image);
    return currentImageUUID.length &&
        [savedImageUUID caseInsensitiveCompare:currentImageUUID] == NSOrderedSame;
}
