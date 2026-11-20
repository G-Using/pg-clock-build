#import "PGGrabberLandscapeBar.h"
#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreMotion/CoreMotion.h>
#import <dlfcn.h>
#import <math.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <time.h>

#pragma mark - 常量

/// 横屏块距屏幕顶边的距离（横屏下的顶边是物理侧边，没有刘海，给一点留白即可）。
static const CGFloat PGLandscapeBarTopInset = 6.0;

/// 竖屏时块落在灵动岛/刘海下方，与安全区再留一点空隙。
static const CGFloat PGLandscapeBarPortraitGap = 4.0;

/// 轮询间隔。方向变化没有可靠且单一的公开通知可依赖，轮询只做几次属性比较，开销可忽略。
static const NSTimeInterval PGLandscapePollInterval = 0.5;

/// 每多少次轮询重读一次偏好。tweak 在 dyld 早期加载时 CFPreferences 可能还没同步到最新值，
/// 一旦 active 被算成 NO 又没人再发设置变更通知，常驻块就会永久不显示 —— 必须能自愈。
static const NSInteger PGLandscapePreferenceRefreshTicks = 10;

/// 重力阈值：约 33° 以上横置才算横屏，避免握持抖动导致块乱闪。
static const CGFloat PGLandscapeGravityThreshold = 0.55;

static NSString *const PGLandscapeLogPath = @"/var/mobile/Media/PerfectGrabber.log";
static const unsigned long long PGLandscapeLogMaxBytes = 512ULL * 1024ULL;

#pragma mark - 诊断日志

static NSLock *PGLogLock = nil;

static void PGLogLine(NSString *message) {
    time_t now = time(NULL);
    struct tm parts;
    memset(&parts, 0, sizeof(parts));
    localtime_r(&now, &parts);
    char stamp[16] = {0};
    strftime(stamp, sizeof(stamp), "%H:%M:%S", &parts);
    NSString *line = [NSString stringWithFormat:@"[%s] %@\n", stamp, message];
    fprintf(stderr, "[PerfectGrabber] %s", line.UTF8String);

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        PGLogLock = [[NSLock alloc] init];
    });
    [PGLogLock lock];
    @try {
        NSFileManager *manager = [NSFileManager defaultManager];
        if (![manager fileExistsAtPath:PGLandscapeLogPath]) {
            [manager createFileAtPath:PGLandscapeLogPath contents:[NSData data] attributes:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:PGLandscapeLogPath];
        if (handle) {
            @try {
                [handle seekToEndOfFile];
                [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            } @finally {
                [handle closeFile];
            }
        }
    } @catch (__unused NSException *exception) {
    }
    [PGLogLock unlock];
}

static void PGLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    PGLogLine(message);
}

/// 日志只保留最近一小段，防止长期运行撑爆 Media 分区。
static void PGTrimLogIfNeeded(void) {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:PGLandscapeLogPath error:nil];
    if (!attributes) return;
    if ([attributes[NSFileSize] unsignedLongLongValue] <= PGLandscapeLogMaxBytes) return;
    [[NSFileManager defaultManager] removeItemAtPath:PGLandscapeLogPath error:nil];
}

#pragma mark - 方向状态（供日志与判定共用）

static UIInterfaceOrientation PGFBSCachedOrientation = UIInterfaceOrientationUnknown;
static UIInterfaceOrientation PGStatusBarCachedOrientation = UIInterfaceOrientationUnknown;
static UIInterfaceOrientation PGSceneCachedOrientation = UIInterfaceOrientationUnknown;
static UIInterfaceOrientation PGDeviceCachedOrientation = UIInterfaceOrientationUnknown;

/// 加速度计给出的重力 x 分量。多处跨线程读写，读写本身是 64 位对齐的原子操作，足够用。
static volatile double PGGravityX = 0.0;
static volatile BOOL PGGravityValid = NO;

/// 竖屏时块左上角的 y 值：贴着灵动岛/刘海的下沿。
/// SpringBoard 的窗口上 safeAreaInsets 不一定有值，所以按屏幕高度兜底。
static CGFloat PGPortraitTopInset(CGRect screenBounds) {
    CGFloat height = CGRectGetHeight(screenBounds);
    CGFloat fallback = height >= 812.0 ? 59.0 : 20.0;   // 全面屏（含灵动岛）59，非全面屏 20

    UIEdgeInsets insets = UIEdgeInsetsZero;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *keyWindow = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    if (keyWindow && keyWindow.safeAreaInsets.top > 0.0) insets = keyWindow.safeAreaInsets;

    return MAX(insets.top, fallback) + PGLandscapeBarPortraitGap;
}

