#import "PGGrabberLandscapeBar.h"
#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"
#import <QuartzCore/QuartzCore.h>
#import <CoreMotion/CoreMotion.h>
#import <math.h>

/// 横屏块距屏幕顶边的距离（横屏下的顶边是物理侧边，没有刘海，给一点留白即可）。
static const CGFloat PGLandscapeBarTopInset = 6.0;

/// 轮询间隔。方向变化没有可靠且单一的公开通知可依赖，轮询只做两次属性比较，开销可忽略。
static const NSTimeInterval PGLandscapePollInterval = 0.5;

/// 状态栏方向没跟上时，用设备方向补判，必须连续确认这么久才认，避免旋转过程中来回闪。
static const CFTimeInterval PGLandscapeConfirmDelay = 1.0;

#pragma mark - 私有接口

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
    // 基类在启用背景色时只圆下面两个角（它贴着屏幕顶边），横屏胶囊要四个角都圆。
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

#pragma mark - 方向判定

static UIWindowScene *PGLandscapeHostScene(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindowScene *landscapeFallback = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        // 只收"坐标系以竖屏为基准"的场景（SpringBoard 主屏）。视频/游戏全屏横屏时，
        // 前台那个场景的坐标系本身已经是横的，在它上面再套旋转补偿会把块推到屏幕外。
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

/// 横屏判定专用：只要有任何场景（含视频 App 那个）处于横屏就算横屏。
/// 这是最可靠的信号 —— statusBarOrientation 在视频全屏时常常仍停在竖屏，
/// UIDevice.orientation 在 SpringBoard 进程里也不可信。
static UIInterfaceOrientation PGSceneLandscapeOrientation(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) continue;
        UIInterfaceOrientation orientation = windowScene.interfaceOrientation;
        if (UIInterfaceOrientationIsLandscape(orientation)) return orientation;
    }
    return UIInterfaceOrientationUnknown;
}

static UIInterfaceOrientation PGSpringBoardInterfaceOrientation(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (![application respondsToSelector:@selector(statusBarOrientation)]) return UIInterfaceOrientationUnknown;
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

static CFTimeInterval PGLandscapeCandidateSince = 0.0;

/// 加速度计给出的重力 x 分量。横屏看视频时状态栏是隐藏的（statusBarOrientation 停在竖屏），
/// SpringBoard 的 connectedScenes 又看不到视频 App 的场景，唯一可靠的依据只剩"哪边朝上"。
static CGFloat PGLandscapeGravityX = 0.0;
static BOOL PGLandscapeGravityValid = NO;

/// 约 33° 以上的横置才认为是横屏，避免握持角度抖动导致块乱闪。
static const CGFloat PGLandscapeGravityThreshold = 0.55;

/// 返回当前应采用的界面方向。只有确认横屏才返回横屏，竖屏（含旋转途中）立即判定为竖屏。
static UIInterfaceOrientation PGResolvedLandscapeOrientation(void) {
    // 1) 重力方向优先。
    if (PGLandscapeGravityValid) {
        PGLandscapeCandidateSince = 0.0;
        if (PGLandscapeGravityX <= -PGLandscapeGravityThreshold) {
            // 设备左侧朝上（Home 键在右）= UIInterfaceOrientationLandscapeLeft，旋转 -90°。
            return UIInterfaceOrientationLandscapeLeft;
        }
        if (PGLandscapeGravityX >= PGLandscapeGravityThreshold) {
            // 设备右侧朝上（Home 键在左）= UIInterfaceOrientationLandscapeRight，旋转 +90°。
            return UIInterfaceOrientationLandscapeRight;
        }
        // 手机物理上还是竖着的（哪怕视频画面被 App 强制转成横屏），不显示常驻块。
        return UIInterfaceOrientationPortrait;
    }

    // 2) 加速度计不可用时退回场景/状态栏方向。
    UIInterfaceOrientation sceneLandscape = PGSceneLandscapeOrientation();
    if (UIInterfaceOrientationIsLandscape(sceneLandscape)) {
        PGLandscapeCandidateSince = 0.0;
        return sceneLandscape;
    }

    UIInterfaceOrientation statusBar = PGSpringBoardInterfaceOrientation();
    if (UIInterfaceOrientationIsLandscape(statusBar)) {
        PGLandscapeCandidateSince = 0.0;
        return statusBar;
    }

    UIDevice *device = UIDevice.currentDevice;
    if (!device.isGeneratingDeviceOrientationNotifications) [device beginGeneratingDeviceOrientationNotifications];
    UIInterfaceOrientation deviceInterface = PGInterfaceOrientationFromDevice(device.orientation);
    if (!UIInterfaceOrientationIsLandscape(deviceInterface)) {
        PGLandscapeCandidateSince = 0.0;
        return UIInterfaceOrientationPortrait;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (PGLandscapeCandidateSince <= 0.0) PGLandscapeCandidateSince = now;
    if (now - PGLandscapeCandidateSince < PGLandscapeConfirmDelay) return UIInterfaceOrientationPortrait;
    return deviceInterface;
}

#pragma mark - 横屏常驻块

@interface PGLandscapeBar ()

@property (nonatomic, strong, nullable) PGLandscapeBarWindow *window;
@property (nonatomic, strong, nullable) UIView *rotator;
@property (nonatomic, strong, nullable) PGLandscapeBarView *bar;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) CMMotionManager *motionManager;
@property (nonatomic, assign) UIInterfaceOrientation laidOutOrientation;
/// 承载窗口所在场景的坐标系是否以竖屏为基准。是才需要反向旋转补偿。
@property (nonatomic, assign) BOOL hostPortraitBase;
@property (nonatomic, assign) BOOL updating;
@property (nonatomic, assign) BOOL suspended;
@property (nonatomic, assign) BOOL active;

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
}

