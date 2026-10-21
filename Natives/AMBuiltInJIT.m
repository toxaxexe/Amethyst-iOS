#import "AMBuiltInJIT.h"
#import "utils.h"
#import "LauncherPreferences.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import <unistd.h>

// Private extension APIs: this build is for sideloading on a physical device.
@interface NSObject (AMJITExtensionSPI)
+ (id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)setRequestCompletionBlock:(void (^)(NSUUID *, NSArray *))block;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *, NSError *))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *))block;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))completion;
- (void)cancelExtensionRequestWithIdentifier:(NSUUID *)identifier;
@end

@interface AMBuiltInJIT ()
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic) id helper;
@property(nonatomic) NSUUID *requestID;
@property(nonatomic) NSTimer *timer;
@property(nonatomic) UIAlertController *waiting;
@property(nonatomic, copy) void (^onAttached)(void);
@property(nonatomic) BOOL attached;
@property(nonatomic) NSDate *deadline;
@end

@implementation AMBuiltInJIT
+ (instancetype)shared { static AMBuiltInJIT *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [self new]; }); return s; }
+ (NSString *)method { return [NSUserDefaults.standardUserDefaults stringForKey:@"AMJITMethod"] ?: @"builtin"; }
- (NSURL *)pairingURL {
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [[docs URLByAppendingPathComponent:@"StikJIT"] URLByAppendingPathComponent:@"pairingFile.plist"];
}
- (void)message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"JIT" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"ОК" style:UIAlertActionStyleDefault handler:nil]];
    [self.presenter presentViewController:alert animated:YES completion:nil];
}
- (void)showSettingsFrom:(UIViewController *)presenter {
    self.presenter = presenter;
    NSString *status = [NSFileManager.defaultManager fileExistsAtPath:self.pairingURL.path] ? @"Файл сопряжения импортирован." : @"Сначала импортируй файл сопряжения.";
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"JIT для Minecraft 1.19.1" message:[status stringByAppendingString:@"\nНужны режим разработчика, get-task-allow и подключённый LocalDevVPN. Встроенный JIT заменяет StikDebug. Это экспериментальная сборка."] preferredStyle:UIAlertControllerStyleAlert];
    NSArray *keys = @[@"builtin", @"external", @"wait"];
    NSArray *names = @[@"Встроенный StikJIT", @"Открывать StikDebug", @"Ждать внешний отладчик"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *key = keys[i];
        NSString *title = [[AMBuiltInJIT method] isEqual:key] ? [@"✓ " stringByAppendingString:names[i]] : names[i];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [NSUserDefaults.standardUserDefaults setObject:key forKey:@"AMJITMethod"]; }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Импортировать файл сопряжения" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
        picker.delegate = self;
        [presenter presentViewController:picker animated:YES completion:nil];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Проверить и подготовить JIT" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self request:@"prepare" attached:nil]; }]];
    BOOL force = [NSUserDefaults.standardUserDefaults boolForKey:@"AMJITForceScript"];
    [menu addAction:[UIAlertAction actionWithTitle:force ? @"✓ Принудительный скрипт: включён" : @"Принудительный скрипт: выключен" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [NSUserDefaults.standardUserDefaults setBool:!force forKey:@"AMJITForceScript"];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Очистить кэш DDI" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self request:@"reset" attached:nil]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Закрыть" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:menu animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *error;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (scoped) [url stopAccessingSecurityScopedResource];
    id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:&error] : nil;
    if (![plist isKindOfClass:NSDictionary.class] || !plist[@"HostID"] || !plist[@"SystemBUID"] || !plist[@"HostPrivateKey"]) {
        [self message:@"Это не файл сопряжения iPhone. Нужен pairing plist от iLoader/idevice_pair."]; return;
    }
    [NSFileManager.defaultManager createDirectoryAtURL:self.pairingURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
    if (![data writeToURL:self.pairingURL options:NSDataWritingAtomic error:&error]) { [self message:error.localizedDescription]; return; }
    [self message:@"Файл импортирован. Подключи LocalDevVPN и нажми Play."];
}
- (void)enableFrom:(UIViewController *)presenter attached:(void (^)(void))attached {
    self.presenter = presenter;
    [self request:@"enable" attached:attached];
}
- (void)request:(NSString *)operation attached:(void (^)(void))attached {
    if (self.helper) { [self message:@"Запрос JIT уже выполняется."]; return; }
    if (@available(iOS 17.4, *)) {} else { [self message:@"Нужна iOS 17.4 или новее."]; return; }
    if (getenv("LC_HOME_PATH")) { [self message:@"Встроенный JIT недоступен внутри LiveContainer."]; return; }
    if (!getEntitlementValue(@"get-task-allow")) { [self message:@"Подпись приложения не содержит get-task-allow. Нужна совместимая подпись для разработки."]; return; }
    NSData *pairing = [NSData dataWithContentsOfURL:self.pairingURL];
    if (!pairing.length && ![operation isEqual:@"reset"]) { [self message:@"Импортируй файл сопряжения в меню JIT. LocalDevVPN должен быть подключён."]; return; }
    NSURL *plugin = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"AMJITHelper.appex"];
    NSString *identifier = [NSBundle bundleWithURL:plugin].bundleIdentifier;
    if (!identifier) { [self message:@"В IPA отсутствует AMJITHelper. При установке нужно сохранить расширение приложения."]; return; }
    dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
    Class cls = NSClassFromString(@"NSExtension");
    NSError *error;
    id helper = [cls extensionWithIdentifier:identifier error:&error];
    if (!helper) { [self message:error.localizedDescription ?: @"iOS не смогла запустить встроенный помощник JIT."]; return; }
    NSData *script = [NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"UniversalJIT26" withExtension:@"js"]];
    if ([operation isEqual:@"enable"] && !script.length) { [self message:@"В сборке отсутствует скрипт UniversalJIT26.js."]; return; }
    self.helper = helper;
    self.attached = NO;
    self.onAttached = attached;
    self.deadline = [NSDate dateWithTimeIntervalSinceNow:300];
    __weak AMBuiltInJIT *weakSelf = self;
    [helper setRequestCompletionBlock:^(NSUUID *uuid, NSArray *items) {
        NSDictionary *reply = ((NSExtensionItem *)items.firstObject).userInfo;
        dispatch_async(dispatch_get_main_queue(), ^{
            AMBuiltInJIT *s = weakSelf;
            if (s.helper != helper) return;
            BOOL failed = ![reply[@"ok"] boolValue];
            BOOL wasAttached = s.attached;
            void (^ready)(void) = nil;
            if (!failed && !wasAttached && s.onAttached && isJITEnabled(false)) ready = s.onAttached;
            [s finishWaiting:^{
                if (ready) ready();
                else if (failed || ![operation isEqual:@"enable"]) [s message:reply[@"message"] ?: @"Помощник завершился без ответа."];
                else if (!wasAttached) [s message:@"Помощник завершился, но готовность JIT не подтверждена."];
            }];
        });
    }];
    [helper setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) { dispatch_async(dispatch_get_main_queue(), ^{ if (weakSelf.helper == helper) [weakSelf fail:error.localizedDescription ?: @"Запрос JIT отменён."]; }); }];
    [helper setRequestInterruptionBlock:^(NSUUID *uuid) { dispatch_async(dispatch_get_main_queue(), ^{ if (weakSelf.helper == helper) [weakSelf fail:@"Служебный процесс JIT остановлен системой."]; }); }];
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{@"operation":operation, @"pid":@(getpid()), @"pairing":pairing ?: NSData.data, @"script":script ?: NSData.data, @"forceScript":@([NSUserDefaults.standardUserDefaults boolForKey:@"AMJITForceScript"])};
    self.waiting = [UIAlertController alertControllerWithTitle:@"Подготовка JIT" message:@"Проверка соединения и DDI. Первая подготовка может занять несколько минут. LocalDevVPN должен быть подключён." preferredStyle:UIAlertControllerStyleAlert];
    [self.waiting addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        if (weakSelf.requestID) [weakSelf.helper cancelExtensionRequestWithIdentifier:weakSelf.requestID];
        [weakSelf finishWaiting:nil];
    }]];
    [self.presenter presentViewController:self.waiting animated:YES completion:nil];
    [helper beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *uuid) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf.helper) return;
            if (!uuid) { [weakSelf fail:@"Не удалось создать процесс JIT."]; return; }
            weakSelf.requestID = uuid;
            weakSelf.timer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) { [weakSelf pollAttachment]; }];
        });
    }];
}
- (void)pollAttachment {
    if (self.onAttached && isJITEnabled(false)) {
        // This only starts JavaLauncher. Its existing region/BRK handshake must
        // still succeed before the JVM starts; the helper stays alive until detach.
        self.attached = YES;
        void (^callback)(void) = self.onAttached;
        self.onAttached = nil;
        [self.timer invalidate]; self.timer = nil;
        UIAlertController *alert = self.waiting; self.waiting = nil;
        [alert dismissViewControllerAnimated:YES completion:callback];
    } else if ([self.deadline timeIntervalSinceNow] <= 0) {
        [self.helper cancelExtensionRequestWithIdentifier:self.requestID];
        [self fail:@"JIT не включился за 5 минут. Проверь LocalDevVPN и файл сопряжения. Можно повторить попытку или выбрать StikDebug."];
    }
}
- (void)finishWaiting:(void (^)(void))completion {
    [self.timer invalidate]; self.timer = nil;
    self.onAttached = nil;
    // Break the retained extension's callback cycle at the end of its request.
    [self.helper setRequestCompletionBlock:nil];
    [self.helper setRequestCancellationBlock:nil];
    [self.helper setRequestInterruptionBlock:nil];
    self.helper = nil; self.requestID = nil;
    UIAlertController *alert = self.waiting; self.waiting = nil;
    if (alert.presentingViewController) [alert dismissViewControllerAnimated:YES completion:completion];
    else if (completion) completion();
}
- (void)fail:(NSString *)message {
    if (!self.helper) return;
    [self finishWaiting:^{ [self message:message]; }];
}
@end