static UIInterfaceOrientation PGSpringBoardInterfaceOrientation(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (!application || ![application respondsToSelector:@selector(statusBarOrientation)]) {
        return UIInterfaceOrientationUnknown;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return application.statusBarOrientation;
#pragma clang diagnostic pop
}

/// UIDeviceOrientation 与 UIInterfaceOrientation 的左右定义相反，必须换过来。
static UIInterfaceOrientation PGInterfaceOrientationFromDevice(UIDeviceOrientation orientation) {
    switch (orientation) {
        case UIDeviceOrientationPortrait: return UIInterfaceOrientationPortrait;
        case UIDeviceOrientationPortraitUpsideDown: return UIInterfaceOrientationPortraitUpsideDown;
        case UIDeviceOrientationLandscapeLeft: return UIInterfaceOrientationLandscapeRight;
        case UIDeviceOrientationLandscapeRight: return UIInterfaceOrientationLandscapeLeft;
        default: return UIInterfaceOrientationUnknown;
    }
}

/// 只用于兜底：SpringBoard 的 connectedScenes 看不到前台 App 的场景，
/// 视频全屏时这里通常什么也拿不到。
static UIInterfaceOrientation PGSceneInterfaceOrientation(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        return windowScene.interfaceOrientation;
    }
    return UIInterfaceOrientationUnknown;
}

#pragma mark - FrontBoardServices 方向服务

/// 只让编译器认识这些私有方法，实际对象由运行时提供（SpringBoard 里 FrontBoardServices 一定在）。
@interface PGLandscapeFBSObserverStub : NSObject
- (void)setHandler:(void (^)(long long orientation))handler;
- (void)activate;
- (void)invalidate;
- (long long)activeInterfaceOrientation;
@end

static PGLandscapeFBSObserverStub *PGFBSObserver = nil;
static NSInteger PGFBSStartAttempts = 0;
/// tweak 在 dyld 早期加载，那时 FrontBoardServices 可能还没就绪，所以允许稍后重试几次。
static const NSInteger PGFBSMaxStartAttempts = 5;

static void PGRequestRefresh(void);

/// FBSOrientationObserver 是 SpringBoard 自己用来跟踪"前台 App 界面方向"的对象，
/// 视频全屏隐藏状态栏时它依然准确 —— 这是这个功能唯一可靠的软件方向源。
static BOOL PGStartFBSObserver(void) {
    if (PGFBSObserver) return YES;
    if (PGFBSStartAttempts >= PGFBSMaxStartAttempts) return NO;
    PGFBSStartAttempts++;

    Class observerClass = NSClassFromString(@"FBSOrientationObserver");
    if (!observerClass) {
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
        observerClass = NSClassFromString(@"FBSOrientationObserver");
    }
    if (!observerClass) {
        PGLog(@"FBS: 找不到 FBSOrientationObserver，方向只能退回状态栏/重力");
        return NO;
    }
    id instance = [observerClass new];
    if (![instance respondsToSelector:@selector(activate)] ||
        ![instance respondsToSelector:@selector(setHandler:)]) {
        PGLog(@"FBS: 接口与预期不符，放弃");
        return NO;
    }

    PGLandscapeFBSObserverStub *stub = (PGLandscapeFBSObserverStub *)instance;
    [stub setHandler:^(long long orientation) {
        if (orientation <= 0 || orientation > 4) return;
        PGFBSCachedOrientation = (UIInterfaceOrientation)orientation;
        PGRequestRefresh();
    }];
    [stub activate];

    long long current = [stub activeInterfaceOrientation];
    if (current > 0 && current <= 4) PGFBSCachedOrientation = (UIInterfaceOrientation)current;
    PGFBSObserver = stub;
    PGLog(@"FBS: observer 就绪，当前方向=%lld", current);
    return YES;
}

#pragma mark - 方向解析

