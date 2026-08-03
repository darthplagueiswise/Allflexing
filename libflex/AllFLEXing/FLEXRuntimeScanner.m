#import "FLEXRuntimeScanner.h"

#import "FLEXHookPersistence.h"
#import "FLEXHookRegistry.h"
#import "FLEXHooking.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

NSNotificationName const FLEXRuntimeImagesDidChangeNotification =
    @"FLEXRuntimeImagesDidChangeNotification";

const char *FLEXRuntimeScannerHostIsolationABIVersion =
    "AllFLEXing no-global-catalog host-image runtime scanner ABI 1";

static dispatch_queue_t FLEXRuntimeScannerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.allflexing.runtime-scanner",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_UTILITY,
                0
            )
        );
    });
    return queue;
}

static atomic_bool gFLEXRuntimeImageNotificationScheduled = false;

static void FLEXRuntimeImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;

    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &gFLEXRuntimeImageNotificationScheduled,
            &expected,
            true,
            memory_order_acq_rel,
            memory_order_relaxed)) {
        return;
    }

    // dyld invokes this callback while loader state is active. Never inspect
    // Objective-C metadata or Mach-O tables from the callback itself.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
        FLEXRuntimeScannerQueue(),
        ^{
            atomic_store_explicit(
                &gFLEXRuntimeImageNotificationScheduled,
                false,
                memory_order_release
            );
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter
                    postNotificationName:FLEXRuntimeImagesDidChangeNotification
                                  object:FLEXRuntimeScanner.class];
            });
        }
    );
}

static BOOL FLEXPathBelongsToCurrentHost(NSString *path) {
    if (!path.length) return NO;

    NSString *executablePath = NSBundle.mainBundle.executablePath;
    if (executablePath.length && [path isEqualToString:executablePath]) {
        return YES;
    }

    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    if (!bundlePath.length) return NO;
    NSString *prefix = [bundlePath stringByAppendingString:@"/"];
    return [path hasPrefix:prefix];
}

static NSString *FLEXUUIDForHeader(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64) return @"";

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_UUID &&
            command->cmdsize >= sizeof(struct uuid_command)) {
            const struct uuid_command *uuidCommand =
                (const struct uuid_command *)command;
            NSUUID *uuid = [[NSUUID alloc]
                initWithUUIDBytes:uuidCommand->uuid];
            return uuid.UUIDString ?: @"";
        }
        cursor += command->cmdsize;
    }
    return @"";
}

static NSString *FLEXUUIDForLoadedImagePath(NSString *path) {
    if (!path.length || !FLEXPathBelongsToCurrentHost(path)) return @"";

    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *genericHeader = _dyld_get_image_header(index);
        if (!rawPath || !genericHeader || genericHeader->magic != MH_MAGIC_64) {
            continue;
        }
        NSString *loadedPath = [NSString stringWithUTF8String:rawPath];
        if (![loadedPath isEqualToString:path]) continue;
        return FLEXUUIDForHeader((const struct mach_header_64 *)genericHeader);
    }
    return @"";
}

static const char *FLEXSkipObjCQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static FLEXHookABI FLEXExactObjectiveCABI(Method method) {
    if (!method) return FLEXHookABIUnknown;

    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (*FLEXSkipObjCQualifiers(returnType) != 'B') {
        return FLEXHookABIUnknown;
    }

    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount == 2) {
        return FLEXHookABIObjCBoolNoArguments;
    }
    if (argumentCount != 3) {
        return FLEXHookABIUnknown;
    }

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *argumentCode = FLEXSkipObjCQualifiers(argumentType);
    if (*argumentCode == '@' || *argumentCode == '#' || *argumentCode == ':') {
        return FLEXHookABIObjCBoolObjectArgument;
    }
    if (strchr("BcCsSiIlLqQ", *argumentCode)) {
        return FLEXHookABIObjCBoolIntegerArgument;
    }
    return FLEXHookABIUnknown;
}

static BOOL FLEXSelectorIsOperationalCandidate(const char *selectorName) {
    if (!selectorName || !selectorName[0]) return NO;
    if (strncmp(selectorName, "set", 3) == 0 ||
        strncmp(selectorName, "init", 4) == 0 ||
        strcmp(selectorName, "dealloc") == 0 ||
        strcmp(selectorName, "isEqual:") == 0 ||
        strcmp(selectorName, "respondsToSelector:") == 0) {
        return NO;
    }
    return YES;
}

@implementation FLEXRuntimeScanner

+ (void)startMonitoringImages {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        (void)FLEXRuntimeScannerQueue();
        _dyld_register_func_for_add_image(FLEXRuntimeImageAdded);
    });
}

