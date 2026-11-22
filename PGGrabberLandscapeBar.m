#import "PGGrabberLandscapeBar.h"
#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <math.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <time.h>

#pragma mark - 常量

/// 胶囊离物理侧边（用户视角的顶边）的距离。
static const CGFloat PGLandscapeBarEdgeInset = 6.0;

/// 轮询间隔。方向变化没有可靠且单一的公开通知可依赖，轮询只做几次属性比较，开销可忽略。
static const NSTimeInterval PGLandscapePollInterval = 0.4;

/// 每多少次轮询重读一次偏好。tweak 在 dyld 早期加载时 CFPreferences 可能还没同步到最新值。
static const NSInteger PGLandscapePreferenceRefreshTicks = 12;

/// 每多少次轮询写一行状态日志（约 12 秒），便于事后定位。
static const NSInteger PGLandscapeStatusLogTicks = 30;

/// 诊断弹窗刷新间隔（轮询次数，约 5 秒）。
static const NSInteger PGLandscapeAlertTicks = 12;

/// 进入 / 退出横屏的重力阈值（带滞回，避免握持在临界角度时块疯狂闪）。
static const double PGLandscapeEnterThreshold = 0.55;   // 约 33°
static const double PGLandscapeExitThreshold = 0.42;    // 约 25°

/// 重力"明确竖着"的判定线：低于它就强制竖屏，不让软件来源把块拽成歪的。
static const double PGLandscapePortraitVeto = 0.30;

/// 加速度计样本有效期。超过这个时间没有新样本就认为运动服务没工作，改用软件来源。
static const CFTimeInterval PGLandscapeGravityMaxAge = 2.0;

/// 加速计启动失败后的重试间隔与次数。dyld 早期 CoreMotion 常报不可用，不能一次失败就永久放弃。
static const CFTimeInterval PGLandscapeMotionRetryInterval = 3.0;
static const NSInteger PGLandscapeMotionMaxAttempts = 20;

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

#pragma mark - 原始方向探针

/// 加速度计的重力分量（设备坐标系，单位 g）。跨线程读写；8 字节标量读写原子。
static volatile double PGGravityX = 0.0;
static volatile double PGGravityY = 0.0;
static volatile CFTimeInterval PGGravityTimestamp = 0.0;
static volatile BOOL PGGravityValid = NO;

/// FBS 上报的界面方向（若可用）。
static UIInterfaceOrientation PGFBSCachedOrientation = UIInterfaceOrientationUnknown;

typedef long long (*PGIntegerGetter)(id, SEL);

