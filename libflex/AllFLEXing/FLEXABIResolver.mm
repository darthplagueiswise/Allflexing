#import "FLEXABIResolver.h"

#import "FLEXHooking.h"

#import <cxxabi.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#import <objc/runtime.h>

const char *FLEXABIResolverABIVersion =
    "AllFLEXing image-scoped ARM64 evidence ABI resolver ABI 2";

@implementation FLEXABIResolution
@end

static dispatch_queue_t FLEXABIResolverQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.allflexing.abi-resolver",
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL,
                QOS_CLASS_USER_INITIATED,
                0
            )
        );
    });
    return queue;
}

static const char *FLEXSkipTypeQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type++;
    }
    return type;
}

static FLEXHookABI FLEXObjectiveCABI(Method method) {
    if (!method) return FLEXHookABIUnknown;
    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *returnCode = FLEXSkipTypeQualifiers(returnType);
    if (*returnCode != 'B') return FLEXHookABIUnknown;

    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return FLEXHookABIObjCBoolNoArguments;
    if (count != 3) return FLEXHookABIUnknown;

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *argumentCode = FLEXSkipTypeQualifiers(argumentType);
    if (*argumentCode == '@' || *argumentCode == '#' || *argumentCode == ':') {
        return FLEXHookABIObjCBoolObjectArgument;
    }
    if (strchr("BcCsSiIlLqQ", *argumentCode)) {
        return FLEXHookABIObjCBoolIntegerArgument;
    }
    return FLEXHookABIUnknown;
}

static NSString *FLEXNormalizedSymbol(NSString *symbol) {
    return [symbol hasPrefix:@"_"] ? [symbol substringFromIndex:1] : symbol;
}

static NSDictionary<NSString *, NSNumber *> *FLEXKnownCSignatures(void) {
    static NSDictionary<NSString *, NSNumber *> *signatures;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        signatures = @{
            @"arc4random": @(FLEXHookABICInt64NoArguments),
            @"getpid": @(FLEXHookABICInt64NoArguments),
            @"getppid": @(FLEXHookABICInt64NoArguments),
            @"getuid": @(FLEXHookABICInt64NoArguments),
            @"geteuid": @(FLEXHookABICInt64NoArguments),
            @"getgid": @(FLEXHookABICInt64NoArguments),
            @"getegid": @(FLEXHookABICInt64NoArguments),
            @"mach_absolute_time": @(FLEXHookABICInt64NoArguments),
        };
    });
    return signatures;
}

static NSString *FLEXDemangleSymbol(NSString *symbol) {
    NSString *normalized = FLEXNormalizedSymbol(symbol);
    if (!normalized.length) return @"";
    int status = 0;
    char *demangled = abi::__cxa_demangle(normalized.UTF8String, NULL, NULL, &status);
    if (!demangled || status != 0) {
        if (demangled) free(demangled);
        return @"";
    }
    NSString *result = [NSString stringWithUTF8String:demangled] ?: @"";
    free(demangled);
    return result;
}

static BOOL FLEXLoadedImage(NSString *path,
                            const struct mach_header_64 **header,
                            intptr_t *slide) {
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *generic = _dyld_get_image_header(index);
        if (!rawPath || !generic || generic->magic != MH_MAGIC_64) continue;
        NSString *candidate = [NSString stringWithUTF8String:rawPath];
        if (![candidate isEqualToString:path]) continue;
        if (header) *header = (const struct mach_header_64 *)generic;
        if (slide) *slide = _dyld_get_image_vmaddr_slide(index);
        return YES;
    }
    return NO;
}

static int64_t FLEXSignExtend(uint64_t value, unsigned bits) {
    uint64_t mask = 1ULL << (bits - 1);
    return (int64_t)((value ^ mask) - mask);
}

static BOOL FLEXARM64BranchTarget(uint32_t instruction,
                                  uintptr_t pc,
                                  uintptr_t *target) {
    if ((instruction & 0xFC000000u) != 0x94000000u) return NO;
    int64_t displacement = FLEXSignExtend(instruction & 0x03FFFFFFu, 26) << 2;
    if (target) *target = (uintptr_t)((int64_t)pc + displacement);
    return YES;
}

