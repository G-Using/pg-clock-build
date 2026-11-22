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

/// 进入 / 退出横屏的重力阈值（带滞回，避免握持在临界角度时块疯狂闪）。
static const double PGLandscapeEnterThreshold = 0.55;   // 约 33°
static const double PGLandscapeExitThreshold = 0.42;    // 约 25°

/// 重力"明确竖着"的判定线：低于它就强制竖屏，不让软件来源把块拽成歪的。
static const double PGLandscapePortraitVeto = 0.30;

/// 加速度计样本有效期。超过这个时间没有新样本就认为运动服务没工作，改用软件来源。
static const CFTimeInterval PGLandscapeGravityMaxAge = 2.0;

/// 判定为横屏后，先等这么久再显示。旋转过程中窗口坐标系正在翻转，此时立刻画出来会"闪一下"。
static const CFTimeInterval PGLandscapeShowDelay = 0.15;

/// 显示淡入时长，避免胶囊硬生生"啪"一下出现。
static const NSTimeInterval PGLandscapeFadeInDuration = 0.14;

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

/// 承载胶囊的容器。窗口尺寸一变（旋转）UIKit 就会同步回调 layoutSubviews，
/// 胶囊在旋转动画的每一帧都贴在正确的边上，不会出现"先错位、等下一次轮询才跳回来"的闪动。
@class PGLandscapeBar;

@interface PGLandscapeBar (PGPlacement)
- (void)placeBarInBounds:(CGRect)bounds;
@end

@interface PGLandscapeHostView : UIView
@property (nonatomic, weak, nullable) PGLandscapeBar *bar;
@end

@implementation PGLandscapeHostView

- (void)layoutSubviews {
    [super layoutSubviews];
    [self.bar placeBarInBounds:self.bounds];
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

#pragma mark - 诊断弹窗已移除
// 方向判定已经用真机日志验证过（重力 x=-0.65、样本充足、判定正确），
// 那个每 5 秒弹出的系统提示框只会挡住画面，整块删掉。诊断信息仍然写 /var/mobile/Media/PerfectGrabber.log。

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
/// 上次排版是不是"贴顶边"（否则贴底边）。用于判断是否需要重排。
@property (nonatomic, assign) BOOL laidOutAnchorAtTop;
@property (nonatomic, assign) CGSize laidOutScreenSize;
/// 当前胶囊尺寸。量一次缓存起来，旋转动画期间每帧重排只做几何计算，不重复量文字。
@property (nonatomic, assign) CGFloat barLength;
@property (nonatomic, assign) CGFloat barThickness;
/// 当前"哪一侧长边朝上"。容器 layoutSubviews 重排时用它，不必重新读重力。
@property (nonatomic, assign) BOOL anchorLeftEdgeUp;
/// 进入横屏的时间戳，用于"稳定 150ms 再显示"。
@property (nonatomic, assign) CFTimeInterval landscapeSince;
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

    PGLog(@"reload: enabled=%d landscapeAlwaysOn=%d → active=%d",
          preferences.isEnabled, preferences.landscapeAlwaysOn, self.active);

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

        // 姿态一旦跨过阈值就立刻重算，不必等 0.4s 轮询 —— 手机转到位后胶囊马上归位。
        static volatile int lastPose = 0;
        int pose = lastPose;
        if (data.acceleration.x >= PGLandscapeEnterThreshold) pose = 1;
        else if (data.acceleration.x <= -PGLandscapeEnterThreshold) pose = -1;
        else if (fabs(data.acceleration.x) < PGLandscapePortraitVeto) pose = 0;
        if (pose != lastPose) {
            lastPose = pose;
            PGRequestRefresh();
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

    if (self.active && self.pollTicks % PGLandscapeStatusLogTicks == 0) {
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
        self.landscapeSince = 0.0;
        [self hideBar];
        [self logSnapshotShown:NO note:[@"portrait/" stringByAppendingString:source]];
        return;
    }

    // 刚转过来时窗口坐标系还在翻转，等方向稳定一小会儿再画，避免闪一下。
    CFTimeInterval now = CACurrentMediaTime();
    if (self.landscapeSince <= 0.0) self.landscapeSince = now;
    if (!self.visible && now - self.landscapeSince < PGLandscapeShowDelay) return;

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
    self.anchorLeftEdgeUp = leftEdgeUp;
    [self layoutBarLeftEdgeUp:leftEdgeUp];
    self.window.hidden = NO;

    if (!self.visible) {
        // 淡入而不是"啪"一下出现，旋转刚结束时观感更干净。
        self.bar.hidden = NO;
        self.bar.alpha = 0.0;
        [UIView animateWithDuration:PGLandscapeFadeInDuration
                              delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.bar.alpha = 1.0;
        } completion:nil];
    }
    self.visible = YES;
}

