#import <Foundation/Foundation.h>

#import "FLEXRuntimeBrowserController.h"
#import "FLEXHookRegistry.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const char *FLEXRuntimeImageSessionABIVersion;

@interface FLEXRuntimeImageDescriptor : NSObject <NSCopying>
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *uuid;
@property (nonatomic) uintptr_t headerAddress;
@property (nonatomic) intptr_t slide;
@property (nonatomic) BOOL mainExecutable;
@end

@interface FLEXRuntimeImageSnapshot : NSObject
@property (nonatomic) FLEXRuntimeImageDescriptor *image;
@property (nonatomic) FLEXRuntimeBrowserKind kind;
@property (nonatomic, copy) NSArray<FLEXHookEntry *> *entries;
@property (nonatomic) NSUInteger objectiveCMethodCount;
@property (nonatomic) NSUInteger importedSymbolCount;
@property (nonatomic) NSUInteger definedFunctionCount;
@property (nonatomic) NSUInteger anonymousFunctionCount;
@property (nonatomic) NSDate *completedAt;
@end

typedef void (^FLEXRuntimeImageProgress)(NSString *phase,
                                         NSUInteger completed,
                                         NSUInteger total);
typedef void (^FLEXRuntimeImageCompletion)(
    FLEXRuntimeImageSnapshot * _Nullable snapshot,
    NSError * _Nullable error
);

@interface FLEXRuntimeImageSession : NSObject

@property (class, nonatomic, readonly) NSArray<FLEXRuntimeImageDescriptor *> *loadedAppImages;
@property (nonatomic, readonly) FLEXRuntimeImageDescriptor *image;
@property (atomic, readonly, getter=isCancelled) BOOL cancelled;

- (instancetype)initWithImage:(FLEXRuntimeImageDescriptor *)image;
- (void)scanKind:(FLEXRuntimeBrowserKind)kind
        progress:(nullable FLEXRuntimeImageProgress)progress
      completion:(FLEXRuntimeImageCompletion)completion;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
