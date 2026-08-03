#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "FLEXHookPersistence.h"
#import "FLEXHookRegistry.h"
#import "FLEXHookWorkspaceController.h"
#import "FLEXHooking.h"
#import "FLEXLiquidGlass.h"
#import "FLEXManager.h"
#import "FLEXManager+Extensibility.h"
#import "FLEXPersistenceStore.h"
#import "FLEXRuntimeScanner.h"
#import "FLEXWindow.h"

const char *AllFLEXingSafeLaunchABIVersion =
    "AllFLEXing post-scene UI-only bootstrap ABI 2";
const char *AllFLEXingUserInvokedRuntimeABIVersion =
    "AllFLEXing user-invoked runtime activation ABI 1";
const char *AllFLEXingUpstreamCtorPolicyABIVersion =
    "AllFLEXing upstream FLEX automatic constructors disabled ABI 1";

static const void *kAllFLEXingRevealGestureKey = &kAllFLEXingRevealGestureKey;
static id AllFLEXingDidBecomeActiveObserver;

@interface AllFLEXingReveal : NSObject
@property (nonatomic) BOOL started;
+ (instancetype)shared;
- (void)start;
@end

@implementation AllFLEXingReveal

+ (instancetype)shared {
    static AllFLEXingReveal *reveal;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        reveal = [AllFLEXingReveal new];
    });
    return reveal;
}

- (void)start {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self start];
        });
        return;
    }
    if (self.started) {
        [self attachToCurrentWindows];
        return;
    }

    self.started = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(windowBecameKey:)
                   name:UIWindowDidBecomeKeyNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(sceneActivated:)
                   name:UISceneDidActivateNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(applicationFinishedLaunching:)
                   name:UIApplicationDidFinishLaunchingNotification
                 object:nil];
    [self attachToCurrentWindows];
}

- (void)applicationFinishedLaunching:(NSNotification *)notification {
    (void)notification;
    [self attachToCurrentWindows];
}

- (void)sceneActivated:(NSNotification *)notification {
    UIScene *scene = notification.object;
    if ([scene isKindOfClass:UIWindowScene.class]) {
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [self attachToWindow:window];
        }
    }
}

- (void)windowBecameKey:(NSNotification *)notification {
    UIWindow *window = notification.object;
    if ([window isKindOfClass:UIWindow.class]) {
        [self attachToWindow:window];
    }
}

- (void)attachToCurrentWindows {
    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [self attachToWindow:window];
        }
    }
}

- (void)attachToWindow:(UIWindow *)window {
    if (!window || objc_getAssociatedObject(window, kAllFLEXingRevealGestureKey)) {
        return;
    }

    NSString *className = NSStringFromClass(window.class);
    if ([className hasPrefix:@"FLEX"] || window.windowLevel != UIWindowLevelNormal) {
        return;
    }

    UILongPressGestureRecognizer *gesture =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handle:)];
    gesture.minimumPressDuration = 0.55;
    gesture.numberOfTouchesRequired = 3;
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;
    [window addGestureRecognizer:gesture];
    objc_setAssociatedObject(
        window,
        kAllFLEXingRevealGestureKey,
        gesture,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
}

- (void)handle:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan ||
        !FLEXFlag(@"reveal.three_finger")) {
        return;
    }

    FLEXManager *manager = FLEXManager.sharedManager;
    UIWindowScene *scene = gesture.view.window.windowScene;
    if (scene) {
        [manager showExplorerFromScene:scene];
    } else {
        [manager showExplorer];
    }
}

@end

// Compatibility exports retained from the former libFLEX target.
__attribute__((visibility("default"))) id FLXGetManager(void) {
    return FLEXManager.sharedManager;
}

__attribute__((visibility("default"))) SEL FLXRevealSEL(void) {
    return @selector(showExplorer);
}

__attribute__((visibility("default"))) Class FLXWindowClass(void) {
    return FLEXWindow.class;
}

static BOOL AllFLEXingIsUIApplicationProcess(void) {
    if ([NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"appex"]) {
        return NO;
    }
    return NSClassFromString(@"UIApplication") != nil;
}

static dispatch_queue_t AllFLEXingRuntimeActivationQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL,
            QOS_CLASS_USER_INITIATED,
            0
        );
        queue = dispatch_queue_create(
            "com.allflexing.user-invoked-runtime-activation",
            attributes
        );
    });
    return queue;
}

