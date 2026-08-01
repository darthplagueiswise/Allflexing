#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "FLEXGlassAutostyle.h"
#import "FLEXHookPersistence.h"
#import "FLEXHookToggles.h"
#import "FLEXHooking.h"
#import "FLEXLiquidGlass.h"
#import "FLEXManager.h"
#import "FLEXManager+Extensibility.h"
#import "FLEXWindow.h"

static const void *kAllFLEXingRevealGestureKey = &kAllFLEXingRevealGestureKey;

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

static void AllFLEXingRegisterRuntime(void) {
    FLEXHookPersistence *flags = FLEXHookPersistence.sharedManager;
    [flags registerFlag:@"glass.enabled"
                  title:@"Liquid Glass UI"
                 detail:@"Use native UIKit 26 glass for FLEX navigation and controls."
           defaultValue:YES];
    [flags registerFlag:@"reveal.three_finger"
                  title:@"Three-finger reveal"
                 detail:@"Open FLEX with a 0.55 second three-finger long press."
           defaultValue:YES];
    [flags registerFlag:@"hook.log_view_controllers"
                  title:@"Log view controllers"
                 detail:@"Diagnostic logging for every viewDidAppear: callback."
           defaultValue:NO];
    [flags registerInstallOnce:@"hook.flex_ui_autostyle"
                         title:@"Auto-style FLEX screens"
                        detail:@"Install one lifecycle hook and gate FLEX-only styling live."
                  defaultValue:YES
                         block:^{
        if (!FLEXGlassAutostyleInstall()) {
            NSLog(@"[AllFLEXing] failed to install FLEX UI lifecycle hook");
        }
    }];
    [flags activateRegisteredHooks];
}

static void AllFLEXingStartUI(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [FLEXManager.sharedManager
            registerGlobalEntryWithName:@"Hook Toggles"
            viewControllerFutureBlock:^UIViewController *{
                return [FLEXHookToggles new];
            }];
        [AllFLEXingReveal.shared start];
        [FLEXLiquidGlass refreshVisibleFLEXViewControllers];

        NSLog(@"[AllFLEXing] initialized in %@ using %@",
            NSBundle.mainBundle.bundleIdentifier ?: NSProcessInfo.processInfo.processName,
            FLEXMessageHookBackend());
    });
}

__attribute__((constructor))
static void AllFLEXingBootstrap(void) {
    @autoreleasepool {
        if (!AllFLEXingIsUIApplicationProcess()) {
            return;
        }

        // Method and symbol hooks are registered synchronously at image load so
        // early app calls cannot win a race with the first main-runloop turn.
        AllFLEXingRegisterRuntime();
        dispatch_async(dispatch_get_main_queue(), ^{
            AllFLEXingStartUI();
        });
    }
}
