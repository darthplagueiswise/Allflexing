#import "FLEXABIResolver.h"

#import "FLEXHooking.h"

#import <cxxabi.h>
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

static const char *FLEXSkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') type++;
    return type;
}

static FLEXHookABI FLEXObjectiveCABI(Method method) {
    if (!method) return FLEXHookABIUnknown;
    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (*FLEXSkipQualifiers(returnType) != 'B') return FLEXHookABIUnknown;

    unsigned int count = method_getNumberOfArguments(method);
    if (count == 2) return FLEXHookABIObjCBoolNoArguments;
    if (count != 3) return FLEXHookABIUnknown;

    char argumentType[64] = {0};
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *code = FLEXSkipQualifiers(argumentType);
    if (*code == '@' || *code == '#' || *code == ':') {
        return FLEXHookABIObjCBoolObjectArgument;
    }
    return strchr("BcCsSiIlLqQ", *code)
        ? FLEXHookABIObjCBoolIntegerArgument
        : FLEXHookABIUnknown;
}

static NSString *FLEXNormalizedSymbol(NSString *symbol) {
    return [symbol hasPrefix:@"_"] ? [symbol substringFromIndex:1] : symbol;
}

static NSDictionary<NSString *, NSNumber *> *FLEXExactCSignatures(void) {
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

static NSString *FLEXDemangledIdentity(NSString *symbol) {
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

static BOOL FLEXFindLoadedImage(NSString *path,
                                const struct mach_header_64 **header,
                                intptr_t *slide) {
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *rawPath = _dyld_get_image_name(index);
        const struct mach_header *candidate = _dyld_get_image_header(index);
        if (!rawPath || !candidate || candidate->magic != MH_MAGIC_64) continue;
        if (![[NSString stringWithUTF8String:rawPath] isEqualToString:path]) continue;
        if (header) *header = (const struct mach_header_64 *)candidate;
        if (slide) *slide = _dyld_get_image_vmaddr_slide(index);
        return YES;
    }
    return NO;
}

static int64_t FLEXSignExtend(uint64_t value, unsigned bits) {
    uint64_t mask = 1ULL << (bits - 1);
    return (int64_t)((value ^ mask) - mask);
}

static BOOL FLEXBLTarget(uint32_t instruction, uintptr_t pc, uintptr_t *target) {
    if ((instruction & 0xFC000000u) != 0x94000000u) return NO;
    int64_t displacement = FLEXSignExtend(instruction & 0x03FFFFFFu, 26) << 2;
    if (target) *target = (uintptr_t)((int64_t)pc + displacement);
    return YES;
}

static BOOL FLEXInstructionWritesArgumentRegister(uint32_t instruction,
                                                  unsigned *reg,
                                                  BOOL *pointerLike) {
    unsigned destination = instruction & 0x1f;
    if (destination > 7) return NO;
    BOOL writes = NO;
    BOOL pointer = NO;

    if ((instruction & 0x1F000000u) == 0x10000000u) {
        writes = YES;
        pointer = YES; // ADR/ADRP
    } else if ((instruction & 0x1F800000u) == 0x12800000u ||
               (instruction & 0x1F000000u) == 0x11000000u ||
               (instruction & 0x1F000000u) == 0x0A000000u ||
               (instruction & 0x1F000000u) == 0x0B000000u ||
               (instruction & 0x1FE00000u) == 0x1A800000u) {
        writes = YES;
    } else if ((instruction & 0x3B000000u) == 0x18000000u) {
        writes = YES;
        pointer = (instruction & 0x40000000u) != 0;
    } else if ((instruction & 0x3B000000u) == 0x39000000u &&
               (instruction & (1u << 22))) {
        writes = YES;
        pointer = ((instruction >> 30) & 0x3) == 0x3;
    }

    if (!writes) return NO;
    if (reg) *reg = destination;
    if (pointerLike) *pointerLike = pointer;
    return YES;
}

static void FLEXVoteForReturnUse(uint32_t instruction,
                                 NSUInteger *boolVotes,
                                 NSUInteger *integerVotes,
                                 NSUInteger *pointerVotes) {
    unsigned rt = instruction & 0x1f;
    if (rt != 0) return;
    if ((instruction & 0x7E000000u) == 0x34000000u) {
        ((instruction & 0x80000000u) ? pointerVotes : boolVotes)[0]++;
    } else if ((instruction & 0x7E000000u) == 0x36000000u) {
        (*boolVotes)++;
    } else if ((instruction & 0x7F00001Fu) == 0x7100001Fu &&
               ((instruction >> 5) & 0x1f) == 0) {
        (*integerVotes)++;
    } else if ((instruction & 0x3B000000u) == 0x39000000u &&
               (instruction & (1u << 22)) &&
               ((instruction >> 5) & 0x1f) == 0) {
        (*pointerVotes)++;
    }
}

/// Return-register CLASS from the callee's own body: does it produce its result
/// in d0/s0 (floating-point) or via x8 indirect (struct-by-value)? Reads forward
/// from the entry address to the first `ret`, bounded, and only looks at whether
/// the LAST writer of the return path is an FP register or a store through x8.
/// This is what tells double/float apart from a general GP (x0) return, which is
/// exactly the distinction the call-site vote cannot make.
typedef NS_ENUM(NSUInteger, FLEXReturnRegisterClass) {
    FLEXReturnRegisterClassGP = 0,   // x0 - bool/int/pointer
    FLEXReturnRegisterClassDouble,   // d0
    FLEXReturnRegisterClassFloat,    // s0
    FLEXReturnRegisterClassIndirect, // x8 sret - struct by value, not forceable
};

static FLEXReturnRegisterClass FLEXReturnClassForFunction(
    const uint32_t *instructions,
    NSUInteger count,
    NSUInteger entryIndex,
    BOOL *sawReturn
) {
    if (sawReturn) *sawReturn = NO;
    BOOL lastWasDouble = NO, lastWasFloat = NO, usesX8 = NO;
    NSUInteger limit = MIN(count, entryIndex + 512); // bounded scan
    for (NSUInteger i = entryIndex; i < limit; i++) {
        uint32_t inst = instructions[i];

        // RET (0xD65F0000 mask). The class is decided by what last touched the
        // return path before this point.
        if ((inst & 0xFFFFFC1Fu) == 0xD65F0000u) {
            if (sawReturn) *sawReturn = YES;
            if (usesX8) return FLEXReturnRegisterClassIndirect;
            if (lastWasDouble) return FLEXReturnRegisterClassDouble;
            if (lastWasFloat) return FLEXReturnRegisterClassFloat;
            return FLEXReturnRegisterClassGP;
        }

        // Any write to x8 as a destination pointer (struct sret) - ADRP/ADD/MOV
        // into x8, or a store through it. Rd == 8.
        unsigned rd = inst & 0x1f;
        if (rd == 8) {
            // ADR/ADRP x8, ADD x8, MOV x8, ... treat as sret setup.
            if ((inst & 0x1F000000u) == 0x10000000u ||   // ADR/ADRP
                (inst & 0x7F800000u) == 0x11000000u ||    // ADD imm
                (inst & 0x7FE00000u) == 0x2A0003E0u) {    // MOV (ORR) into x8
                usesX8 = YES;
            }
        }

        // FMOV/FP producers writing d0/s0 (Rd == 0 in the FP register file).
        // FMOV (register) 000: 0x1E604000 (double), 0x1E204000 (single).
        // Also catch scalar FP ops and loads that land in d0/s0.
        unsigned fpRd = inst & 0x1f;
        if (fpRd == 0) {
            uint32_t top = inst & 0xFF200000u;
            // Double-precision scalar FP data-processing / fmov: ...01 11100 1x
            if ((inst & 0xFF200000u) == 0x1E600000u) { lastWasDouble = YES; lastWasFloat = NO; }
            // Single-precision scalar FP: ...00 11100 0x
            else if ((inst & 0xFF200000u) == 0x1E200000u) { lastWasFloat = YES; lastWasDouble = NO; }
            // LDR d0 (64-bit FP load): 1111 1101 01 ... -> 0xFD400000
            else if ((inst & 0xFFC00000u) == 0xFD400000u) { lastWasDouble = YES; lastWasFloat = NO; }
            // LDR s0 (32-bit FP load): 1011 1101 01 ... -> 0xBD400000
            else if ((inst & 0xFFC00000u) == 0xBD400000u) { lastWasFloat = YES; lastWasDouble = NO; }
            (void)top;
        }
        // A GP write to x0 after an FP write clears the FP hypothesis: the value
        // being returned is the GP one.
        if ((inst & 0x1f) == 0) {
            BOOL isGPWrite =
                (inst & 0x1F800000u) == 0x12800000u ||   // MOVZ/MOVN
                (inst & 0x1F000000u) == 0x11000000u ||    // ADD/SUB imm
                (inst & 0x7FE00000u) == 0x2A0003E0u ||    // MOV (ORR)
                (inst & 0xBFC00000u) == 0xB9400000u;      // LDR w0/x0
            if (isGPWrite) { lastWasDouble = NO; lastWasFloat = NO; }
        }
    }
    return FLEXReturnRegisterClassGP; // no ret seen within budget: assume GP
}

static FLEXHookABI FLEXInferCABIFromCallSites(
    FLEXHookEntry *entry,
    NSMutableArray<NSString *> *evidence,
    FLEXABIResolutionConfidence *confidence
) {
    const struct mach_header_64 *header = NULL;
    intptr_t slide = 0;
    if (!FLEXFindLoadedImage(entry.locator[@"image"], &header, &slide)) {
        [evidence addObject:@"The selected image is no longer loaded."];
        return FLEXHookABIUnknown;
    }

    NSMutableSet<NSNumber *> *targets = [NSMutableSet set];
    NSNumber *address = entry.locator[@"address"];
    if ([address isKindOfClass:NSNumber.class] && address.unsignedLongLongValue) {
        [targets addObject:address];
    }
    for (NSNumber *stub in entry.locator[@"stubAddresses"] ?: @[]) {
        if ([stub isKindOfClass:NSNumber.class] && stub.unsignedLongLongValue) {
            [targets addObject:stub];
        }
    }
    if (!targets.count) {
        [evidence addObject:@"No executable address or call stub is recorded."];
        return FLEXHookABIUnknown;
    }

    NSUInteger calls = 0, boolVotes = 0, integerVotes = 0, pointerVotes = 0;
    NSUInteger maxArguments = 0, pointerArgumentVotes = 0;

    // First, read the callee's own return-register class. This is the only
    // signal that distinguishes a double/float return (d0/s0) from a general GP
    // return, and it also rejects struct-by-value (x8 sret) targets, which are
    // not forceable. Requires the function's own address.
    FLEXReturnRegisterClass returnClass = FLEXReturnRegisterClassGP;
    BOOL returnClassKnown = NO;
    NSNumber *fnAddress = entry.locator[@"address"];
    if ([fnAddress isKindOfClass:NSNumber.class] && fnAddress.unsignedLongLongValue) {
        // Find the executable segment that contains the function address, then
        // scan forward from it for the return-register class.
        const uint8_t *scan = (const uint8_t *)(header + 1);
        for (uint32_t ci = 0; ci < header->ncmds; ci++) {
            const struct load_command *cmd = (const struct load_command *)scan;
            if (cmd->cmdsize < sizeof(struct load_command)) break;
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg =
                    (const struct segment_command_64 *)cmd;
                if ((seg->initprot & VM_PROT_EXECUTE) && seg->vmsize) {
                    uintptr_t segStart = (uintptr_t)(seg->vmaddr + slide);
                    uintptr_t segEnd = segStart + (uintptr_t)seg->vmsize;
                    uintptr_t fn = (uintptr_t)fnAddress.unsignedLongLongValue;
                    if (fn >= segStart && fn < segEnd) {
                        const uint32_t *segInsts = (const uint32_t *)segStart;
                        NSUInteger segCount =
                            (NSUInteger)(seg->vmsize / sizeof(uint32_t));
                        NSUInteger fnIndex =
                            (NSUInteger)((fn - segStart) / sizeof(uint32_t));
                        BOOL sawReturn = NO;
                        returnClass = FLEXReturnClassForFunction(
                            segInsts, segCount, fnIndex, &sawReturn);
                        returnClassKnown = sawReturn;
                        break;
                    }
                }
            }
            scan += cmd->cmdsize;
        }
    }

    if (returnClassKnown) {
        if (returnClass == FLEXReturnRegisterClassIndirect) {
            [evidence addObject:
                @"Callee returns a struct by value (x8 indirect); not forceable."];
            *confidence = FLEXABIResolutionConfidenceStrong;
            return FLEXHookABIUnknown;
        }
        if (returnClass == FLEXReturnRegisterClassDouble) {
            [evidence addObject:
                @"Callee return path writes d0: double(void) floating-point return."];
            *confidence = FLEXABIResolutionConfidenceStrong;
            return FLEXHookABICDoubleNoArguments;
        }
        if (returnClass == FLEXReturnRegisterClassFloat) {
            [evidence addObject:
                @"Callee return path writes s0: float(void) floating-point return."];
            *confidence = FLEXABIResolutionConfidenceStrong;
            return FLEXHookABICFloatNoArguments;
        }
    }

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t commandIndex = 0; commandIndex < header->ncmds; commandIndex++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(struct load_command)) break;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if ((segment->initprot & VM_PROT_EXECUTE) && segment->vmsize) {
                uintptr_t start = (uintptr_t)(segment->vmaddr + slide);
                NSUInteger count = (NSUInteger)(segment->vmsize / sizeof(uint32_t));
                const uint32_t *instructions = (const uint32_t *)start;
                for (NSUInteger index = 0; index < count; index++) {
                    uintptr_t target = 0;
                    uintptr_t pc = start + index * sizeof(uint32_t);
                    if (!FLEXBLTarget(instructions[index], pc, &target) ||
                        ![targets containsObject:@(target)]) continue;
                    calls++;
                    BOOL sawArgument = NO;
                    unsigned highest = 0;
                    BOOL x0Pointer = NO;
                    NSUInteger beginning = index > 8 ? index - 8 : 0;
                    for (NSUInteger previous = beginning; previous < index; previous++) {
                        unsigned reg = 0;
                        BOOL pointerLike = NO;
                        if (FLEXInstructionWritesArgumentRegister(
                                instructions[previous], &reg, &pointerLike)) {
                            sawArgument = YES;
                            highest = MAX(highest, reg);
                            if (reg == 0 && pointerLike) x0Pointer = YES;
                        }
                    }
                    if (sawArgument) maxArguments = MAX(maxArguments, highest + 1);
                    if (x0Pointer) pointerArgumentVotes++;
                    for (NSUInteger after = 1; after <= 4 && index + after < count; after++) {
                        FLEXVoteForReturnUse(instructions[index + after],
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
        @"ARM64 callers=%lu, bool=%lu, integer=%lu, pointer=%lu, observed argument registers=%lu.",
        (unsigned long)calls,
        (unsigned long)boolVotes,
        (unsigned long)integerVotes,
        (unsigned long)pointerVotes,
        (unsigned long)maxArguments]];

    if (calls < 2) {
        if (calls) *confidence = FLEXABIResolutionConfidenceHeuristic;
        return FLEXHookABIUnknown;
    }
    if (boolVotes >= 2 && boolVotes >= integerVotes && boolVotes >= pointerVotes) {
        if (maxArguments == 0) {
            *confidence = FLEXABIResolutionConfidenceStrong;
            return FLEXHookABICBoolNoArguments;
        }
        if (maxArguments == 1 && pointerArgumentVotes >= 2) {
            *confidence = FLEXABIResolutionConfidenceStrong;
            return FLEXHookABICBoolPointerArgument;
        }
    }
    if (integerVotes >= 2 && maxArguments == 0) {
        *confidence = FLEXABIResolutionConfidenceStrong;
        return FLEXHookABICInt64NoArguments;
    }
    if (pointerVotes >= 2 && maxArguments == 0) {
        *confidence = FLEXABIResolutionConfidenceStrong;
        return FLEXHookABICPointerNoArguments;
    }
    *confidence = FLEXABIResolutionConfidenceHeuristic;
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
        FLEXABIResolution *result = [FLEXABIResolution new];
        result.abi = FLEXHookABIUnknown;
        result.backend = FLEXHookBackendNone;
        result.confidence = FLEXABIResolutionConfidenceUnknown;
        NSMutableArray<NSString *> *evidence = [NSMutableArray array];
        NSUInteger bindSlots = [snapshot.locator[@"bindSlots"] unsignedIntegerValue];

        if (snapshot.surface == FLEXHookSurfaceObjectiveC) {
            Class cls = NSClassFromString(snapshot.locator[@"class"]);
            SEL selector = NSSelectorFromString(snapshot.locator[@"selector"]);
            BOOL classMethod = [snapshot.locator[@"classMethod"] boolValue];
            Method method = classMethod
                ? class_getClassMethod(cls, selector)
                : class_getInstanceMethod(cls, selector);
            result.symbolResolved = method != NULL;
            result.backend = FLEXHookBackendObjectiveCElleKit;
            result.abi = FLEXObjectiveCABI(method);
            if (result.abi != FLEXHookABIUnknown) {
                result.confidence = FLEXABIResolutionConfidenceExact;
                [evidence addObject:[NSString stringWithFormat:
                    @"Objective-C runtime encoding: %s",
                    method_getTypeEncoding(method) ?: ""]];
            } else {
                [evidence addObject:@"The Objective-C encoding is real, but no supported replacement profile matches it."];
            }
        } else {
            NSNumber *address = snapshot.locator[@"address"];
            if (bindSlots > 0) {
                result.backend = FLEXHookBackendFishhook;
                result.symbolResolved = YES;
                [evidence addObject:[NSString stringWithFormat:
                    @"%lu confirmed Mach-O bind slot%@ select fishhook.",
                    (unsigned long)bindSlots, bindSlots == 1 ? @"" : @"s"]];
            } else if ([address isKindOfClass:NSNumber.class] &&
                       address.unsignedLongLongValue) {
                result.backend = FLEXHookBackendInlineElleKit;
                result.symbolResolved = FLEXMSHookFunctionProviderAvailable();
                [evidence addObject:@"A loaded executable address selects MSHookFunction."];
            }

            NSString *symbol = snapshot.locator[@"symbol"] ?: snapshot.title;
            NSNumber *known = FLEXExactCSignatures()[FLEXNormalizedSymbol(symbol)];
            if (known) {
                result.abi = (FLEXHookABI)known.integerValue;
                result.confidence = FLEXABIResolutionConfidenceExact;
                [evidence addObject:@"Matched an exact public C signature."];
            } else {
                NSString *demangled = FLEXDemangledIdentity(symbol);
                if (demangled.length) {
                    [evidence addObject:[@"Demangled identity: " stringByAppendingString:demangled]];
                    [evidence addObject:@"Return type still requires caller evidence."];
                }
                FLEXABIResolutionConfidence confidence =
                    FLEXABIResolutionConfidenceUnknown;
                result.abi = FLEXInferCABIFromCallSites(snapshot, evidence, &confidence);
                result.confidence = confidence;
            }
        }

        BOOL backendAvailable = NO;
        if (result.backend == FLEXHookBackendObjectiveCElleKit) {
            backendAvailable = FLEXMSHookMessageProviderAvailable();
        } else if (result.backend == FLEXHookBackendFishhook) {
            backendAvailable = bindSlots > 0;
        } else if (result.backend == FLEXHookBackendInlineElleKit) {
            backendAvailable = FLEXMSHookFunctionProviderAvailable();
        }
        result.canAutoApply = result.abi != FLEXHookABIUnknown &&
            backendAvailable &&
            result.confidence >= FLEXABIResolutionConfidenceStrong;
        result.evidence = evidence.copy;
        result.summary = [NSString stringWithFormat:@"%@ - %@ - %@",
            [self confidenceName:result.confidence],
            FLEXHookABIName(result.abi),
            FLEXHookBackendName(result.backend)];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(result);
        });
    });
}

@end
