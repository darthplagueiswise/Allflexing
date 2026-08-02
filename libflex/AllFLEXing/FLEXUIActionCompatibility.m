#import "FLEXRuntimeBrowserController.h"

@implementation UIAction (AllFLEXingSubtitleCompatibility)

+ (instancetype)actionWithTitle:(NSString *)title
                       subtitle:(NSString *)subtitle
                          image:(UIImage *)image
                     identifier:(UIActionIdentifier)identifier
                        handler:(UIActionHandler)handler {
    UIAction *action = [self actionWithTitle:title
                                       image:image
                                  identifier:identifier
                                     handler:handler];
    SEL setter = NSSelectorFromString(@"setSubtitle:");
    if (subtitle.length && [action respondsToSelector:setter]) {
        [action setValue:subtitle forKey:@"subtitle"];
    }
    return action;
}

@end