/// 安全地调用一个"返回整数"的私有 getter。类/方法不存在时返回 NO，不抛异常。
static BOOL PGProbeInteger(id object, NSString *selectorName, long long *outValue) {
    if (!object || selectorName.length == 0) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (!selector || ![object respondsToSelector:selector]) return NO;
    @try {
        PGIntegerGetter getter = (PGIntegerGetter)[object methodForSelector:selector];
        if (!getter) return NO;
        if (outValue) *outValue = getter(object, selector);
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

/// 把 1..4 的枚举值收进 UIInterfaceOrientation，越界一律当作 Unknown。
static UIInterfaceOrientation PGInterfaceOrientationFromRaw(long long raw) {
    if (raw >= UIInterfaceOrientationPortrait && raw <= UIInterfaceOrientationLandscapeRight) {
        return (UIInterfaceOrientation)raw;
    }
    return UIInterfaceOrientationUnknown;
}

/// UIDeviceOrientation 与 UIInterfaceOrientation 的左右定义相反。
static UIInterfaceOrientation PGInterfaceOrientationFromDevice(UIDeviceOrientation orientation) {
    switch (orientation) {
        case UIDeviceOrientationPortrait: return UIInterfaceOrientationPortrait;
        case UIDeviceOrientationPortraitUpsideDown: return UIInterfaceOrientationPortraitUpsideDown;
        case UIDeviceOrientationLandscapeLeft: return UIInterfaceOrientationLandscapeRight;
        case UIDeviceOrientationLandscapeRight: return UIInterfaceOrientationLandscapeLeft;
        default: return UIInterfaceOrientationUnknown;
    }
}

/// 探针一：SpringBoard 用来给状态栏取方向的"前台 App 界面方向"。
/// 视频全屏隐藏状态栏时它依然跟着 App 转，是最贴合本需求的一个来源。
static UIInterfaceOrientation PGFrontMostAppOrientation(void) {
    long long raw = 0;
    if (!PGProbeInteger(UIApplication.sharedApplication, @"_frontMostAppOrientation", &raw)) {
        return UIInterfaceOrientationUnknown;
    }
    return PGInterfaceOrientationFromRaw(raw);
}

/// 探针二：SpringBoard 自己的设备姿态（UIDeviceOrientation 语义 1..7）。
static UIInterfaceOrientation PGSpringBoardDeviceOrientation(void) {
    long long raw = 0;
    if (!PGProbeInteger(UIApplication.sharedApplication, @"_deviceOrientation", &raw)) {
        return UIInterfaceOrientationUnknown;
    }
    if (raw < UIDeviceOrientationPortrait || raw > UIDeviceOrientationFaceDown) {
        return UIInterfaceOrientationUnknown;
    }
    return PGInterfaceOrientationFromDevice((UIDeviceOrientation)raw);
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

/// 最弱的一路：SpringBoard 自己的场景方向（视频全屏时通常停在竖屏）。
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

/// 只让编译器认识这些接口，实际对象由运行时提供。注意 handler 的真实参数是
/// FBSOrientationUpdate 对象（不是一个整数）—— 之前按整数签名接，拿到的是垃圾值，
/// 正是"竖屏恒定为横屏、块贴左边"的根源。
@interface PGLandscapeFBSObserverStub : NSObject
- (void)setHandler:(void (^)(id update))handler;
- (void)activate;
- (void)invalidate;
- (long long)activeInterfaceOrientation;
@end

static PGLandscapeFBSObserverStub *PGFBSObserver = nil;
static NSInteger PGFBSStartAttempts = 0;
static const NSInteger PGFBSMaxStartAttempts = 5;

static void PGRequestRefresh(void);

static BOOL PGStartFBSObserver(void) {
    if (PGFBSObserver) return YES;
    if (PGFBSStartAttempts >= PGFBSMaxStartAttempts) return NO;
    PGFBSStartAttempts++;

    Class observerClass = NSClassFromString(@"FBSOrientationObserver");
    if (!observerClass) {
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
        observerClass = NSClassFromString(@"FBSOrientationObserver");
    }
    if (!observerClass) return NO;

    id instance = [observerClass new];
    if (![instance respondsToSelector:@selector(activate)]) return NO;

    PGLandscapeFBSObserverStub *stub = (PGLandscapeFBSObserverStub *)instance;
    if ([stub respondsToSelector:@selector(setHandler:)]) {
        [stub setHandler:^(id update) {
            if (!update) return;
            long long raw = 0;
            if ([update respondsToSelector:@selector(orientation)]) {
                PGProbeInteger(update, @"orientation", &raw);
            } else if ([update respondsToSelector:@selector(valueForKey:)]) {
                @try {
                    id value = [update valueForKey:@"orientation"];
                    if ([value respondsToSelector:@selector(longLongValue)]) raw = [value longLongValue];
                } @catch (__unused NSException *exception) {
                    raw = 0;
                }
            }
            UIInterfaceOrientation orientation = PGInterfaceOrientationFromRaw(raw);
            if (orientation == UIInterfaceOrientationUnknown) return;
            PGFBSCachedOrientation = orientation;
            PGRequestRefresh();
        }];
    }
    [stub activate];

    long long current = 0;
    if ([stub respondsToSelector:@selector(activeInterfaceOrientation)] &&
        PGProbeInteger(stub, @"activeInterfaceOrientation", &current)) {
        UIInterfaceOrientation orientation = PGInterfaceOrientationFromRaw(current);
        if (orientation != UIInterfaceOrientationUnknown) PGFBSCachedOrientation = orientation;
    }

    PGFBSObserver = stub;
    PGLog(@"FBS: observer 就绪，当前=%lld", current);
    return YES;
}

#pragma mark - 视图与窗口

/// 复用的样式方法，定义在 PGGrabberOverlayView.m 内。
@interface PGGrabberOverlayView (PGLandscapeStyle)
- (void)applyAppearance;
@end

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

/// 只负责显示、永不抢焦点：常驻块必须完全穿透触摸。
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

/// 承载窗口所在场景。
static UIWindowScene *PGLandscapeHostScene(void) {
    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        return windowScene;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in application.windows) {
        if (window.windowScene) return window.windowScene;
    }
#pragma clang diagnostic pop
    return nil;
}

#pragma mark - 诊断弹窗

static CFUserNotificationRef PGDiagnosticAlert = NULL;

/// 用系统级警示框把当前状态直接显示在屏幕上。
/// 这个弹窗由系统绘制，一定能盖在全屏 App 之上 —— 用它当作"看得见的日志"。
static void PGPostDiagnosticAlert(NSString *title, NSString *message) {
    if (PGDiagnosticAlert) {
        CFRelease(PGDiagnosticAlert);
        PGDiagnosticAlert = NULL;
    }
    NSDictionary *payload = @{
        (__bridge NSString *)kCFUserNotificationAlertHeaderKey: title ?: @"PerfectGrabber",
        (__bridge NSString *)kCFUserNotificationAlertMessageKey: message ?: @"",
    };
    SInt32 error = 0;
    CFUserNotificationRef alert = CFUserNotificationCreate(kCFAllocatorDefault, 0,
                                                           kCFUserNotificationPlainAlertLevel,
                                                           &error, (__bridge CFDictionaryRef)payload);
    if (alert) PGDiagnosticAlert = alert;
}

#pragma mark - 横屏常驻块

@interface PGLandscapeBar ()

@property (nonatomic, strong, nullable) PGLandscapeBarWindow *window;
@property (nonatomic, strong, nullable) PGLandscapeBarView *bar;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) NSTimer *suspendTimer;
@property (nonatomic, strong, nullable) CMMotionManager *motionManager;
@property (nonatomic, strong, nullable) NSOperationQueue *motionQueue;
@property (nonatomic, assign) NSInteger motionAttempts;
@property (nonatomic, assign) CFTimeInterval motionLastAttempt;
@property (nonatomic, assign) NSInteger motionSamples;
@property (nonatomic, assign) BOOL updating;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, assign) NSInteger pollTicks;
@property (nonatomic, assign) BOOL laidOut;
@property (nonatomic, assign) BOOL laidOutLeftEdgeUp;
@property (nonatomic, assign) CGSize laidOutScreenSize;
/// 最近一次解析结果，供日志/诊断弹窗使用。
@property (nonatomic, copy) NSString *resolvedSource;
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
        _resolvedSource = @"-";
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
    self.laidOut = NO;
    [self.suspendTimer invalidate];
    self.suspendTimer = nil;
    self.suspended = NO;

    PGLog(@"reload: enabled=%d landscapeAlwaysOn=%d flip=%d alert=%d → active=%d",
          preferences.isEnabled, preferences.landscapeAlwaysOn,
          preferences.landscapeFlipSide, preferences.debugAlertEnabled, self.active);

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
        // 兜底：_willDismiss 未必总被调用，一旦漏掉这个标记就会永久暂停、横竖屏都不显示。
        __weak typeof(self) weakSelf = self;
        NSTimer *timer = [NSTimer timerWithTimeInterval:3.0
                                               repeats:NO
                                                 block:^(NSTimer *fireTimer) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!strongSelf->_suspended) return;
            PGLog(@"suspended 超时，强制恢复");
            strongSelf->_suspended = NO;
            [strongSelf refreshNow];
        }];
        self.suspendTimer = timer;
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    }
    [self refreshNow];
}

