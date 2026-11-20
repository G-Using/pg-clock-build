#import "PGGrabberLandscapeBar.h"
#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"
#import <QuartzCore/QuartzCore.h>
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
    UIWindowScene *fallback = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) return windowScene;
        if (!fallback) fallback = windowScene;
    }
    if (fallback) return fallback;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in application.windows) {
        if (window.windowScene) return window.windowScene;
    }
#pragma clang diagnostic pop
    return nil;
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

/// 返回当前应采用的界面方向。只有确认横屏才返回横屏，竖屏（含旋转途中）立即判定为竖屏。
static UIInterfaceOrientation PGResolvedLandscapeOrientation(void) {
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
@property (nonatomic, assign) UIInterfaceOrientation laidOutOrientation;
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
        [self hideBar];
        return;
    }
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
    if (self.window && scene && self.window.windowScene != scene) [self teardownWindow];
    if (self.window) return YES;

    // 优先挂到 SpringBoard 自己的窗口场景；拿不到场景时退化为整屏窗口，至少保证不静默失效。
    PGLandscapeBarWindow *window = scene ? [[PGLandscapeBarWindow alloc] initWithWindowScene:scene]
                                         : [[PGLandscapeBarWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.frame = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
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
    CGFloat landscapeWidth = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat landscapeHeight = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    if (landscapeWidth <= 0.0 || landscapeHeight <= 0.0) return;

    BOOL sizeUnchanged = CGRectGetWidth(self.rotator.bounds) == landscapeWidth &&
                         CGRectGetHeight(self.rotator.bounds) == landscapeHeight;
    if (self.laidOutOrientation == orientation && sizeUnchanged) return;

    self.rotator.bounds = CGRectMake(0.0, 0.0, landscapeWidth, landscapeHeight);
    self.rotator.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));

    // SpringBoard 自己的窗口不跟着应用转，所以把整块内容反向补偿旋转，人眼看到才是正的。
    // LandscapeLeft = 用户视角的“上”落在物理左边，因此逆时针转 90°。
    BOOL leftEdgeUp = orientation == UIInterfaceOrientationLandscapeLeft;
    self.rotator.transform = CGAffineTransformMakeRotation(leftEdgeUp ? -M_PI_2 : M_PI_2);

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
