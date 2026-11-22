#import "PGGrabberLandscapeBar.h"
#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreMotion/CoreMotion.h>
#import <math.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <time.h>

#pragma mark - 常量

/// 胶囊离物理侧边（用户视角的顶边）的距离。
static const CGFloat PGLandscapeBarEdgeInset = 6.0;

/// 轮询间隔。方向变化没有可靠且单一的公开通知可依赖，轮询只做几次浮点比较，开销可忽略。
static const NSTimeInterval PGLandscapePollInterval = 0.4;

/// 每多少次轮询重读一次偏好。tweak 在 dyld 早期加载时 CFPreferences 可能还没同步到最新值，
/// 一旦 active 被算成 NO 又没人再发设置变更通知，常驻块就会永久不显示 —— 必须能自愈。
static const NSInteger PGLandscapePreferenceRefreshTicks = 12;

/// 进入 / 退出横屏的重力阈值（带滞回，避免握持在临界角度时块疯狂闪）。
static const double PGLandscapeEnterThreshold = 0.55;   // 约 33°
static const double PGLandscapeExitThreshold = 0.42;    // 约 25°

/// 加速度计样本的有效期。超过这个时间没有新样本就认为运动服务停摆，改用兜底来源。
static const CFTimeInterval PGLandscapeGravityMaxAge = 2.0;

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

#pragma mark - 物理姿态状态

/// 加速度计的重力分量（设备坐标系，单位 g）。多处跨线程读写；
/// double / CFTimeInterval 是 8 字节对齐的标量，读写本身原子，配合"是否新鲜"判断足够安全。
static volatile double PGGravityX = 0.0;
static volatile double PGGravityY = 0.0;
static volatile CFTimeInterval PGGravityTimestamp = 0.0;
static volatile BOOL PGGravityValid = NO;

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

#pragma mark - 视图与窗口

/// 复用的样式方法，定义在 PGGrabberOverlayView.m 内。
@interface PGGrabberOverlayView (PGLandscapeStyle)
- (void)applyAppearance;
@end

/// 复用下拉覆盖层的排版与配色，四角都是圆角：它是浮在画面上的胶囊，不贴着屏幕边缘。
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

#pragma mark - 横屏常驻块

@interface PGLandscapeBar ()

@property (nonatomic, strong, nullable) PGLandscapeBarWindow *window;
@property (nonatomic, strong, nullable) PGLandscapeBarView *bar;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) NSTimer *suspendTimer;
@property (nonatomic, strong, nullable) CMMotionManager *motionManager;
@property (nonatomic, strong, nullable) NSOperationQueue *motionQueue;
@property (nonatomic, assign) BOOL motionUnavailable;
@property (nonatomic, assign) BOOL updating;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) NSInteger pollTicks;
/// 已按"哪一侧朝上"排版过，且当时记录的屏幕尺寸与朝向都一致，才跳过重复排版。
@property (nonatomic, assign) BOOL laidOut;
@property (nonatomic, assign) BOOL laidOutLeftEdgeUp;
@property (nonatomic, assign) CGSize laidOutScreenSize;
/// 当前是否正显示（用于重力阈值的滞回判断）。
@property (nonatomic, assign) BOOL visible;
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

- (void)dealloc {
    [_pollTimer invalidate];
    [_motionManager stopAccelerometerUpdates];
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
    self.laidOut = NO;
    // 设置变更是一次干净的重新开始：清掉可能残留的暂停标记和计时器。
    [self.suspendTimer invalidate];
    self.suspendTimer = nil;
    self.suspended = NO;

    PGLog(@"reload: enabled=%d landscapeAlwaysOn=%d → active=%d",
          preferences.isEnabled, preferences.landscapeAlwaysOn, self.active);

    if (self.active) {
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

#pragma mark 物理姿态

- (void)startMotionUpdatesIfNeeded {
    if (self.motionManager || self.motionUnavailable) return;
    CMMotionManager *manager = [[CMMotionManager alloc] init];
    if (!manager.accelerometerAvailable) {
        self.motionUnavailable = YES;
        PGLog(@"CoreMotion: 加速度计不可用");
        return;
    }
    manager.accelerometerUpdateInterval = 0.1;
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
        PGGravityY = data.acceleration.y;
        PGGravityTimestamp = CACurrentMediaTime();
        PGGravityValid = YES;
        samples++;
        if (samples == 1) PGLog(@"CoreMotion: 首个样本 x=%.3f y=%.3f z=%.3f",
                                data.acceleration.x, data.acceleration.y, data.acceleration.z);
    }];
}

