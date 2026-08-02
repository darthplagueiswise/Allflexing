#import <Foundation/Foundation.h>

#import "FLEXHookRegistry.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const char *FLEXABIResolverABIVersion;

typedef NS_ENUM(NSInteger, FLEXABIResolutionConfidence) {
    FLEXABIResolutionConfidenceUnknown = 0,
    FLEXABIResolutionConfidenceHeuristic,
    FLEXABIResolutionConfidenceStrong,
    FLEXABIResolutionConfidenceExact,
};

@interface FLEXABIResolution : NSObject
@property (nonatomic) FLEXHookABI abi;
@property (nonatomic) FLEXHookBackend backend;
@property (nonatomic) FLEXABIResolutionConfidence confidence;
@property (nonatomic) BOOL symbolResolved;
@property (nonatomic) BOOL canAutoApply;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy) NSArray<NSString *> *evidence;
@end

@interface FLEXABIResolver : NSObject

/// Returns a profile only for symbols present in the explicit verified
/// signature catalog. Symbol spelling, prefixes, English words and demangled
/// names never infer an ABI.
+ (FLEXHookABI)exactKnownABIForSymbol:(NSString *)symbol;

/// Resolves backend and ABI evidence against the live selected image. Backend
/// targetability may be proven while ABI remains unknown; in that case the
/// entry stays inspection-only until an explicit manual profile is selected.
+ (void)resolveEntry:(FLEXHookEntry *)entry
          completion:(void (^)(FLEXABIResolution *resolution))completion;
+ (NSString *)confidenceName:(FLEXABIResolutionConfidence)confidence;

@end

NS_ASSUME_NONNULL_END