#pragma mark 物理姿态

/// dyld 早期 CoreMotion 常报不可用，所以失败不锁死，按间隔重试若干次。
- (void)startMotionUpdatesIfNeeded {
    if (self.motionManager) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (self.motionAttempts >= PGLandscapeMotionMaxAttempts) return;
    if (self.motionLastAttempt > 0.0 && now - self.motionLastAttempt < PGLandscapeMotionRetryInterval) return;

    self.motionAttempts++;
    self.motionLastAttempt = now;

    CMMotionManager *manager = [[CMMotionManager alloc] init];
    if (!manager.accelerometerAvailable) {
        PGLog(@"CoreMotion: 加速度计不可用（第 %ld 次尝试，稍后重试）", (long)self.motionAttempts);
        return;
    }
    manager.accelerometerUpdateInterval = 0.1;
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 1;
    queue.qualityOfService = NSQualityOfServiceUtility;
    self.motionManager = manager;
    self.motionQueue = queue;

    PGLog(@"CoreMotion: 已启动（第 %ld 次尝试）", (long)self.motionAttempts);
    __weak typeof(self) weakSelf = self;
    [manager startAccelerometerUpdatesToQueue:queue withHandler:^(CMAccelerometerData *data, NSError *error) {
        if (!data) {
            if (error) PGLog(@"CoreMotion: 回调错误 %@", error.localizedDescription);
            return;
        }
        PGGravityX = data.acceleration.x;
        PGGravityY = data.acceleration.y;
        PGGravityTimestamp = CACurrentMediaTime();
        PGGravityValid = YES;

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.motionSamples++;
        if (strongSelf.motionSamples == 1) {
            PGLog(@"CoreMotion: 首个样本 x=%.3f y=%.3f z=%.3f",
                  data.acceleration.x, data.acceleration.y, data.acceleration.z);
        }
    }];
}