static BOOL FLEXARM64WritesRegister(uint32_t instruction,
                                    unsigned *registerIndex,
                                    BOOL *pointerLike) {
    unsigned rd = instruction & 0x1f;
    if (rd > 7) return NO;

    BOOL writes = NO;
    BOOL pointer = NO;
    if ((instruction & 0x1F000000u) == 0x10000000u) {
        writes = YES;
        pointer = YES; // ADR/ADRP
    } else if ((instruction & 0x1F800000u) == 0x12800000u) {
        writes = YES; // MOVN/MOVZ/MOVK
    } else if ((instruction & 0x1F000000u) == 0x11000000u) {
        writes = YES; // ADD/SUB immediate
    } else if ((instruction & 0x1F000000u) == 0x0A000000u ||
               (instruction & 0x1F000000u) == 0x0B000000u) {
        writes = YES; // logical/add-sub register
    } else if ((instruction & 0x3B000000u) == 0x18000000u) {
        writes = YES;
        pointer = (instruction & 0x40000000u) != 0; // literal load width
    } else if ((instruction & 0x3B000000u) == 0x39000000u &&
               (instruction & (1u << 22))) {
        writes = YES; // load from memory
        pointer = ((instruction >> 30) & 0x3) == 0x3;
    } else if ((instruction & 0x1FE00000u) == 0x1A800000u) {
        writes = YES; // conditional select
    }

    if (!writes) return NO;
    if (registerIndex) *registerIndex = rd;
    if (pointerLike) *pointerLike = pointer;
    return YES;
}

static void FLEXAnalyzeReturnUse(uint32_t instruction,
                                 NSUInteger *boolVotes,
                                 NSUInteger *integerVotes,
                                 NSUInteger *pointerVotes) {
    unsigned rt = instruction & 0x1f;
    if (rt != 0) return;

    if ((instruction & 0x7E000000u) == 0x34000000u) {
        BOOL xRegister = (instruction & 0x80000000u) != 0;
        if (xRegister) (*pointerVotes)++;
        else (*boolVotes)++;
        return;
    }
    if ((instruction & 0x7E000000u) == 0x36000000u) {
        (*boolVotes)++;
        return;
    }
    if ((instruction & 0x7F00001Fu) == 0x7100001Fu &&
        ((instruction >> 5) & 0x1f) == 0) {
        (*integerVotes)++;
        return;
    }
    if ((instruction & 0x3B000000u) == 0x39000000u) {
        unsigned rn = (instruction >> 5) & 0x1f;
        BOOL load = (instruction & (1u << 22)) != 0;
        if (load && rn == 0) (*pointerVotes)++;
    }
}

static BOOL FLEXAddressMatchesTargets(uintptr_t address,
                                      NSSet<NSNumber *> *targets) {
    return [targets containsObject:@(address)];
}