+ (FLEXHookEntry *)objectiveCEntryForClass:(Class)targetClass
                                  selector:(SEL)selector
                               classMethod:(BOOL)classMethod {
    if (!targetClass || !selector ||
        !FLEXSelectorIsOperationalCandidate(sel_getName(selector))) {
        return nil;
    }

    const char *rawImage = class_getImageName(targetClass);
    if (!rawImage || !rawImage[0]) return nil;
    NSString *imagePath = [NSString stringWithUTF8String:rawImage];
    if (!FLEXPathBelongsToCurrentHost(imagePath)) return nil;

    NSString *imageUUID = FLEXUUIDForLoadedImagePath(imagePath);
    if (!imageUUID.length) return nil;

    Method method = classMethod
        ? class_getClassMethod(targetClass, selector)
        : class_getInstanceMethod(targetClass, selector);
    FLEXHookABI abi = FLEXExactObjectiveCABI(method);
    if (!method || abi == FLEXHookABIUnknown) return nil;

    const char *rawClassName = class_getName(targetClass);
    const char *rawSelectorName = sel_getName(selector);
    if (!rawClassName || !rawSelectorName) return nil;

    NSString *className = [NSString stringWithUTF8String:rawClassName];
    NSString *selectorName = [NSString stringWithUTF8String:rawSelectorName];
    if (!className.length || !selectorName.length) return nil;

    const char *rawEncoding = method_getTypeEncoding(method);
    NSString *encoding = rawEncoding
        ? [NSString stringWithUTF8String:rawEncoding] : @"";
    NSString *host = NSBundle.mainBundle.bundleIdentifier
        ?: NSProcessInfo.processInfo.processName
        ?: @"host";

    BOOL providerAvailable = FLEXMSHookMessageProviderAvailable();
    BOOL engineEnabled = FLEXFlag(@"engine.objc_ellekit");

    FLEXHookEntry *entry = [FLEXHookEntry new];
    entry.identifier = [NSString stringWithFormat:@"objc|%@|%@|%@|%@|%@",
        host,
        imageUUID,
        className,
        classMethod ? @"+" : @"-",
        selectorName];
    entry.title = [NSString stringWithFormat:@"%@[%@ %@]",
        classMethod ? @"+" : @"-", className, selectorName];
    entry.detail = [NSString stringWithFormat:@"%@ · %@",
        FLEXHookABIName(abi), encoding];
    entry.imageName = imagePath.lastPathComponent ?: imagePath;
    entry.surface = FLEXHookSurfaceObjectiveC;
    entry.backend = FLEXHookBackendObjectiveCElleKit;
    entry.abi = abi;
    entry.locator = @{
        @"source": @"objc-runtime-row",
        @"host": host,
        @"class": className,
        @"selector": selectorName,
        @"classMethod": @(classMethod),
        @"encoding": encoding,
        @"image": imagePath,
        @"imageUUID": imageUUID,
        @"methodAddress": @((uintptr_t)method_getImplementation(method)),
    };
    entry.available = providerAvailable;
    entry.hookable = providerAvailable && engineEnabled;
    entry.stale = NO;
    if (!providerAvailable) {
        entry.lastError = @"Substrate-compatible provider unavailable";
    } else if (!engineEnabled) {
        entry.lastError = @"Objective-C/ElleKit engine is disabled";
    }
    return entry;
}

+ (void)scanObjectiveCRuntimeIncludingSystemImages:(BOOL)includeSystemImages
                                         completion:(FLEXRuntimeScanCompletion)completion {
    (void)includeSystemImages;
    // Deliberately disabled. The Runtime Workspace must scan one explicitly
    // selected Mach-O through FLEXRuntimeImageSession. A process-wide catalog
    // is not valid input for the operational hook browser.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(@[]);
    });
}

+ (void)scanCImportsIncludingSystemImages:(BOOL)includeSystemImages
                                completion:(FLEXRuntimeScanCompletion)completion {
    (void)includeSystemImages;
    // Deliberately disabled for the same reason as the Objective-C global scan.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) completion(@[]);
    });
}

+ (FLEXHookEntry *)manualCEntryForSymbol:(NSString *)symbol
                               imageName:(NSString *)imageName {
    NSString *normalized = [symbol hasPrefix:@"_"]
        ? [symbol substringFromIndex:1] : symbol;
    NSString *resolvedImage = imageName ?: @"";
    NSString *imageUUID = FLEXUUIDForLoadedImagePath(resolvedImage);
    NSString *host = NSBundle.mainBundle.bundleIdentifier
        ?: NSProcessInfo.processInfo.processName
        ?: @"host";

    FLEXHookEntry *entry = [FLEXHookEntry new];
    entry.identifier = [NSString stringWithFormat:@"c-inline|%@|%@|%@",
        host,
        imageUUID.length ? imageUUID : @"unresolved-image",
        normalized ?: @""];
    entry.title = normalized ?: @"";
    entry.detail = @"Manual inline target · explicit ABI required";
    entry.imageName = resolvedImage.lastPathComponent ?: @"Unresolved image";
    entry.surface = FLEXHookSurfaceCInline;
    entry.backend = FLEXHookBackendInlineElleKit;
    entry.abi = FLEXHookABIUnknown;
    entry.locator = @{
        @"source": @"manual-current-host",
        @"host": host,
        @"symbol": normalized ?: @"",
        @"image": resolvedImage,
        @"imageUUID": imageUUID,
        @"bindSlots": @0,
    };
    entry.available = normalized.length > 0 && imageUUID.length > 0 &&
        FLEXMSHookFunctionProviderAvailable();
    entry.hookable = NO;
    entry.userConfigured = YES;
    entry.lastError = entry.available
        ? nil : @"Select a currently loaded host image before resolving this symbol";
    return entry;
}

@end