- (BOOL)ensureWindowAndSubviews {
    if (self.window) return YES;

    // 只用来做一次合法性检查；实际排版尺寸一律读 window.bounds（横竖屏由系统改写）。
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
    // 不要手动设 frame：场景窗口的 frame 由系统维护，横竖屏切换时会被自动改成 932x430 / 430x932，
    // 手动写成竖屏尺寸会把胶囊算到屏幕外。
    if (!scene) window.frame = base;
    // 必须远高于普通 App 窗口：全屏视频时前台 App 的层级很高。
    // 系统自带 HUD 都是这个量级，照抄才不会"窗口建好了但看不见"。
    window.windowLevel = UIWindowLevelAlert + 1000000.0;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;
    window.accessibilityElementsHidden = YES;
    window.hidden = YES;

    // 根视图换成自定义容器：它随窗口一起变尺寸，旋转动画每一帧都会回调 layoutSubviews 重排胶囊。
    PGLandscapeHostView *host = [[PGLandscapeHostView alloc] initWithFrame:window.bounds];
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    host.backgroundColor = UIColor.clearColor;
    host.userInteractionEnabled = NO;
    host.bar = self;

    UIViewController *controller = [[UIViewController alloc] init];
    controller.view = host;
    window.rootViewController = controller;

    PGLandscapeBarView *bar = [[PGLandscapeBarView alloc] initWithFrame:CGRectZero];
    bar.hidden = YES;
    [host addSubview:bar];

    self.window = window;
    self.bar = bar;
    self.laidOut = NO;
    self.barLength = 0.0;
    self.barThickness = 0.0;

    PGLog(@"窗口已创建: scene=%@ bounds=%.0fx%.0f level=%.0f",
          scene ? @"有" : @"无(legacy)",
          CGRectGetWidth(base), CGRectGetHeight(base), window.windowLevel);
    return YES;
}

- (void)layoutBarLeftEdgeUp:(BOOL)leftEdgeUp {
    if (!self.window || !self.bar) return;

    CGRect space = self.window.bounds;
    CGFloat spaceWidth = CGRectGetWidth(space);
    CGFloat spaceHeight = CGRectGetHeight(space);
    if (spaceWidth <= 0.0 || spaceHeight <= 0.0) return;

    BOOL landscapeSpace = spaceWidth > spaceHeight;      // 窗口已按横屏铺开

    BOOL sameGeometry = self.laidOut &&
                        self.barLength > 0.0 &&
                        self.laidOutLeftEdgeUp == leftEdgeUp &&
                        fabs(self.laidOutScreenSize.width - spaceWidth) < 0.5 &&
                        fabs(self.laidOutScreenSize.height - spaceHeight) < 0.5;
    if (sameGeometry) {
        // 尺寸没变，只按当前窗口重新摆一次位置（旋转动画中每帧都会走到这里）。
        [self placeBarInBounds:space];
        return;
    }

    // 胶囊的长轴沿着窗口的长边铺开，可用长度取长边。
    CGFloat inset = PGLandscapeBarEdgeInset;
    CGFloat available = (landscapeSpace ? spaceWidth : spaceHeight) - 2.0 * inset - 24.0;
    CGSize size = [self.bar preferredContentSizeForMaxWidth:MAX(80.0, available)];
    self.barLength = MIN(MAX(size.width, 44.0), MAX(available, 44.0));
    self.barThickness = MAX(size.height, 20.0);

    self.laidOut = YES;
    self.laidOutLeftEdgeUp = leftEdgeUp;
    self.laidOutScreenSize = CGSizeMake(spaceWidth, spaceHeight);

    [self placeBarInBounds:space];

    PGLog(@"排版: 横屏空间=%d 左边缘朝上=%d 空间=%.0fx%.0f 胶囊=%.0fx%.0f",
          landscapeSpace, leftEdgeUp, spaceWidth, spaceHeight, self.barLength, self.barThickness);
}

/// 只做几何摆放：横屏空间贴顶边居中；万一窗口仍是竖屏基准，就贴"物理朝上"的那条长边并旋转 90°。
/// 两种分支在同一物理姿态下看起来是同一个位置，所以旋转过程中切换分支不会跳。
- (void)placeBarInBounds:(CGRect)space {
    if (!self.bar || self.barLength <= 0.0 || self.barThickness <= 0.0) return;
    CGFloat spaceWidth = CGRectGetWidth(space);
    CGFloat spaceHeight = CGRectGetHeight(space);
    if (spaceWidth <= 0.0 || spaceHeight <= 0.0) return;

    CGFloat inset = PGLandscapeBarEdgeInset;
    self.bar.transform = CGAffineTransformIdentity;
    self.bar.bounds = CGRectMake(0.0, 0.0, self.barLength, self.barThickness);

    if (spaceWidth > spaceHeight) {
        // 横屏坐标系：y=0 那条边就是用户视角的顶边，胶囊横着躺、居中。
        self.bar.center = CGPointMake(spaceWidth / 2.0, inset + self.barThickness / 2.0);
    } else {
        // 竖屏坐标系（旋转未能同步到这里时）：用户视角的顶边是左右两条长边，胶囊旋转 90° 贴上去。
        BOOL leftSide = self.anchorLeftEdgeUp;
        CGFloat centerX = leftSide ? (inset + self.barThickness / 2.0)
                                   : (spaceWidth - inset - self.barThickness / 2.0);
        self.bar.center = CGPointMake(centerX, spaceHeight / 2.0);
        self.bar.transform = CGAffineTransformMakeRotation(leftSide ? -M_PI_2 : M_PI_2);
    }
}

- (void)hideBar {
    if (self.updating) {
        [self.bar stopUpdating];
        self.updating = NO;
    }
    [self.bar.layer removeAllAnimations];
    self.bar.alpha = 1.0;
    self.bar.hidden = YES;
    self.window.hidden = YES;
    self.laidOut = NO;
    self.visible = NO;
    self.landscapeSince = 0.0;
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