static FLEXHookABI FLEXAnalyzeARM64CallSites(FLEXHookEntry *entry,
                                             NSMutableArray<NSString *> *evidence,
                                             FLEXABIResolutionConfidence *confidence) {
    NSString *imagePath = entry.locator[@"image"];
    const struct mach_header_64 *header = NULL;
    intptr_t slide = 0;
    if (!FLEXLoadedImage(imagePath, &header, &slide)) {
        [evidence addObject:@"Selected image is not currently loaded."];
        return FLEXHookABIUnknown;
    }

    NSMutableSet<NSNumber *> *targets = [NSMutableSet set];
    NSNumber *address = entry.locator[@"address"];
    if ([address isKindOfClass:NSNumber.class] && address.unsignedLongLongValue) {
        [targets addObject:address];
    }
    NSArray *stubs = entry.locator[@"stubAddresses"];
    if ([stubs isKindOfClass:NSArray.class]) {
        for (NSNumber *stub in stubs) {
            if ([stub isKindOfClass:NSNumber.class] && stub.unsignedLongLongValue) {
                [targets addObject:stub];
            }
        }
    }
    if (!targets.count) {
        [evidence addObject:@"No executable address or call stub was recorded for this entry."];
        return FLEXHookABIUnknown;
    }

    NSUInteger callSites = 0;
    NSUInteger boolVotes = 0;
    NSUInteger integerVotes = 0;
    NSUInteger pointerVotes = 0;
    NSUInteger maximumArguments = 0;
    NSUInteger pointerArgumentVotes = 0;

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if ((segment->initprot & VM_PROT_EXECUTE) && segment->vmsize) {
                uintptr_t start = (uintptr_t)(segment->vmaddr + slide);
                uintptr_t end = start + (uintptr_t)segment->vmsize;
                const uint32_t *instructions = (const uint32_t *)start;
                NSUInteger count = (end - start) / sizeof(uint32_t);
                for (NSUInteger index = 0; index < count; index++) {
                    uintptr_t pc = start + index * sizeof(uint32_t);
                    uintptr_t target = 0;
                    if (!FLEXARM64BranchTarget(instructions[index], pc, &target) ||
                        !FLEXAddressMatchesTargets(target, targets)) {
                        continue;
                    }
                    callSites++;
                    unsigned highestArgument = 0;
                    BOOL sawArgument = NO;
                    BOOL firstArgumentPointer = NO;
                    NSUInteger beginning = index > 8 ? index - 8 : 0;
                    for (NSUInteger previous = beginning; previous < index; previous++) {
                        unsigned reg = 0;
                        BOOL pointerLike = NO;
                        if (FLEXARM64WritesRegister(instructions[previous], &reg, &pointerLike)) {
                            highestArgument = MAX(highestArgument, reg);
                            sawArgument = YES;
                            if (reg == 0 && pointerLike) firstArgumentPointer = YES;
                        }
                    }
                    if (sawArgument) maximumArguments = MAX(maximumArguments, highestArgument + 1);
                    if (firstArgumentPointer) pointerArgumentVotes++;
                    for (NSUInteger after = 1; after <= 4 && index + after < count; after++) {
                        FLEXAnalyzeReturnUse(instructions[index + after],
                                             &boolVotes,
                                             &integerVotes,
                                             &pointerVotes);
                    }
                }
            }
        }
        cursor += command->cmdsize;
    }

    [evidence addObject:[NSString stringWithFormat:
        @"ARM64 call-site analysis: %lu caller%@, bool=%lu, integer=%lu, pointer=%lu, max x0-x%lu arguments.",
        (unsigned long)callSites, callSites == 1 ? @"" : @"s",
        (unsigned long)boolVotes,
        (unsigned long)integerVotes,
        (unsigned long)pointerVotes,
        (unsigned long)(maximumArguments ? maximumArguments - 1 : 0)]];

    NSUInteger requiredVotes = callSites >= 2 ? 2 : NSUIntegerMax;
    if (boolVotes >= requiredVotes && boolVotes >= integerVotes && boolVotes >= pointerVotes) {
        if (maximumArguments == 0) {
            *confidence = FLEXABIResolutionConfidenceStrong;
            return FLEXHookABICBoolNoArguments;
        }
        if (maximumArguments == 1 && pointerArgumentVotes >= requiredVotes) {
            *confidence = FLEXABIResolutionConfidenceStrong;
            return FLEXHookABICBoolPointerArgument;
        }
    }
    if (integerVotes >= requiredVotes && maximumArguments == 0) {
        *confidence = FLEXABIResolutionConfidenceStrong;
        return FLEXHookABICInt64NoArguments;
    }
    if (pointerVotes >= requiredVotes && maximumArguments == 0) {
        *confidence = FLEXABIResolutionConfidenceStrong;
        return FLEXHookABICPointerNoArguments;
    }
    if (callSites > 0) {
        *confidence = FLEXABIResolutionConfidenceHeuristic;
        [evidence addObject:@"The observed callers do not agree strongly enough for automatic activation."];
    }
    return FLEXHookABIUnknown;
}

@implementation FLEXABIResolver

+ (NSString *)confidenceName:(FLEXABIResolutionConfidence)confidence {
    switch (confidence) {
        case FLEXABIResolutionConfidenceExact: return @"Exact";
        case FLEXABIResolutionConfidenceStrong: return @"Strong";
        case FLEXABIResolutionConfidenceHeuristic: return @"Partial";
        case FLEXABIResolutionConfidenceUnknown: return @"Unknown";
    }
}

