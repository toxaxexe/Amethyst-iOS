#import <UIKit/UIKit.h>

// The future combined launcher can call this coordinator before starting Java.
@interface AMBuiltInJIT : NSObject <UIDocumentPickerDelegate>
+ (instancetype)shared;
+ (NSString *)method;
- (void)showSettingsFrom:(UIViewController *)presenter;
- (void)enableFrom:(UIViewController *)presenter attached:(void (^)(void))attached;
@end