/// 解析当前是否横屏，并给出"哪一侧边朝上"。
/// 优先级：重力（物理事实，且带竖屏否决）→ 前台 App 方向 → FBS → 设备姿态 → 状态栏 → 场景。
- (BOOL)resolveLandscape:(BOOL *)leftEdgeUp source:(NSString **)source {
    CFTimeInterval age = CACurrentMediaTime() - PGGravityTimestamp;
    BOOL gravityFresh = PGGravityValid && age >= 0.0 && age < PGLandscapeGravityMaxAge;

    if (gravityFresh) {
        double x = PGGravityX;
        double threshold = self.visible ? PGLandscapeExitThreshold : PGLandscapeEnterThreshold;
        // 坐标约定（设备坐标系，竖屏时 +x 向右、+y 向下）：
        // 手机顺时针转 90°（右边缘朝下、左边缘朝上），重力在 +x 上有正分量。
        if (x >= threshold) {
            if (leftEdgeUp) *leftEdgeUp = YES;
            if (source) *source = @"gravity";
            return YES;
        }
        if (x <= -threshold) {
            if (leftEdgeUp) *leftEdgeUp = NO;
            if (source) *source = @"gravity";
            return YES;
        }
        if (fabs(x) < PGLandscapePortraitVeto) {
            // 明确竖着拿：直接判竖屏，不让软件来源把块拽出来或拽歪。
            if (source) *source = @"gravity-portrait";
            return NO;
        }
    }

    UIInterfaceOrientation candidate = PGFrontMostAppOrientation();
    NSString *name = @"frontmost";
    if (!UIInterfaceOrientationIsLandscape(candidate)) {
        candidate = PGFBSCachedOrientation;
        name = @"fbs";
    }
    if (!UIInterfaceOrientationIsLandscape(candidate)) {
        candidate = PGSpringBoardDeviceOrientation();
        name = @"device";
    }
    if (!UIInterfaceOrientationIsLandscape(candidate)) {
        UIDevice *device = UIDevice.currentDevice;
        if (!device.isGeneratingDeviceOrientationNotifications) {
            [device beginGeneratingDeviceOrientationNotifications];
        }
        candidate = PGInterfaceOrientationFromDevice(device.orientation);
        name = @"uid";
    }
    if (!UIInterfaceOrientationIsLandscape(candidate)) {
        candidate = PGSpringBoardInterfaceOrientation();
        name = @"statusbar";
    }
    if (!UIInterfaceOrientationIsLandscape(candidate)) {
        candidate = PGSceneInterfaceOrientation();
        name = @"scene";
    }
    if (UIInterfaceOrientationIsLandscape(candidate)) {
        // InterfaceLandscapeRight = 底边在左、左边缘朝上。
        if (leftEdgeUp) *leftEdgeUp = (candidate == UIInterfaceOrientationLandscapeRight);
        if (source) *source = name;
        return YES;
    }

    if (source) *source = gravityFresh ? @"portrait" : @"none";
    return NO;
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

- (void)pollTick {
    self.pollTicks++;

    if (self.pollTicks % PGLandscapePreferenceRefreshTicks == 0) {
        PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
        [preferences reload];
        BOOL shouldBeActive = preferences.isEnabled && preferences.landscapeAlwaysOn;
        if (shouldBeActive != self.active) {
            PGLog(@"偏好自愈: active %d → %d", self.active, shouldBeActive);
            self.active = shouldBeActive;
            if (shouldBeActive) PGStartFBSObserver();
        }
    }
    if (self.active && !self.motionManager) {
        [self startMotionUpdatesIfNeeded];
    }

    [self refreshNow];

    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (preferences.debugAlertEnabled && self.pollTicks % PGLandscapeAlertTicks == 0) {
        PGPostDiagnosticAlert(@"PerfectGrabber 方向诊断", [self detailSnapshot]);
    } else if (self.active && self.pollTicks % PGLandscapeStatusLogTicks == 0) {
        PGLog(@"状态 %@", [self detailSnapshot]);
    }
}

- (void)refreshNow {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshNow];
        });
        return;
    }

    if (!self.active) {
        [self hideBar];
        [self logSnapshotShown:NO note:@"inactive"];
        return;
    }
    if (self.suspended) {
        [self hideBar];
        [self logSnapshotShown:NO note:@"suspended"];
        return;
    }

    BOOL leftEdgeUp = NO;
    NSString *source = @"-";
    BOOL landscape = [self resolveLandscape:&leftEdgeUp source:&source];
    self.resolvedSource = source;

    if (!landscape) {
        // 竖屏一律隐藏 —— 这是功能定义，不做"竖屏也常驻"的兼容。
        [self hideBar];
        [self logSnapshotShown:NO note:[@"portrait/" stringByAppendingString:source]];
        return;
    }

    // 位置纠错：万一把"哪一侧朝上"判反了，用户打开这个开关就能换到另一侧。
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (preferences.landscapeFlipSide) leftEdgeUp = !leftEdgeUp;

    [self showBarLeftEdgeUp:leftEdgeUp];
    [self logSnapshotShown:YES note:[@"show/" stringByAppendingString:source]];
}