/// 返回当前应采用的界面方向。只有确认横屏才返回横屏。
/// 优先级：物理重力（横置是物理事实，视频强制横屏也骗不了它）
///        → FBS（前台 App 的真实界面方向）
///        → 状态栏 → 场景 → 设备方向。
static UIInterfaceOrientation PGResolvedOrientation(void) {
    PGStatusBarCachedOrientation = PGSpringBoardInterfaceOrientation();
    PGSceneCachedOrientation = PGSceneInterfaceOrientation();

    UIDevice *device = UIDevice.currentDevice;
    if (!device.isGeneratingDeviceOrientationNotifications) {
        [device beginGeneratingDeviceOrientationNotifications];
    }
    PGDeviceCachedOrientation = PGInterfaceOrientationFromDevice(device.orientation);

    // 1) 只要加速度计有数据，物理姿态就是最高优先级，且不做任何"软件源覆盖"：
    //    手机竖着拿就一定是竖屏（块落在灵动岛下方、不旋转），横过来才算横屏。
    //    这样竖屏永远不会被 FBS/状态栏带偏而出现歪着显示的块。
    if (PGGravityValid) {
        if (PGGravityX <= -PGLandscapeGravityThreshold) return UIInterfaceOrientationLandscapeLeft;
        if (PGGravityX >= PGLandscapeGravityThreshold) return UIInterfaceOrientationLandscapeRight;
        return UIInterfaceOrientationPortrait;
    }

    // 2) 加速度计不可用时，用 FBS 报的界面方向。
    if (UIInterfaceOrientationIsLandscape(PGFBSCachedOrientation)) return PGFBSCachedOrientation;

    if (UIInterfaceOrientationIsLandscape(PGStatusBarCachedOrientation)) return PGStatusBarCachedOrientation;
    if (UIInterfaceOrientationIsLandscape(PGSceneCachedOrientation)) return PGSceneCachedOrientation;
    if (UIInterfaceOrientationIsLandscape(PGDeviceCachedOrientation)) return PGDeviceCachedOrientation;

    return UIInterfaceOrientationPortrait;
}

/// 承载窗口必须挂在"坐标系以竖屏为基准"的场景上，视频 App 那个横屏场景不行。
static UIWindowScene *PGLandscapeHostScene(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindowScene *landscapeFallback = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        if (!UIInterfaceOrientationIsLandscape(windowScene.interfaceOrientation)) return windowScene;
        if (!landscapeFallback) landscapeFallback = windowScene;
    }
    if (landscapeFallback) return landscapeFallback;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in application.windows) {
        if (window.windowScene) return window.windowScene;
    }
#pragma clang diagnostic pop
    return nil;
}

#pragma mark - 视图与窗口

/// 复用的样式方法，定义在 PGGrabberOverlayView.m 内。
@interface PGGrabberOverlayView (PGLandscapeStyle)
- (void)applyAppearance;
@end

/// 复用下拉覆盖层的排版与配色，但四角都是圆角：它是浮在画面上的胶囊，不贴着屏幕边缘。
@interface PGLandscapeBarView : PGGrabberOverlayView
@end

@implementation PGLandscapeBarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = YES;
        self.layer.cornerRadius = 10.0;
    }
    return self;
}

- (void)applyAppearance {
    [super applyAppearance];
    self.layer.cornerRadius = 10.0;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                               kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
}

@end

/// 只负责显示、永不抢焦点：横屏块必须完全穿透触摸。
@interface PGLandscapeBarWindow : UIWindow
@end

@implementation PGLandscapeBarWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (BOOL)canBecomeFocused {
    return NO;
}

@end

#pragma mark - 横屏常驻块

@interface PGLandscapeBar ()

@property (nonatomic, strong, nullable) PGLandscapeBarWindow *window;
@property (nonatomic, strong, nullable) UIView *rotator;
@property (nonatomic, strong, nullable) PGLandscapeBarView *bar;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) NSTimer *suspendTimer;
@property (nonatomic, strong, nullable) CMMotionManager *motionManager;
@property (nonatomic, strong, nullable) NSOperationQueue *motionQueue;
@property (nonatomic, assign) UIInterfaceOrientation laidOutOrientation;
/// 承载窗口的坐标系恒为竖屏基准（SpringBoard 自己的窗口不跟随 App 旋转），
/// 所以横屏内容一律靠反向旋转补偿，不再根据场景方向分支 —— 那个分支是横屏布局崩掉的原因。
@property (nonatomic, assign) BOOL motionUnavailable;
@property (nonatomic, assign) BOOL updating;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) NSInteger pollTicks;
@property (nonatomic, copy, nullable) NSString *lastSnapshot;

@end

@implementation PGLandscapeBar

+ (instancetype)sharedBar {
    static PGLandscapeBar *bar;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bar = [[self alloc] init];
    });
    return bar;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _laidOutOrientation = UIInterfaceOrientationUnknown;
    }
    return self;
}

