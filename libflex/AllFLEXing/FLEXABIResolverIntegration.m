#import "FLEXABIResolver.h"

#import "FLEXCHookEngine.h"
#import "FLEXHookEntryDetailController.h"
#import "FLEXHookRegistry.h"

#import <objc/runtime.h>

static const void *kFLEXABIResolveItemKey = &kFLEXABIResolveItemKey;

static void FLEXABIExchangeInstanceMethods(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (originalMethod && replacementMethod) {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

@interface FLEXHookEntryDetailController (AllFLEXingABIPrivate)
- (void)af_abi_viewDidLoad;
- (void)af_resolveABI:(UIBarButtonItem *)sender;
- (FLEXHookEntry *)af_abi_entry;
- (void)af_applyABI:(FLEXHookABI)abi backend:(FLEXHookBackend)backend;
- (void)af_presentABIResolution:(FLEXABIResolution *)resolution
                       fromItem:(UIBarButtonItem *)item;
@end

@implementation FLEXHookEntryDetailController (AllFLEXingABIResolver)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FLEXABIExchangeInstanceMethods(
            FLEXHookEntryDetailController.class,
            @selector(viewDidLoad),
            @selector(af_abi_viewDidLoad)
        );
    });
}

- (FLEXHookEntry *)af_abi_entry {
    @try {
        return [self valueForKey:@"entry"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (void)af_abi_viewDidLoad {
    [self af_abi_viewDidLoad];
    FLEXHookEntry *entry = [self af_abi_entry];
    if (entry.surface != FLEXHookSurfaceCImport &&
        entry.surface != FLEXHookSurfaceCInline &&
        entry.surface != FLEXHookSurfaceObjectiveC) {
        return;
    }

    UIBarButtonItem *resolve = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"waveform.badge.magnifyingglass"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(af_resolveABI:)];
    resolve.accessibilityLabel = @"Resolve ABI";
    objc_setAssociatedObject(self,
                             kFLEXABIResolveItemKey,
                             resolve,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSMutableArray<UIBarButtonItem *> *items =
        [self.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    if (self.navigationItem.rightBarButtonItem && !items.count) {
        [items addObject:self.navigationItem.rightBarButtonItem];
    }
    [items addObject:resolve];
    self.navigationItem.rightBarButtonItems = items;
}

- (void)af_resolveABI:(UIBarButtonItem *)sender {
    FLEXHookEntry *entry = [self af_abi_entry];
    if (!entry) return;

    sender.enabled = NO;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    sender.customView = spinner;

    __weak typeof(self) weakSelf = self;
    [FLEXABIResolver resolveEntry:entry completion:^(FLEXABIResolution *resolution) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        sender.customView = nil;
        sender.image = [UIImage systemImageNamed:@"waveform.badge.magnifyingglass"];
        sender.enabled = YES;
        [self af_presentABIResolution:resolution fromItem:sender];
    }];
}

- (void)af_applyABI:(FLEXHookABI)abi backend:(FLEXHookBackend)backend {
    FLEXHookEntry *entry = [self af_abi_entry];
    if (!entry) return;
    [FLEXHookRegistry.sharedRegistry
        configureEntryIdentifier:entry.identifier
                              abi:abi
                          backend:backend];
    FLEXHookEntry *latest = [FLEXHookRegistry.sharedRegistry
        entryForIdentifier:entry.identifier];
    if (latest) {
        [FLEXCHookEngine refreshAvailabilityForEntry:latest];
        @try {
            [self setValue:latest forKey:@"entry"];
        } @catch (__unused NSException *exception) {
        }
    }
    [self.tableView reloadData];
}

- (void)af_presentABIResolution:(FLEXABIResolution *)resolution
                       fromItem:(UIBarButtonItem *)item {
    NSString *evidence = resolution.evidence.count
        ? [resolution.evidence componentsJoinedByString:@"\n\n"]
        : @"No reliable ABI evidence was found.";
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@",
        resolution.summary, evidence];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:@"ABI resolution"
                         message:message
                  preferredStyle:UIAlertControllerStyleActionSheet];

    if (resolution.canAutoApply) {
        [sheet addAction:[UIAlertAction
            actionWithTitle:[NSString stringWithFormat:@"Use %@ + %@",
                FLEXHookABIName(resolution.abi),
                FLEXHookBackendName(resolution.backend)]
                      style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *action) {
            [self af_applyABI:resolution.abi backend:resolution.backend];
        }]];
    }

    FLEXHookBackend suggestedBackend = resolution.backend != FLEXHookBackendNone
        ? resolution.backend : FLEXHookBackendAuto;
    NSArray<NSNumber *> *profiles = @[
        @(FLEXHookABICBoolNoArguments),
        @(FLEXHookABICBoolPointerArgument),
        @(FLEXHookABICInt64NoArguments),
        @(FLEXHookABICPointerNoArguments),
    ];
    for (NSNumber *number in profiles) {
        FLEXHookABI abi = number.integerValue;
        [sheet addAction:[UIAlertAction
            actionWithTitle:[@"Manual: " stringByAppendingString:FLEXHookABIName(abi)]
                      style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *action) {
            [self af_applyABI:abi backend:suggestedBackend];
        }]];
    }

    [sheet addAction:[UIAlertAction
        actionWithTitle:@"Keep inspection-only"
                  style:UIAlertActionStyleDestructive
                handler:^(__unused UIAlertAction *action) {
        [self af_applyABI:FLEXHookABIUnknown backend:FLEXHookBackendNone];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.barButtonItem = item;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
