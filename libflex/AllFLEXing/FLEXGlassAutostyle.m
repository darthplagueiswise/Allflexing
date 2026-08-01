#import "FLEXGlassAutostyle.h"

#import "FLEXHooking.h"
#import "FLEXHookPersistence.h"
#import "FLEXLiquidGlass.h"
#import <UIKit/UIKit.h>

static void (*FLEXOriginalViewDidAppear)(UIViewController *, SEL, BOOL);
static void (*FLEXOriginalViewWillAppear)(UIViewController *, SEL, BOOL);

static BOOL FLEXIsOverlayViewController(UIViewController *controller) {
    NSString *className = NSStringFromClass(controller.class);
    return [className hasPrefix:@"FLEX"] ||
           [className hasPrefix:@"FHS"] ||
           [className hasPrefix:@"AllFLEXing"];
}

static void FLEXReplacementViewDidAppear(UIViewController *controller,
                                         SEL selector,
                                         BOOL animated) {
    if (FLEXOriginalViewDidAppear) {
        FLEXOriginalViewDidAppear(controller, selector, animated);
    }

    if (FLEXFlag(@"hook.log_view_controllers")) {
        NSLog(@"[AllFLEXing] viewDidAppear: %@", NSStringFromClass(controller.class));
    }

    if (FLEXFlag(@"hook.flex_ui_autostyle") && FLEXIsOverlayViewController(controller)) {
        [FLEXLiquidGlass applyToViewController:controller];
        __weak UIViewController *weakController = controller;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *strongController = weakController;
            [strongController.view layoutIfNeeded];
            [FLEXLiquidGlass applyToViewController:strongController];
        });
    }
}

static void FLEXReplacementViewWillAppear(UIViewController *controller,
                                          SEL selector,
                                          BOOL animated) {
    if (FLEXOriginalViewWillAppear) {
        FLEXOriginalViewWillAppear(controller, selector, animated);
    }
    if (FLEXFlag(@"hook.flex_ui_autostyle") && FLEXIsOverlayViewController(controller)) {
        [FLEXLiquidGlass applyToViewController:controller];
    }
}

BOOL FLEXGlassAutostyleInstall(void) {
    static dispatch_once_t onceToken;
    static BOOL installed;
    static id flagsObserver;
    dispatch_once(&onceToken, ^{
        BOOL earlyInstalled = FLEXHookMessage(
            UIViewController.class,
            @selector(viewWillAppear:),
            (IMP)FLEXReplacementViewWillAppear,
            (IMP *)&FLEXOriginalViewWillAppear
        );
        BOOL reconciliationInstalled = FLEXHookMessage(
            UIViewController.class,
            @selector(viewDidAppear:),
            (IMP)FLEXReplacementViewDidAppear,
            (IMP *)&FLEXOriginalViewDidAppear
        );
        installed = earlyInstalled && reconciliationInstalled;

        flagsObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:FLEXHookFlagsDidChangeNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
                        [FLEXLiquidGlass refreshVisibleFLEXViewControllers];
                    }];
        (void)flagsObserver;
    });
    return installed;
}