- (void)dealloc {
    [_pollTimer invalidate];
    [_motionManager stopAccelerometerUpdates];
    if (PGFBSObserver) [PGFBSObserver invalidate];
}

#pragma mark 对外入口

- (void)reloadPreferences {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadPreferences];
        });
        return;
    }

    PGTrimLogIfNeeded();
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    self.active = preferences.isEnabled && preferences.landscapeAlwaysOn;
    // 设置可能改了字号/配色，强制下一次重新排版。
    self.laidOutOrientation = UIInterfaceOrientationUnknown;
    // 设置变更是一次干净的重新开始：清掉可能残留的暂停标记和计时器。
    [self.suspendTimer invalidate];
    self.suspendTimer = nil;
    self.suspended = NO;

    PGLog(@"reload: enabled=%d landscapeAlwaysOn=%d debugForce=%d → active=%d",
          preferences.isEnabled, preferences.landscapeAlwaysOn,
          preferences.debugForceLandscape, self.active);

    if (self.active) {
        PGStartFBSObserver();
        [self startMotionUpdatesIfNeeded];
        [self startPolling];
    }
    [self refreshNow];
}

- (void)setSuspended:(BOOL)suspended {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setSuspended:suspended];
        });
        return;
    }
    [self.suspendTimer invalidate];
    self.suspendTimer = nil;

    if (suspended == _suspended && !suspended) {
        [self refreshNow];
        return;
    }
    _suspended = suspended;

    if (suspended) {
        // 兜底：SBGrabberTongue 的 _willDismiss 未必总被调用（手势取消、被系统打断等），
        // 一旦漏掉这个标记就会永久处于"暂停"状态、横竖屏都不显示。3 秒后强制恢复。
        __weak typeof(self) weakSelf = self;
        NSTimer *timer = [NSTimer timerWithTimeInterval:3.0
                                               repeats:NO
                                                 block:^(NSTimer *fireTimer) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!strongSelf->_suspended) return;
            PGLog(@"suspended 超时，强制恢复显示");
            strongSelf->_suspended = NO;
            [strongSelf refreshNow];
        }];
        self.suspendTimer = timer;
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    }
    [self refreshNow];
}

#pragma mark 重力方向

- (void)startMotionUpdatesIfNeeded {
    if (self.motionManager || self.motionUnavailable) return;
    CMMotionManager *manager = [[CMMotionManager alloc] init];
    if (!manager.isAccelerometerAvailable) {
        self.motionUnavailable = YES;
        PGLog(@"CoreMotion: 加速度计不可用");
        return;
    }
    manager.accelerometerUpdateInterval = 0.2;
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;
    queue.qualityOfService = NSQualityOfServiceUtility;
    self.motionManager = manager;
    self.motionQueue = queue;

    __block NSInteger samples = 0;
    [manager startAccelerometerUpdatesToQueue:queue withHandler:^(CMAccelerometerData *data, NSError *error) {
        if (!data) {
            if (error && samples == 0) PGLog(@"CoreMotion: 回调错误 %@", error.localizedDescription);
            return;
        }
        PGGravityX = data.acceleration.x;
        PGGravityValid = YES;
        samples++;
        if (samples == 1) PGLog(@"CoreMotion: 首个样本 x=%.3f y=%.3f z=%.3f",
                                data.acceleration.x, data.acceleration.y, data.acceleration.z);
    }];
}

- (void)stopMotionUpdates {
    [self.motionManager stopAccelerometerUpdates];
    self.motionManager = nil;
    self.motionQueue = nil;
    PGGravityValid = NO;
}

#pragma mark 轮询

