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

    // 1) 只要加速度计有数据，物理姿态就是最高优先级：手机真的横过来了，就一定显示。
    if (PGGravityValid) {
        if (PGGravityX <= -PGLandscapeGravityThreshold) return UIInterfaceOrientationLandscapeLeft;
        if (PGGravityX >= PGLandscapeGravityThreshold) return UIInterfaceOrientationLandscapeRight;
        // 手机物理上还竖着。但如果系统说前台 App 已经是横屏（强制横屏的播放器），也得跟着显示。
        if (UIInterfaceOrientationIsLandscape(PGFBSCachedOrientation)) return PGFBSCachedOrientation;
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
@property (nonatomic, strong, nullable) CMMotionManager *motionManager;
@property (nonatomic, strong, nullable) NSOperationQueue *motionQueue;
@property (nonatomic, assign) UIInterfaceOrientation laidOutOrientation;
/// 承载窗口所在场景的坐标系是否以竖屏为基准。是才需要反向旋转补偿。
@property (nonatomic, assign) BOOL hostPortraitBase;
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
    if (_suspended == suspended) return;
    _suspended = suspended;
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
    if (!UIInterfaceOrientationIsLandscape(orientation)) {
        [self hideBar];
        [self logSnapshotFor:orientation shown:NO note:@"vertical"];
        return;
    }
    BOOL shown = [self showBarForOrientation:orientation];
    [self logSnapshotFor:orientation shown:shown note:(shown ? @"show" : @"no-scene")];
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
    UIWindowScene *scene = PGLandscapeHostScene();
    if (self.window && scene && self.window.windowScene != scene) [self teardownWindow];
    if (self.window) return YES;

    self.hostPortraitBase = scene ? !UIInterfaceOrientationIsLandscape(scene.interfaceOrientation) : YES;
    CGRect base = self.hostPortraitBase ? UIScreen.mainScreen.bounds : scene.coordinateSpace.bounds;
    if (CGRectGetWidth(base) <= 0.0 || CGRectGetHeight(base) <= 0.0) base = UIScreen.mainScreen.bounds;
    if (CGRectGetWidth(base) <= 0.0 || CGRectGetHeight(base) <= 0.0) return NO;

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

    PGLog(@"窗口已创建: scene=%@ portraitBase=%d bounds=%.0fx%.0f level=%.0f",
          scene ? @"有" : @"无(legacy)", self.hostPortraitBase,
          CGRectGetWidth(base), CGRectGetHeight(base), window.windowLevel);
    return YES;
}

- (void)layoutBarForOrientation:(UIInterfaceOrientation)orientation {
    CGRect bounds = self.window.bounds;
    CGFloat landscapeWidth = 0.0;
    CGFloat landscapeHeight = 0.0;
    if (self.hostPortraitBase) {
        // 竖屏基准坐标系：内容按横屏尺寸排版，再整体旋转 90° 铺回去。
        landscapeWidth = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
        landscapeHeight = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    } else {
        landscapeWidth = CGRectGetWidth(bounds);
        landscapeHeight = CGRectGetHeight(bounds);
    }
    if (landscapeWidth <= 0.0 || landscapeHeight <= 0.0) return;

    BOOL sizeUnchanged = CGRectGetWidth(self.rotator.bounds) == landscapeWidth &&
                         CGRectGetHeight(self.rotator.bounds) == landscapeHeight;
    if (self.laidOutOrientation == orientation && sizeUnchanged) return;

    self.rotator.bounds = CGRectMake(0.0, 0.0, landscapeWidth, landscapeHeight);
    self.rotator.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));

    // SpringBoard 自己的窗口不跟着应用转，所以把整块内容反向补偿旋转，人眼看到才是正的。
    // LandscapeLeft = 用户视角的“上”落在物理左边，因此逆时针转 90°。
    BOOL leftEdgeUp = orientation == UIInterfaceOrientationLandscapeLeft;
    self.rotator.transform = self.hostPortraitBase
        ? CGAffineTransformMakeRotation(leftEdgeUp ? -M_PI_2 : M_PI_2)
        : CGAffineTransformIdentity;

    CGSize size = [self.bar preferredContentSizeForMaxWidth:MAX(80.0, landscapeWidth - 48.0)];
    CGFloat barWidth = MIN(MAX(size.width, 44.0), landscapeWidth - 24.0);
    CGFloat barHeight = MAX(size.height, 20.0);
    self.bar.frame = CGRectMake((landscapeWidth - barWidth) / 2.0, PGLandscapeBarTopInset, barWidth, barHeight);
    self.laidOutOrientation = orientation;

    PGLog(@"排版: 方向=%ld 画布=%.0fx%.0f 胶囊=%.0fx%.0f 变换=%d",
          (long)orientation, landscapeWidth, landscapeHeight, barWidth, barHeight,
          self.hostPortraitBase);
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