/// 判断当前是否横屏，并给出"哪一侧边朝上"。
/// 只用物理姿态：加速度计重力 > UIDevice 方向（两者都是物理来源）。
/// 状态栏 / 场景方向在这里一律不用 —— 视频全屏时它们都停在竖屏，用了反而会互相拆台。
- (BOOL)resolveLeftEdgeUp:(BOOL *)leftEdgeUp {
    CFTimeInterval age = CACurrentMediaTime() - PGGravityTimestamp;
    if (PGGravityValid && age >= 0.0 && age < PGLandscapeGravityMaxAge) {
        double x = PGGravityX;
        // 滞回：已经在显示时用更低的退出阈值，避免握在临界角度上疯狂闪。
        double threshold = self.visible ? PGLandscapeExitThreshold : PGLandscapeEnterThreshold;
        // 坐标约定（设备坐标系，竖屏时 +x 向右、+y 向下）：
        // 手机顺时针转 90°（右边缘朝下、左边缘朝上），重力在 +x 上有正分量 → x ≥ +阈值。
        if (x >= threshold) {
            if (leftEdgeUp) *leftEdgeUp = YES;
            return YES;
        }
        if (x <= -threshold) {
            if (leftEdgeUp) *leftEdgeUp = NO;
            return YES;
        }
        return NO;
    }

    // 运动服务没数据时，用 UIDevice 的物理姿态兜底。
    UIDevice *device = UIDevice.currentDevice;
    if (!device.isGeneratingDeviceOrientationNotifications) {
        [device beginGeneratingDeviceOrientationNotifications];
    }
    switch (device.orientation) {
        case UIDeviceOrientationLandscapeLeft:
            // 底边（Home / 手势条）在右侧 → 右边缘朝上。
            if (leftEdgeUp) *leftEdgeUp = NO;
            return YES;
        case UIDeviceOrientationLandscapeRight:
            if (leftEdgeUp) *leftEdgeUp = YES;
            return YES;
        default:
            return NO;
    }
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
            if (shouldBeActive) [self startMotionUpdatesIfNeeded];
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

    if (!self.active) {
        [self hideBar];
        [self logSnapshotLandscape:NO leftEdgeUp:NO shown:NO note:@"inactive"];
        return;
    }
    if (self.suspended) {
        [self hideBar];
        [self logSnapshotLandscape:NO leftEdgeUp:NO shown:NO note:@"suspended"];
        return;
    }

    BOOL leftEdgeUp = NO;
    BOOL landscape = [self resolveLeftEdgeUp:&leftEdgeUp];
    if (!landscape) {
        // 竖屏一律隐藏：这是这个功能的定义，不做"竖屏也常驻"的兼容。
        [self hideBar];
        [self logSnapshotLandscape:NO leftEdgeUp:NO shown:NO note:@"portrait-hide"];
        return;
    }

    [self showBarLeftEdgeUp:leftEdgeUp];
    [self logSnapshotLandscape:YES leftEdgeUp:leftEdgeUp shown:YES note:@"show"];
}

- (void)logSnapshotLandscape:(BOOL)landscape
                  leftEdgeUp:(BOOL)leftEdgeUp
                      shown:(BOOL)shown
                       note:(NSString *)note {
    NSString *snapshot = [NSString stringWithFormat:@"%d/%d/%d/%@", landscape, leftEdgeUp, shown, note];
    if (self.lastSnapshot && [self.lastSnapshot isEqualToString:snapshot]) return;
    self.lastSnapshot = snapshot;

    CFTimeInterval age = CACurrentMediaTime() - PGGravityTimestamp;
    NSString *gravity = PGGravityValid
        ? [NSString stringWithFormat:@"x=%.2f y=%.2f age=%.1fs", PGGravityX, PGGravityY, age]
        : @"n/a";
    PGLog(@"%@ | 横屏=%d 左侧朝上=%d 显示=%d | %@ | 窗口=%@ level=%.0f",
          note, landscape, leftEdgeUp, shown, gravity,
          self.window ? @"有" : @"无", self.window ? self.window.windowLevel : 0.0);
}

#pragma mark 显示

- (void)showBarLeftEdgeUp:(BOOL)leftEdgeUp {
    if (![self ensureWindowAndSubviews]) return;
    // 先启动更新把文字填好，再排版，否则第一次量出来的宽度是空的。
    if (!self.updating) {
        [self.bar startUpdating];
        self.updating = YES;
    }
    [self layoutBarLeftEdgeUp:leftEdgeUp];
    self.bar.hidden = NO;
    self.window.hidden = NO;
    self.visible = YES;
}

- (BOOL)ensureWindowAndSubviews {
    // 窗口一次建好就不再重建：反复 teardown/重建只会在横竖切换时闪断。
    if (self.window) return YES;

    // 坐标系恒为竖屏基准（SpringBoard 自己的窗口不跟随 App 旋转）。
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

    // 横屏时胶囊沿"物理竖直方向"铺开，可用长度就是屏幕的高（932 一类）。
    CGFloat available = screenHeight - 2.0 * PGLandscapeBarEdgeInset - 24.0;
    CGSize size = [self.bar preferredContentSizeForMaxWidth:MAX(80.0, available)];
    CGFloat barLength = MIN(MAX(size.width, 44.0), MAX(available, 44.0));
    CGFloat barThickness = MAX(size.height, 20.0);

    self.window.frame = screen;

    // 直接旋转胶囊本身（不再套一层大画布）：绕自身中心转 90°，
    // 文字随之一起转，手机横过来时读起来才是正的。
    self.bar.transform = CGAffineTransformIdentity;
    self.bar.bounds = CGRectMake(0.0, 0.0, barLength, barThickness);
    // 左边缘朝上 → 贴屏幕左边；右边缘朝上 → 贴屏幕右边。
    CGFloat centerX = leftEdgeUp ? (PGLandscapeBarEdgeInset + barThickness / 2.0)
                                 : (screenWidth - PGLandscapeBarEdgeInset - barThickness / 2.0);
    self.bar.center = CGPointMake(centerX, screenHeight / 2.0);
    self.bar.transform = CGAffineTransformMakeRotation(leftEdgeUp ? -M_PI_2 : M_PI_2);

    self.laidOut = YES;
    self.laidOutLeftEdgeUp = leftEdgeUp;
    self.laidOutScreenSize = CGSizeMake(screenWidth, screenHeight);

    PGLog(@"排版: 左朝上=%d 屏=%.0fx%.0f 胶囊=%.0fx%.0f 中心=(%.0f,%.0f)",
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
}

@end