- (NSString *)detailSnapshot {
    CFTimeInterval age = CACurrentMediaTime() - PGGravityTimestamp;
    NSString *gravity = PGGravityValid
        ? [NSString stringWithFormat:@"x=%.2f y=%.2f age=%.1fs 样本=%ld",
           PGGravityX, PGGravityY, age, (long)self.motionSamples]
        : [NSString stringWithFormat:@"无（尝试 %ld 次）", (long)self.motionAttempts];
    return [NSString stringWithFormat:
            @"重力: %@\n前台App: %ld\nFBS: %ld\n设备: %ld\n状态栏: %ld\n场景: %ld\n"
            @"判定: %@ | active=%d visible=%d\n窗口: %@ level=%.0f",
            gravity,
            (long)PGFrontMostAppOrientation(),
            (long)PGFBSCachedOrientation,
            (long)PGSpringBoardDeviceOrientation(),
            (long)PGSpringBoardInterfaceOrientation(),
            (long)PGSceneInterfaceOrientation(),
            self.resolvedSource ?: @"-", self.active, self.visible,
            self.window ? @"有" : @"无", self.window ? self.window.windowLevel : 0.0];
}

- (void)logSnapshotShown:(BOOL)shown note:(NSString *)note {
    NSString *snapshot = [NSString stringWithFormat:@"%d/%@", shown, note];
    if (self.lastSnapshot && [self.lastSnapshot isEqualToString:snapshot]) return;
    self.lastSnapshot = snapshot;
    PGLog(@"%@ | 显示=%d | %@", note, shown, [self detailSnapshot]);
}

#pragma mark 显示

- (void)showBarLeftEdgeUp:(BOOL)leftEdgeUp {
    if (![self ensureWindowAndSubviews]) return;
    if (!self.updating) {
        [self.bar startUpdating];
        self.updating = YES;
    }
    [self layoutBarLeftEdgeUp:leftEdgeUp];
    self.bar.hidden = NO;
    self.window.hidden = NO;
    [self.window bringSubviewToFront:self.bar];
    self.visible = YES;
}