- (void)startPolling {
    if (self.pollTimer) return;
    NSTimer *timer = [NSTimer timerWithTimeInterval:PGLandscapePollInterval
                                             target:self
                                           selector:@selector(pollTick)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.pollTimer = timer;
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)pollTick {
    self.pollTicks++;
    if (self.pollTicks % PGLandscapePreferenceRefreshTicks == 0) {
        // 定期重读偏好：dyld 早期可能读到旧值，这里必须能自愈。
        PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
        [preferences reload];
        BOOL shouldBeActive = preferences.isEnabled && preferences.landscapeAlwaysOn;
        if (shouldBeActive != self.active) {
            PGLog(@"偏好自愈: active %d → %d", self.active, shouldBeActive);
            self.active = shouldBeActive;
            if (shouldBeActive) {
                PGStartFBSObserver();
                [self startMotionUpdatesIfNeeded];
            }
        }
    }
    [self refreshNow];
}

- (void)refreshNow {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshNow];
        });
        return;
    }

    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;

    if (!self.active) {
        [self hideBar];
        [self logSnapshotFor:UIInterfaceOrientationUnknown shown:NO note:@"inactive"];
        return;
    }
    if (self.suspended) {
        [self hideBar];
        [self logSnapshotFor:UIInterfaceOrientationUnknown shown:NO note:@"suspended"];
        return;
    }

    UIInterfaceOrientation orientation = PGResolvedOrientation();
    if (preferences.debugForceLandscape) {
        orientation = UIInterfaceOrientationLandscapeLeft;
    }
    // 竖屏也常驻：落在灵动岛/刘海下方居中；横屏落到用户视角的顶边。
    BOOL shown = [self showBarForOrientation:orientation];
    NSString *note = shown
        ? (UIInterfaceOrientationIsLandscape(orientation) ? @"show-横屏" : @"show-竖屏")
        : @"no-window";
    [self logSnapshotFor:orientation shown:shown note:note];
}

- (void)logSnapshotFor:(UIInterfaceOrientation)orientation shown:(BOOL)shown note:(NSString *)note {
    NSString *snapshot = [NSString stringWithFormat:@"%ld/%d/%@", (long)orientation, shown, note];
    if (self.lastSnapshot && [self.lastSnapshot isEqualToString:snapshot]) return;
    self.lastSnapshot = snapshot;

    NSString *gravity = PGGravityValid
        ? [NSString stringWithFormat:@"%.2f", PGGravityX]
        : @"n/a";
    PGLog(@"%@ | 方向=%ld 显示=%d | fbs=%ld status=%ld scene=%ld device=%ld gravityX=%@ | 窗口=%@ level=%.0f",
          note, (long)orientation, shown,
          (long)PGFBSCachedOrientation, (long)PGStatusBarCachedOrientation,
          (long)PGSceneCachedOrientation, (long)PGDeviceCachedOrientation,
          gravity, self.window ? @"有" : @"无", self.window ? self.window.windowLevel : 0.0);
}

#pragma mark 显示

- (BOOL)showBarForOrientation:(UIInterfaceOrientation)orientation {
    if (![self ensureWindowAndSubviews]) return NO;
    // 先启动更新把文字填好，再排版，否则第一次量出来的宽度是空的。
    if (!self.updating) {
        [self.bar startUpdating];
        self.updating = YES;
    }
    [self layoutBarForOrientation:orientation];
    self.bar.hidden = NO;
    self.window.hidden = NO;
    [self.window bringSubviewToFront:self.rotator];
    return YES;
}

- (BOOL)ensureWindowAndSubviews {
    // 窗口一次建好就不再重建：SpringBoard 的主场景不会销毁，反复 teardown/重建
    // 只会在横竖切换时闪断。坐标系恒为竖屏基准，与场景方向无关。
    if (self.window) return YES;

    // 坐标系恒为竖屏基准（SpringBoard 自己的窗口不跟随 App 旋转），与场景方向无关。
    CGRect base = UIScreen.mainScreen.bounds;
    if (CGRectGetWidth(base) <= 0.0 || CGRectGetHeight(base) <= 0.0) return NO;

    UIWindowScene *scene = PGLandscapeHostScene();
    PGLandscapeBarWindow *window = nil;
    if (scene) {
        window = [[PGLandscapeBarWindow alloc] initWithWindowScene:scene];
    } else {
        // 拿不到场景时退化成整屏窗口（SpringBoard 是单场景进程，legacy 窗口依然能显示）。
        window = [[PGLandscapeBarWindow alloc] initWithFrame:base];
    }
    if (!window) return NO;
    window.frame = base;
    // 必须高于 UIWindowLevelAlert：视频/游戏全屏时前台 App 的层级很高，
    // 音量 HUD、来电横幅这类 SpringBoard 覆盖层都在 Alert 之上才看得见。
    window.windowLevel = UIWindowLevelAlert + 1001.0;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;
    window.accessibilityElementsHidden = YES;
    window.hidden = YES;

    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = UIColor.clearColor;
    controller.view.userInteractionEnabled = NO;
    window.rootViewController = controller;

    UIView *rotator = [[UIView alloc] init];
    rotator.backgroundColor = UIColor.clearColor;
    rotator.userInteractionEnabled = NO;
    rotator.clipsToBounds = NO;
    [controller.view addSubview:rotator];

    PGLandscapeBarView *bar = [[PGLandscapeBarView alloc] initWithFrame:CGRectZero];
    bar.hidden = YES;
    [rotator addSubview:bar];

    self.window = window;
    self.rotator = rotator;
    self.bar = bar;
    self.laidOutOrientation = UIInterfaceOrientationUnknown;

    PGLog(@"窗口已创建: scene=%@ bounds=%.0fx%.0f level=%.0f",
          scene ? @"有" : @"无(legacy)",
          CGRectGetWidth(base), CGRectGetHeight(base), window.windowLevel);
    return YES;
}