static FLEXHookPersistence *AllFLEXingRegisterRuntimeFlags(void) {
    FLEXHookPersistence *flags = FLEXHookPersistence.sharedManager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [flags registerFlag:@"glass.enabled"
                      title:@"Liquid Glass UI"
                     detail:@"Use native UIKit 26 glass for FLEX navigation and controls."
               defaultValue:YES];
        [flags registerFlag:@"reveal.three_finger"
                      title:@"Three-finger reveal"
                     detail:@"Open FLEX with a 0.55 second three-finger long press."
               defaultValue:YES];
        [flags registerFlag:@"engine.objc_ellekit"
                      title:@"Objective-C / ElleKit"
                     detail:@"Allow ABI-validated runtime methods through MSHookMessageEx."
               defaultValue:YES];
        [flags registerFlag:@"engine.fishhook"
                      title:@"C imports / fishhook"
                     detail:@"Allow rebinding only when a Mach-O import slot is confirmed."
               defaultValue:YES];
        [flags registerFlag:@"engine.inline_ellekit"
                      title:@"C inline / ElleKit"
                     detail:@"Allow MSHookFunction only for an explicit C ABI and resolved address."
               defaultValue:YES];
    });
    return flags;
}

static void AllFLEXingActivateRuntimeForWorkspace(dispatch_block_t completion) {
    dispatch_async(AllFLEXingRuntimeActivationQueue(), ^{
        static BOOL activated = NO;
        if (!activated) {
            @autoreleasepool {
                // This is the first point where persistence, scanner and hook
                // replay are allowed to initialize. Merely injecting/loading
                // the dylib never touches the host defaults database or starts
                // runtime-image monitoring.
                (void)FLEXPersistenceStore.sharedStore;

                FLEXHookPersistence *flags = AllFLEXingRegisterRuntimeFlags();
                [flags reloadPersistedValues];
                [flags activateRegisteredHooks];

                FLEXHookRegistry *registry = FLEXHookRegistry.sharedRegistry;
                [FLEXRuntimeScanner startMonitoringImages];
                [registry reapplyPersistedEntries];
                activated = YES;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion();
            }
        });
    });
}

static void AllFLEXingStartUI(void) {
    NSCAssert(NSThread.isMainThread, @"FLEX UI bootstrap must run on the main thread");
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Flag registration only reads the host defaults domain. It neither
        // creates the persistence store nor writes/synchronizes a value.
        (void)AllFLEXingRegisterRuntimeFlags();

        [FLEXManager.sharedManager
            registerGlobalEntryWithName:@"AllFLEXing Runtime Workspace"
            action:^(__kindof UITableViewController *host) {
                __weak UITableViewController *weakHost = host;
                AllFLEXingActivateRuntimeForWorkspace(^{
                    UITableViewController *strongHost = weakHost;
                    if (!strongHost) {
                        return;
                    }
                    FLEXHookWorkspaceController *workspace =
                        [FLEXHookWorkspaceController new];
                    [strongHost presentViewController:workspace
                                             animated:YES
                                           completion:nil];
                });
            }];
        [AllFLEXingReveal.shared start];
        [FLEXLiquidGlass refreshVisibleFLEXViewControllers];

        NSLog(@"[AllFLEXing] UI initialized in %@; runtime activation begins only after the workspace is opened",
            NSBundle.mainBundle.bundleIdentifier ?: NSProcessInfo.processInfo.processName);
    });
}

static void AllFLEXingRunActivationPhase(void) {
    NSCAssert(NSThread.isMainThread, @"activation phase must run on the main thread");
    AllFLEXingStartUI();
}

static void AllFLEXingScheduleActivationPhase(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *application = UIApplication.sharedApplication;
        if (application.applicationState == UIApplicationStateActive) {
            AllFLEXingRunActivationPhase();
            return;
        }

        if (AllFLEXingDidBecomeActiveObserver) {
            return;
        }
        AllFLEXingDidBecomeActiveObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
            id observer = AllFLEXingDidBecomeActiveObserver;
            AllFLEXingDidBecomeActiveObserver = nil;
            if (observer) {
                [NSNotificationCenter.defaultCenter removeObserver:observer];
            }
            AllFLEXingRunActivationPhase();
        }];
    });
}

__attribute__((constructor))
static void AllFLEXingBootstrap(void) {
    @autoreleasepool {
        if (!AllFLEXingIsUIApplicationProcess()) {
            return;
        }

        // The constructor only schedules UI attachment after the active scene.
        // Persistence, scanner startup and hook replay require an explicit tap
        // on the Runtime Workspace entry.
        AllFLEXingScheduleActivationPhase();
    }
}