- (BOOL)ensureWindowAndSubviews {
    if (self.window) return YES;

    // 坐标系恒为竖屏基准（SpringBoard 自己的窗口不跟随 App 旋转）。
    CGRect base = UIScreen.mainScreen.bounds;
    if (CGRectGetWidth(base) <= 0.0 || CGRectGetHeight(base) <= 0.0) return NO;

    UIWindowScene *scene = PGLandscapeHostScene();
    PGLandscapeBarWindow *window = nil;
    if (scene) {
        window = [[PGLandscapeBarWindow alloc] initWithWindowScene:scene];
    } else {
        window = [[PGLandscapeBarWindow alloc] initWithFrame:base];
    }
    if (!window) return NO;
    window.frame = base;
    // 必须远高于普通 App 窗口：全屏视频时前台 App 的层级很高。
    // 系统自带 HUD 都是这个量级，照抄才不会"窗口建好了但看不见"。
    window.windowLevel = UIWindowLevelAlert + 1000000.0;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;
    window.accessibilityElementsHidden = YES;
    window.hidden = YES;

    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = UIColor.clearColor;
    controller.view.userInteractionEnabled = NO;
    window.rootViewController = controller;

    PGLandscapeBarView *bar = [[PGLandscapeBarView alloc] initWithFrame:CGRectZero];
    bar.hidden = YES;
    [controller.view addSubview:bar];

    self.window = window;
    self.bar = bar;
    self.laidOut = NO;

    PGLog(@"窗口已创建: scene=%@ bounds=%.0fx%.0f level=%.0f",
          scene ? @"有" : @"无(legacy)",
          CGRectGetWidth(base), CGRectGetHeight(base), window.windowLevel);
    return YES;
}

- (void)layoutBarLeftEdgeUp:(BOOL)leftEdgeUp {
    CGRect screen = UIScreen.mainScreen.bounds;   // 恒竖屏基准：宽=水平，高=竖直
    CGFloat screenWidth = CGRectGetWidth(screen);
    CGFloat screenHeight = CGRectGetHeight(screen);
    if (screenWidth <= 0.0 || screenHeight <= 0.0) return;

    BOOL sameGeometry = self.laidOut &&
                        self.laidOutLeftEdgeUp == leftEdgeUp &&
                        fabs(self.laidOutScreenSize.width - screenWidth) < 0.5 &&
                        fabs(self.laidOutScreenSize.height - screenHeight) < 0.5;
    if (sameGeometry) return;

    // 横屏时胶囊沿"物理竖直方向"铺开，可用长度就是屏幕的高。
    CGFloat available = screenHeight - 2.0 * PGLandscapeBarEdgeInset - 24.0;
    CGSize size = [self.bar preferredContentSizeForMaxWidth:MAX(80.0, available)];
    CGFloat barLength = MIN(MAX(size.width, 44.0), MAX(available, 44.0));
    CGFloat barThickness = MAX(size.height, 20.0);

    self.window.frame = screen;

    // 直接旋转胶囊本身：绕自身中心转 90°，文字随之一起转，手机横过来读起来才是正的。
    self.bar.transform = CGAffineTransformIdentity;
    self.bar.bounds = CGRectMake(0.0, 0.0, barLength, barThickness);
    CGFloat centerX = leftEdgeUp ? (PGLandscapeBarEdgeInset + barThickness / 2.0)
                                 : (screenWidth - PGLandscapeBarEdgeInset - barThickness / 2.0);
    self.bar.center = CGPointMake(centerX, screenHeight / 2.0);
    self.bar.transform = CGAffineTransformMakeRotation(leftEdgeUp ? -M_PI_2 : M_PI_2);

    self.laidOut = YES;
    self.laidOutLeftEdgeUp = leftEdgeUp;
    self.laidOutScreenSize = CGSizeMake(screenWidth, screenHeight);

    PGLog(@"排版: 左侧朝上=%d 屏=%.0fx%.0f 胶囊=%.0fx%.0f 中心=(%.0f,%.0f)",
          leftEdgeUp, screenWidth, screenHeight, barLength, barThickness, centerX, screenHeight / 2.0);
}

- (void)hideBar {
    if (self.updating) {
        [self.bar stopUpdating];
        self.updating = NO;
    }
    self.bar.hidden = YES;
    self.window.hidden = YES;
    self.laidOut = NO;
    self.visible = NO;
}

- (void)teardownWindow {
    if (self.updating) {
        [self.bar stopUpdating];
        self.updating = NO;
    }
    self.window.hidden = YES;
    self.window.rootViewController = nil;
    self.window = nil;
    self.bar = nil;
    self.laidOut = NO;
    self.visible = NO;
}

@end

#pragma mark - 跨线程刷新入口

static void PGRequestRefresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [PGLandscapeBar.sharedBar refreshNow];
    });
}