- (void)layoutBarForOrientation:(UIInterfaceOrientation)orientation {
    CGRect screenBounds = UIScreen.mainScreen.bounds;   // 恒竖屏基准：宽=水平，高=竖直
    CGFloat screenWidth = CGRectGetWidth(screenBounds);
    CGFloat screenHeight = CGRectGetHeight(screenBounds);
    if (screenWidth <= 0.0 || screenHeight <= 0.0) return;

    // 横屏时画布转成横的（932x430），转 90° 后视觉上正好铺满竖屏屏幕。
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    CGFloat canvasWidth = landscape ? screenHeight : screenWidth;
    CGFloat canvasHeight = landscape ? screenWidth : screenHeight;

    CGSize currentSize = self.rotator.bounds.size;
    BOOL sizeUnchanged = fabs(currentSize.width - canvasWidth) < 0.5 &&
                         fabs(currentSize.height - canvasHeight) < 0.5;
    BOOL windowUnchanged = fabs(CGRectGetWidth(self.window.bounds) - screenWidth) < 0.5;
    if (self.laidOutOrientation == orientation && sizeUnchanged && windowUnchanged) return;

    self.window.frame = screenBounds;
    self.rotator.bounds = CGRectMake(0.0, 0.0, canvasWidth, canvasHeight);
    self.rotator.center = CGPointMake(screenWidth / 2.0, screenHeight / 2.0);

    // 横屏：SpringBoard 自己的窗口不跟着应用转，所以整块内容反向补偿旋转，人眼看到才是正的。
    // LandscapeLeft = 用户视角的“上”落在物理左边，所以逆时针转 90°。
    // 竖屏：不转，直接水平排版，落在灵动岛/刘海下方。
    if (landscape) {
        BOOL leftEdgeUp = orientation == UIInterfaceOrientationLandscapeLeft;
        self.rotator.transform = CGAffineTransformMakeRotation(leftEdgeUp ? -M_PI_2 : M_PI_2);
    } else {
        self.rotator.transform = CGAffineTransformIdentity;
    }

    CGSize size = [self.bar preferredContentSizeForMaxWidth:MAX(80.0, canvasWidth - 48.0)];
    CGFloat barWidth = MIN(MAX(size.width, 44.0), canvasWidth - 24.0);
    CGFloat barHeight = MAX(size.height, 20.0);
    // 横屏：贴着物理侧边（用户视角的顶边）；竖屏：灵动岛/刘海下方居中。
    CGFloat top = landscape ? PGLandscapeBarTopInset : PGPortraitTopInset(screenBounds);
    self.bar.frame = CGRectMake((canvasWidth - barWidth) / 2.0, top, barWidth, barHeight);
    self.laidOutOrientation = orientation;

    PGLog(@"排版: 方向=%ld 画布=%.0fx%.0f 胶囊=%.0fx%.0f(=%.0f,%.0f %.0fx%.0f) 旋转=%d",
          (long)orientation, canvasWidth, canvasHeight,
          barWidth, barHeight,
          CGRectGetMinX(self.bar.frame), CGRectGetMinY(self.bar.frame), barWidth, barHeight,
          landscape);
}

- (void)hideBar {
    if (self.updating) {
        [self.bar stopUpdating];
        self.updating = NO;
    }
    self.bar.hidden = YES;
    self.window.hidden = YES;
    self.laidOutOrientation = UIInterfaceOrientationUnknown;
}

- (void)teardownWindow {
    if (self.updating) {
        [self.bar stopUpdating];
        self.updating = NO;
    }
    self.window.hidden = YES;
    self.window.rootViewController = nil;
    self.window = nil;
    self.rotator = nil;
    self.bar = nil;
    self.laidOutOrientation = UIInterfaceOrientationUnknown;
}

@end

#pragma mark - 跨线程刷新入口

static void PGRequestRefresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [PGLandscapeBar.sharedBar refreshNow];
    });
}