+ (void)resolveEntry:(FLEXHookEntry *)entry
          completion:(void (^)(FLEXABIResolution *resolution))completion {
    FLEXHookEntry *snapshot = [entry copy];
    dispatch_async(FLEXABIResolverQueue(), ^{
        FLEXABIResolution *resolution = [FLEXABIResolution new];
        resolution.abi = FLEXHookABIUnknown;
        resolution.backend = FLEXHookBackendNone;
        resolution.confidence = FLEXABIResolutionConfidenceUnknown;
        NSMutableArray<NSString *> *evidence = [NSMutableArray array];

        if (snapshot.surface == FLEXHookSurfaceObjectiveC) {
            NSString *className = snapshot.locator[@"class"];
            NSString *selectorName = snapshot.locator[@"selector"];
            BOOL classMethod = [snapshot.locator[@"classMethod"] boolValue];
            Class targetClass = NSClassFromString(className);
            SEL selector = NSSelectorFromString(selectorName);
            Method method = classMethod
                ? class_getClassMethod(targetClass, selector)
                : class_getInstanceMethod(targetClass, selector);
            resolution.symbolResolved = method != NULL;
            resolution.backend = FLEXHookBackendObjectiveCElleKit;
            resolution.abi = FLEXObjectiveCABI(method);
            if (resolution.abi != FLEXHookABIUnknown) {
                resolution.confidence = FLEXABIResolutionConfidenceExact;
                const char *encoding = method_getTypeEncoding(method);
                [evidence addObject:[NSString stringWithFormat:
                    @"Objective-C runtime encoding is authoritative: %s",
                    encoding ?: ""]];
            } else {
                [evidence addObject:@"Objective-C metadata is available, but the type encoding does not match a supported replacement profile."];
            }
        } else {
            NSUInteger bindSlots = [snapshot.locator[@"bindSlots"] unsignedIntegerValue];
            NSNumber *address = snapshot.locator[@"address"];
            if (bindSlots > 0) {
                resolution.backend = FLEXHookBackendFishhook;
                resolution.symbolResolved = YES;
                [evidence addObject:[NSString stringWithFormat:
                    @"%lu Mach-O bind slot%@ select the embedded fishhook backend.",
                    (unsigned long)bindSlots, bindSlots == 1 ? @"" : @"s"]];
            } else if ([address isKindOfClass:NSNumber.class] &&
                       address.unsignedLongLongValue) {
                resolution.backend = FLEXHookBackendInlineElleKit;
                resolution.symbolResolved = FLEXMSHookFunctionProviderAvailable();
                [evidence addObject:@"Executable function address selects the MSHookFunction backend."];
            }

            NSString *symbol = snapshot.locator[@"symbol"] ?: snapshot.title;
            NSNumber *known = FLEXKnownCSignatures()[FLEXNormalizedSymbol(symbol)];
            if (known) {
                resolution.abi = (FLEXHookABI)known.integerValue;
                resolution.confidence = FLEXABIResolutionConfidenceExact;
                [evidence addObject:@"Matched an exact public C signature in the built-in signature table."];
            } else {
                NSString *demangled = FLEXDemangleSymbol(symbol);
                if (demangled.length) {
                    [evidence addObject:[@"Demangled C++ identity: " stringByAppendingString:demangled]];
                    [evidence addObject:@"C++ mangling proves parameter identity but normally does not encode the return type; ARM64 callers are still required."];
                }
                FLEXABIResolutionConfidence callSiteConfidence =
                    FLEXABIResolutionConfidenceUnknown;
                FLEXHookABI callSiteABI = FLEXAnalyzeARM64CallSites(
                    snapshot, evidence, &callSiteConfidence);
                if (callSiteABI != FLEXHookABIUnknown) {
                    resolution.abi = callSiteABI;
                    resolution.confidence = callSiteConfidence;
                } else if (callSiteConfidence > resolution.confidence) {
                    resolution.confidence = callSiteConfidence;
                }
            }
        }

        BOOL backendAvailable = NO;
        switch (resolution.backend) {
            case FLEXHookBackendObjectiveCElleKit:
                backendAvailable = FLEXMSHookMessageProviderAvailable();
                break;
            case FLEXHookBackendFishhook:
                backendAvailable = bindSlots > 0;
                break;
            case FLEXHookBackendInlineElleKit:
                backendAvailable = FLEXMSHookFunctionProviderAvailable();
                break;
            default:
                backendAvailable = NO;
                break;
        }
        resolution.canAutoApply = resolution.abi != FLEXHookABIUnknown &&
            backendAvailable &&
            resolution.confidence >= FLEXABIResolutionConfidenceStrong;
        resolution.evidence = evidence.copy;
        resolution.summary = [NSString stringWithFormat:@"%@ · %@ · %@",
            [self confidenceName:resolution.confidence],
            FLEXHookABIName(resolution.abi),
            FLEXHookBackendName(resolution.backend)];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(resolution);
        });
    });
}

@end