#pragma mark 对外入口

- (void)reloadPreferences {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadPreferences];
        });
        return;
    }

    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    self.active = preferences.isEnabled && preferences.landscapeAlwaysOn;
    // 设置可能改了字号/配色，强制下一次重新排版。
    self.laidOutOrientation = UIInterfaceOrientationUnknown;

    if (!self.active) {
        [self stopPolling];
        [self stopMotionUpdates];
        [self hideBar];
        return;
    }
    [self startMotionUpdatesIfNeeded];
    [self startPolling];
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
    if (suspended) {
        [self hideBar];
        return;
    }
    [self refreshNow];
}

#pragma mark 重力方向

- (void)startMotionUpdatesIfNeeded {
    if (self.motionManager) return;
    CMMotionManager *manager = [CMMotionManager new];
    if (!manager.isAccelerometerAvailable) {
        // 拿不到加速度计时退回场景/状态栏判定，至少不会完全失效。
        PGLandscapeGravityValid = NO;
        return;
    }
    manager.accelerometerUpdateInterval = 0.25;
    self.motionManager = manager;
    [manager startAccelerometerUpdatesToQueue:NSOperationQueue.mainQueue
                                  withHandler:^(CMAccelerometerData *data, NSError *error) {
        if (!data) return;
        PGLandscapeGravityX = data.acceleration.x;
        PGLandscapeGravityValid = YES;
    }];
}

- (void)stopMotionUpdates {
    [self.motionManager stopAccelerometerUpdates];
    self.motionManager = nil;
    PGLandscapeGravityValid = NO;
}

#pragma mark 轮询

- (void)startPolling {
    if (self.pollTimer) return;
    NSTimer *timer = [NSTimer timerWithTimeInterval:PGLandscapePollInterval
                                             target:self
                                           selector:@selector(refreshNow)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.pollTimer = timer;
}

- (void)stopPolling {
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

- (void)refreshNow {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshNow];
        });
        return;
    }

    if (!self.active || self.suspended) {
        [self hideBar];
        return;
    }

    UIInterfaceOrientation orientation = PGResolvedLandscapeOrientation();
    if (!UIInterfaceOrientationIsLandscape(orientation)) {
        [self hideBar];
        return;
    }
    [self showBarForOrientation:orientation];
}

#pragma mark 显示

- (void)showBarForOrientation:(UIInterfaceOrientation)orientation {
    if (![self ensureWindowAndSubviews]) return;
    [self layoutBarForOrientation:orientation];
    if (!self.updating) {
        [self.bar startUpdating];
        self.updating = YES;
    }
    self.bar.hidden = NO;
    self.window.hidden = NO;
}

- (BOOL)ensureWindowAndSubviews {
    UIWindowScene *scene = PGLandscapeHostScene();
    if (!scene) return NO;
    if (self.window && self.window.windowScene != scene) [self teardownWindow];
    if (self.window) return YES;

    // 场景若是竖屏基准（SpringBoard 主屏），屏幕尺寸取 UIScreen（恒为竖屏基准，430x932 这种），
    // 再靠旋转补偿把内容摆正；场景本身已横屏时则直接用它的坐标系，不再补偿。
    self.hostPortraitBase = !UIInterfaceOrientationIsLandscape(scene.interfaceOrientation);
    CGRect base = self.hostPortraitBase ? UIScreen.mainScreen.bounds : scene.coordinateSpace.bounds;
    if (CGRectGetWidth(base) <= 0.0 || CGRectGetHeight(base) <= 0.0) base = UIScreen.mainScreen.bounds;

    PGLandscapeBarWindow *window = [[PGLandscapeBarWindow alloc] initWithWindowScene:scene];
    window.frame = base;
    window.windowLevel = UIWindowLevelAlert + 1.0;
    window.backgroundColor = UIColor.clearColor;
    window.userInteractionEnabled = NO;
    window.accessibilityElementsHidden = YES;
    window.hidden = YES;

    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.clearColor;
    controller.view.userInteractionEnabled = NO;
    window.rootViewController = controller;

    UIView *rotator = [UIView new];
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
    return YES;
}

- (void)layoutBarForOrientation:(UIInterfaceOrientation)orientation {
    CGRect bounds = self.window.bounds;
    CGFloat landscapeWidth = 0.0;
    CGFloat landscapeHeight = 0.0;
    if (self.hostPortraitBase) {
        // 竖屏基准坐标系：内容按横屏尺寸排版，再整体旋转 90° 铺回竖屏。
        landscapeWidth = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
        landscapeHeight = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    } else {
        // 场景自身已是横屏坐标系，直接铺满，不能再旋转。
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
