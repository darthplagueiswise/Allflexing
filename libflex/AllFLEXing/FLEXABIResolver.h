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
+ (void)resolveEntry:(FLEXHookEntry *)entry
          completion:(void (^)(FLEXABIResolution *resolution))completion;
+ (NSString *)confidenceName:(FLEXABIResolutionConfidence)confidence;
@end

NS_ASSUME_NONNULL_END
