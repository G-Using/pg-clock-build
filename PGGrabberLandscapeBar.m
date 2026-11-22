#import "PGGrabberLandscapeBar.h"
#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"
#import "PGNowPlaying.h"
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <math.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <time.h>

#pragma mark - 常量

/// 胶囊离物理侧边（用户视角的顶边）的距离。
static const CGFloat PGLandscapeBarEdgeInset = 6.0;

/// 轮询间隔。方向变化没有可靠且单一的公开通知可依赖，轮询只做几次属性比较，开销可忽略。
/// 0.25 秒是为了配合"竖屏确认 0.3 秒才收起"的防抖：转回竖屏后约 0.5 秒内就能藏掉。
static const NSTimeInterval PGLandscapePollInterval = 0.25;

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

/// 竖屏要连续确认这么久才收起。方向来源在切前台 / App 切换的瞬间会有一两次瞬时失准，
/// 一失准就立刻藏、下一拍又显 —— 表现就是"一直闪"。宁可慢半拍藏，也不能闪。
static const CFTimeInterval PGLandscapeHideDelay = 0.30;

/// 收起后至少隔这么久才允许再次显示，避免"藏了又显"的抖动。
static const CFTimeInterval PGLandscapeReshowDelay = 0.40;

/// 显示后至少保持这么久，期间方向抖动不收起。
static const CFTimeInterval PGLandscapeMinVisible = 0.60;

/// 音乐区（歌名那一段）的显示 / 隐藏要先稳定这么久才生效。
/// 正在播放的探针在切前台、App 切换、锁屏时会有一两次失准，宽度跟着来回跳就是闪。
static const CFTimeInterval PGLandscapeMusicDebounce = 0.80;

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

/// 其它编译单元（PGNowPlaying）复用同一份日志文件。
void PGDebugLog(NSString *format, ...) {
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
        // 横屏块恒单排：时间、电量、（音乐）全在一条线上。
        self.forceSingleLine = YES;
        // 需要接受点按（点一下弹播放控制面板），子标签自己不拦触摸。
        self.userInteractionEnabled = YES;
    }
    return self;
}

- (void)applyAppearance {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    self.backgroundOverrideColor = preferences.landscapeCustomBackground
        ? preferences.landscapeBackgroundColor
        : nil;
    [super applyAppearance];
    self.layer.cornerRadius = 10.0;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                               kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
}

@end

#pragma mark - 播放控制面板

/// 点一下胶囊弹出来的播放面板：毛玻璃卡片 + 封面 + 歌名/歌手 + 进度条 + 上一首/播放暂停/下一首。
@interface PGLandscapeControlPanel : UIView
@property (nonatomic, copy, nullable) void (^onPrevious)(void);
@property (nonatomic, copy, nullable) void (^onToggle)(void);
@property (nonatomic, copy, nullable) void (^onNext)(void);
@property (nonatomic, copy, nullable) void (^onOpenApplication)(void);
- (void)updateTitle:(nullable NSString *)title
             artist:(nullable NSString *)artist
            playing:(BOOL)playing
            elapsed:(double)elapsed
           duration:(double)duration
        artworkData:(nullable NSData *)artworkData
         canOpenApp:(BOOL)canOpenApp;
@end

/// 面板内边距。
static const CGFloat PGPanelPadding = 16.0;
/// 封面边长。
static const CGFloat PGPanelArtworkSize = 76.0;
/// 面板高度（宽度按屏幕给，见 placePanelInSpace:）。
static const CGFloat PGPanelHeight = 200.0;

@implementation PGLandscapeControlPanel {
    UIVisualEffectView *_blurView;
    /// 叠在毛玻璃之上的极淡暗渐变：只压住底部按钮区的对比度，不做整块压暗，
    /// 否则面板又变回"半透明色块"，透不出背后的画面。
    UIView *_tintView;
    CAGradientLayer *_tintGradient;
    /// 左上到右下的白色高光，模拟玻璃反光。
    UIView *_sheenView;
    CAGradientLayer *_sheenGradient;
    BOOL _didBoostBlur;
    UIImageView *_artworkView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UILabel *_elapsedLabel;
    UILabel *_remainingLabel;
    UIView *_progressTrack;
    UIView *_progressFill;
    CAGradientLayer *_progressGradient;
    UIButton *_previousButton;
    UIButton *_toggleButton;
    UIButton *_nextButton;
    UIButton *_openButton;

    /// 进度条的锚点：MediaRemote 的 elapsed 只按秒级更新，两次更新之间用本地时钟补齐，
    /// 否则进度条是一秒一跳。只有"漂移超过 0.75 秒"或"暂停/换曲"才重新对齐。
    double _anchorElapsed;
    double _duration;
    BOOL _playing;
    CFTimeInterval _anchorTime;
    NSTimer *_tickTimer;
    NSData *_lastArtworkData;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        self.layer.cornerRadius = 22.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        self.layer.borderWidth = 1.0 / MAX(UIScreen.mainScreen.scale, 1.0);
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.26].CGColor;

        // 毛玻璃：ultraThin 是最透的一档 —— 背后游戏的色块会被糊开、颜色透上来，
        // 而不是像 thinMaterial 那样把整块压成深灰。可读性靠上面的渐变 + 文字阴影补。
        UIBlurEffect *effect = nil;
        if (@available(iOS 13.0, *)) {
            effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        } else {
            effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        }
        _blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
        _blurView.userInteractionEnabled = NO;
        [self addSubview:_blurView];

        // 只压底部（按钮/进度条所在的那半），顶部保持通透。
        _tintView = [UIView new];
        _tintView.userInteractionEnabled = NO;
        _tintGradient = [CAGradientLayer layer];
        _tintGradient.colors = @[(__bridge id)[UIColor colorWithWhite:0.0 alpha:0.02].CGColor,
                                 (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.10].CGColor,
                                 (__bridge id)[UIColor colorWithWhite:0.0 alpha:0.26].CGColor];
        _tintGradient.locations = @[@0.0, @0.55, @1.0];
        _tintGradient.startPoint = CGPointMake(0.5, 0.0);
        _tintGradient.endPoint = CGPointMake(0.5, 1.0);
        [_tintView.layer addSublayer:_tintGradient];
        [self addSubview:_tintView];

        _sheenView = [UIView new];
        _sheenView.userInteractionEnabled = NO;
        _sheenGradient = [CAGradientLayer layer];
        _sheenGradient.colors = @[(__bridge id)[UIColor colorWithWhite:1.0 alpha:0.16].CGColor,
                                  (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.05].CGColor,
                                  (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
        _sheenGradient.locations = @[@0.0, @0.45, @1.0];
        _sheenGradient.startPoint = CGPointMake(0.0, 0.0);
        _sheenGradient.endPoint = CGPointMake(0.35, 0.55);
        [_sheenView.layer addSublayer:_sheenGradient];
        [self addSubview:_sheenView];

        _artworkView = [UIImageView new];
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        _artworkView.layer.cornerCurve = kCACornerCurveContinuous;
        if (@available(iOS 13.0, *)) {
            _artworkView.image = [UIImage systemImageNamed:@"music.note"];
            _artworkView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.55];
            _artworkView.contentMode = UIViewContentModeCenter;
        }
        [self addSubview:_artworkView];

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.layer.shadowColor = UIColor.blackColor.CGColor;
        _titleLabel.layer.shadowOpacity = 0.45;
        _titleLabel.layer.shadowRadius = 3.0;
        _titleLabel.layer.shadowOffset = CGSizeMake(0.0, 1.0);
        [self addSubview:_titleLabel];

        _subtitleLabel = [UILabel new];
        _subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.78];
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _subtitleLabel.layer.shadowColor = UIColor.blackColor.CGColor;
        _subtitleLabel.layer.shadowOpacity = 0.40;
        _subtitleLabel.layer.shadowRadius = 3.0;
        _subtitleLabel.layer.shadowOffset = CGSizeMake(0.0, 1.0);
        [self addSubview:_subtitleLabel];

        _elapsedLabel = [self timeLabelWithAlignment:NSTextAlignmentLeft];
        _remainingLabel = [self timeLabelWithAlignment:NSTextAlignmentRight];
        [self addSubview:_elapsedLabel];
        [self addSubview:_remainingLabel];

        _progressTrack = [UIView new];
        _progressTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.26];
        _progressTrack.clipsToBounds = YES;
        [self addSubview:_progressTrack];

        _progressFill = [UIView new];
        _progressGradient = [CAGradientLayer layer];
        _progressGradient.colors = @[(__bridge id)[UIColor colorWithWhite:1.0 alpha:0.98].CGColor,
                                     (__bridge id)[UIColor colorWithRed:1.0 green:0.70 blue:0.42 alpha:1.0].CGColor];
        _progressGradient.startPoint = CGPointMake(0.0, 0.5);
        _progressGradient.endPoint = CGPointMake(1.0, 0.5);
        [_progressFill.layer addSublayer:_progressGradient];
        [_progressTrack addSubview:_progressFill];

        _previousButton = [self buttonWithSymbol:@"backward.fill" pointSize:20.0 action:@selector(tappedPrevious)];
        _nextButton = [self buttonWithSymbol:@"forward.fill" pointSize:20.0 action:@selector(tappedNext)];
        _toggleButton = [self buttonWithSymbol:@"play.fill" pointSize:26.0 action:@selector(tappedToggle)];
        _toggleButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        _openButton = [self buttonWithSymbol:@"arrow.up.forward.app.fill" pointSize:18.0
                                     action:@selector(tappedOpen)];
        _openButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];

        for (UIButton *button in @[_previousButton, _toggleButton, _nextButton, _openButton]) {
            [self addSubview:button];
        }
    }
    return self;
}

- (void)dealloc {
    [_tickTimer invalidate];
}

#pragma mark 控件构造

- (UILabel *)timeLabelWithAlignment:(NSTextAlignment)alignment {
    UILabel *label = [UILabel new];
    label.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightMedium];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    label.textAlignment = alignment;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    return label;
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol
                     pointSize:(CGFloat)pointSize
                        action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIFontWeightSemibold];
        UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:configuration];
        [button setImage:image forState:UIControlStateNormal];
        button.tintColor = UIColor.whiteColor;
    }
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark 内容

- (void)updateTitle:(NSString *)title
             artist:(NSString *)artist
            playing:(BOOL)playing
            elapsed:(double)elapsed
           duration:(double)duration
        artworkData:(NSData *)artworkData
         canOpenApp:(BOOL)canOpenApp {
    _titleLabel.text = title.length ? title : @"正在播放";
    _subtitleLabel.text = artist.length ? artist : @"";

    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:26.0 weight:UIFontWeightBold];
        UIImage *image = [UIImage systemImageNamed:(playing ? @"pause.fill" : @"play.fill")
                                 withConfiguration:configuration];
        [_toggleButton setImage:image forState:UIControlStateNormal];
    }

    _openButton.hidden = !canOpenApp;
    if (artworkData) [self applyArtworkData:artworkData];

    // 暂停/换曲/拖动进度：直接对齐；正常播放：只在漂移过大时对齐，避免每秒往回跳。
    BOOL hardSync = playing != _playing || fabs(duration - _duration) > 0.5;
    if (hardSync) {
        _anchorElapsed = elapsed;
        _anchorTime = CACurrentMediaTime();
    } else {
        double displayed = [self displayedElapsed];
        if (fabs(elapsed - displayed) > 0.75) {
            _anchorElapsed = elapsed;
            _anchorTime = CACurrentMediaTime();
        }
    }
    _playing = playing;
    _duration = duration;

    [self refreshProgress];
    [self setNeedsLayout];
}

- (void)applyArtworkData:(NSData *)data {
    // 字典是浅拷贝，同一个 NSData 实例会一直被复用，指针比较就够了，不必每次解码。
    if (data == _lastArtworkData) return;
    _lastArtworkData = data;

    UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
    if (image) {
        _artworkView.image = image;
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.tintColor = nil;
    } else if (@available(iOS 13.0, *)) {
        _artworkView.image = [UIImage systemImageNamed:@"music.note"];
        _artworkView.contentMode = UIViewContentModeCenter;
        _artworkView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    }
}

- (double)displayedElapsed {
    if (!_playing) return MAX(0.0, _anchorElapsed);
    double value = _anchorElapsed + (CACurrentMediaTime() - _anchorTime);
    if (_duration > 0.0) value = MIN(value, _duration);
    return MAX(0.0, value);
}

- (NSString *)timeStringForSeconds:(double)seconds {
    if (!isfinite(seconds) || seconds < 0.0) seconds = 0.0;
    NSInteger total = (NSInteger)seconds;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(total / 60), (long)(total % 60)];
}

- (void)refreshProgress {
    double elapsed = [self displayedElapsed];
    BOOL hasDuration = _duration > 0.5;

    _elapsedLabel.hidden = !hasDuration;
    _remainingLabel.hidden = !hasDuration;
    _progressTrack.hidden = !hasDuration;
    if (!hasDuration) {
        _elapsedLabel.text = nil;
        _remainingLabel.text = nil;
        return;
    }

    _elapsedLabel.text = [self timeStringForSeconds:elapsed];
    _remainingLabel.text = [NSString stringWithFormat:@"-%@",
                            [self timeStringForSeconds:MAX(0.0, _duration - elapsed)]];
    [self layoutProgressFill];
}

- (void)layoutProgressFill {
    CGFloat trackWidth = CGRectGetWidth(_progressTrack.bounds);
    CGFloat trackHeight = CGRectGetHeight(_progressTrack.bounds);
    if (trackWidth <= 0.0 || trackHeight <= 0.0) return;

    double ratio = 0.0;
    if (_duration > 0.0) {
        ratio = MIN(1.0, MAX(0.0, [self displayedElapsed] / _duration));
    }
    CGFloat fillWidth = trackWidth * (CGFloat)ratio;
    _progressFill.frame = CGRectMake(0.0, 0.0, fillWidth, trackHeight);
    _progressFill.layer.cornerRadius = trackHeight / 2.0;
    _progressGradient.frame = _progressFill.bounds;
    _progressFill.hidden = fillWidth < 1.0;
}

#pragma mark 计时

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    if (hidden) {
        [_tickTimer invalidate];
        _tickTimer = nil;
    } else {
        [self startTickingIfNeeded];
    }
}

- (void)startTickingIfNeeded {
    if (_tickTimer || self.hidden) return;
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *fireTimer) {
        [weakSelf refreshProgress];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    _tickTimer = timer;
}

#pragma mark 交互

- (void)tappedPrevious {
    if (self.onPrevious) self.onPrevious();
}

- (void)tappedToggle {
    if (self.onToggle) self.onToggle();
}

- (void)tappedNext {
    if (self.onNext) self.onNext();
}

- (void)tappedOpen {
    if (self.onOpenApplication) self.onOpenApplication();
}

#pragma mark 布局

/// 系统材质的模糊半径是固定的（UltraThin 大概只有 20 出头），放大到 42 才有真正的
/// "毛玻璃"观感：背后的色块完全化开，只剩一片有颜色的雾。
///
/// 走的是 UIVisualEffectView 内部的 `_UIVisualEffectBackdropView`，它把 CAFilter 数组
/// 挂在 `filters` 上。这一段全是私有层级：类名、key、filter 名任何一个对不上就什么都不做，
/// 所以每一步都用 @try 包住 —— 在 SpringBoard 里崩一次就是安全模式，不能赌。
static const CGFloat PGBackdropBlurRadius = 42.0;

- (void)enlargeBackdropBlurInView:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth < 0) return;

    NSString *className = NSStringFromClass(view.class);
    NSRange match = [className rangeOfString:@"backdrop" options:NSCaseInsensitiveSearch];
    if (match.location != NSNotFound) {
        @try {
            id filters = [view valueForKey:@"filters"];
            if ([filters isKindOfClass:[NSArray class]]) {
                NSMutableArray *updated = [NSMutableArray arrayWithCapacity:[filters count]];
                BOOL changed = NO;
                for (id filter in (NSArray *)filters) {
                    NSString *name = nil;
                    @try {
                        name = [filter valueForKey:@"name"];
                    } @catch (NSException *exception) {
                        (void)exception;
                    }
                    if ([name isKindOfClass:[NSString class]] &&
                        [name rangeOfString:@"blur" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        @try {
                            [filter setValue:@(PGBackdropBlurRadius) forKey:@"inputRadius"];
                            changed = YES;
                        } @catch (NSException *exception) {
                            (void)exception;
                        }
                    }
                    [updated addObject:filter];
                }
                if (changed) {
                    [view setValue:updated forKey:@"filters"];
                    PGLog(@"面板: 模糊半径已放大到 %.0f", PGBackdropBlurRadius);
                }
            }
        } @catch (NSException *exception) {
            (void)exception;
        }
        return;
    }

    for (UIView *subview in view.subviews) {
        [self enlargeBackdropBlurInView:subview depth:depth - 1];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    _blurView.frame = self.bounds;
    _tintView.frame = self.bounds;
    _tintGradient.frame = _tintView.bounds;
    _sheenView.frame = self.bounds;
    _sheenGradient.frame = _sheenView.bounds;

    // 第一次上屏时把系统材质的模糊半径拉大（默认半径偏小，看着像"半透明色块"）。
    // 这是私有层级，某些系统上会失败，失败就维持系统默认，绝不能让它把 SpringBoard 带崩。
    if (!_didBoostBlur && width > 0.0) {
        _didBoostBlur = YES;
        [self enlargeBackdropBlurInView:_blurView depth:4];
    }

    CGFloat artSize = PGPanelArtworkSize;
    _artworkView.frame = CGRectMake(PGPanelPadding, PGPanelPadding, artSize, artSize);
    _artworkView.layer.cornerRadius = artSize / 2.0;

    CGFloat textX = PGPanelPadding + artSize + 14.0;
    CGFloat textWidth = MAX(0.0, width - textX - PGPanelPadding);
    _titleLabel.frame = CGRectMake(textX, PGPanelPadding + 2.0, textWidth, 22.0);
    _subtitleLabel.frame = CGRectMake(textX, PGPanelPadding + 26.0, textWidth, 18.0);

    // 进度行：左边当前时间、右边剩余时间，中间是进度条。
    CGFloat progressY = PGPanelPadding + artSize + 14.0;
    CGFloat timeWidth = 42.0;
    CGFloat trackX = PGPanelPadding + timeWidth + 10.0;
    CGFloat trackRight = width - PGPanelPadding - timeWidth - 10.0;
    CGFloat trackWidth = MAX(0.0, trackRight - trackX);
    CGFloat trackHeight = 5.0;
    CGFloat trackY = progressY + (16.0 - trackHeight) / 2.0;

    _elapsedLabel.frame = CGRectMake(PGPanelPadding, progressY, timeWidth, 16.0);
    _remainingLabel.frame = CGRectMake(width - PGPanelPadding - timeWidth, progressY, timeWidth, 16.0);
    _progressTrack.frame = CGRectMake(trackX, trackY, trackWidth, trackHeight);
    _progressTrack.layer.cornerRadius = trackHeight / 2.0;
    [self layoutProgressFill];

    // 按钮行：上一首 / 播放暂停 / 下一首 居中，右侧留一个"打开播放器"。
    CGFloat toggleSize = 52.0;
    CGFloat sideSize = 40.0;
    CGFloat gap = 26.0;
    CGFloat centerY = height - PGPanelPadding - toggleSize / 2.0;

    CGFloat total = sideSize * 2.0 + toggleSize + gap * 2.0;
    CGFloat originX = (width - total) / 2.0;
    _previousButton.frame = CGRectMake(originX, centerY - sideSize / 2.0, sideSize, sideSize);
    _toggleButton.frame = CGRectMake(originX + sideSize + gap, centerY - toggleSize / 2.0,
                                     toggleSize, toggleSize);
    _nextButton.frame = CGRectMake(originX + sideSize + gap + toggleSize + gap,
                                   centerY - sideSize / 2.0, sideSize, sideSize);
    _toggleButton.layer.cornerRadius = toggleSize / 2.0;
    _toggleButton.layer.cornerCurve = kCACornerCurveContinuous;

    CGFloat openSize = 34.0;
    _openButton.frame = CGRectMake(width - PGPanelPadding - openSize,
                                   centerY - openSize / 2.0, openSize, openSize);
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

/// 显示 + 只放行胶囊和面板上的触摸，其它位置全部穿透给底下的游戏。
@interface PGLandscapeBarWindow : UIWindow
@property (nonatomic, weak, nullable) UIView *barHitArea;
@property (nonatomic, weak, nullable) UIView *panelHitArea;
@end

@implementation PGLandscapeBarWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (BOOL)canBecomeFocused {
    return NO;
}

/// 这个窗口铺满全屏，如果正常参与命中测试会把游戏的触摸全部吃掉。
/// 只把落在胶囊 / 控制面板里的点交出去，其余返回 nil —— UIKit 会继续往下层窗口投递。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self) return nil;

    UIView *bar = self.barHitArea;
    if (bar && !bar.hidden && [hit isDescendantOfView:bar]) return hit;

    UIView *panel = self.panelHitArea;
    if (panel && !panel.hidden && panel.superview && [hit isDescendantOfView:panel]) return hit;

    return nil;
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
/// 进入竖屏的时间戳（0 = 当前不是竖屏），用于"连续确认 300ms 才收起"。
@property (nonatomic, assign) CFTimeInterval portraitSince;
@property (nonatomic, assign) CFTimeInterval lastShowTime;
@property (nonatomic, assign) CFTimeInterval lastHideTime;
/// 第一次出现才用淡入；之后重新显示直接给 alpha，避免每隔几百毫秒闪一次淡入。
@property (nonatomic, assign) BOOL appearedOnce;
/// 内容宽度变了（歌名长度变化），下一次排版要重新量尺寸。
@property (nonatomic, assign) BOOL needsResize;
/// 长按已经处理过，抑制紧随其后的那次 tap（否则面板一开就被自己关掉）。
@property (nonatomic, assign) CFTimeInterval suppressTapUntil;
/// 上次重建窗口的时间，用于给重建限流。
@property (nonatomic, assign) CFTimeInterval lastWindowRebuild;
/// 显示/隐藏抖动检测：窗口期内翻转次数，以及熔断到期时间。
@property (nonatomic, assign) NSInteger toggleBurst;
@property (nonatomic, assign) CFTimeInterval burstWindowStart;
@property (nonatomic, assign) CFTimeInterval flickerLockUntil;
/// 最近一次解析结果，供日志/诊断弹窗使用。
@property (nonatomic, copy) NSString *resolvedSource;
@property (nonatomic, copy, nullable) NSString *lastSnapshot;

/// 点一下胶囊弹出的播放控制面板。
@property (nonatomic, strong, nullable) PGLandscapeControlPanel *panel;
@property (nonatomic, assign) BOOL panelVisible;
@property (nonatomic, strong, nullable) NSTimer *panelTimer;
/// 是否已经在监听系统"正在播放"。
@property (nonatomic, assign) BOOL musicMonitoring;
/// 音乐区当前生效的可见状态，以及"待生效"的候选状态。
@property (nonatomic, assign) BOOL musicAppliedVisible;
@property (nonatomic, assign) BOOL musicHasApplied;
@property (nonatomic, assign) BOOL musicPendingVisible;
@property (nonatomic, assign) CFTimeInterval musicPendingSince;
/// 最新一次算出来的"应不应该显示音乐区"。轮询每拍都重新算一遍，
/// 不能只在 onChange 里算 —— 系统不一定发通知，那样"待生效"永远等不到下一拍。
@property (nonatomic, assign) BOOL musicDesiredVisible;

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
        [self startMusicMonitoring];
    }
    [self refreshNow];
}

#pragma mark 音乐

- (void)startMusicMonitoring {
    if (self.musicMonitoring) return;
    self.musicMonitoring = YES;
    PGNowPlaying *nowPlaying = PGNowPlaying.sharedInstance;
    __weak typeof(self) weakSelf = self;
    nowPlaying.onChange = ^(PGNowPlaying *item) {
        [weakSelf applyNowPlaying:item];
    };
    [nowPlaying startMonitoring];
}

/// 决定胶囊里要不要带音乐信息。
/// 判定条件：开关打开 + 确实在播 + 有歌名/歌手 + 播放的 App 不是当前前台 App
/// （前台自己在放视频/音乐时不该再显示一遍，那正是全屏看片会误弹的原因）。
- (void)applyNowPlaying:(PGNowPlaying *)item {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyNowPlaying:item];
        });
        return;
    }
    if (!self.bar) return;

    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    NSString *playingApp = item.bundleIdentifier;
    NSString *frontApp = item.frontmostBundleIdentifier;
    BOOL inBackground = playingApp.length == 0 || frontApp.length == 0 ||
                        ![playingApp isEqualToString:frontApp];
    BOOL hasText = item.title.length > 0 || item.artist.length > 0;
    self.musicDesiredVisible = preferences.landscapeMusic && item.isPlaying && hasText && inBackground;

    [self evaluateMusicVisibilityWithItem:item];
}

/// 把"想要的可见状态"按 PGLandscapeMusicDebounce 稳定一段时间后落到胶囊上。
/// 必须能被外部按拍调用（pollTick），否则状态一旦不再变化就再没人推进它 ——
/// 表现就是"明明在放歌，歌名永远不出来"。
- (void)evaluateMusicVisibilityWithItem:(PGNowPlaying *)item {
    BOOL desired = self.musicDesiredVisible;

    // 稳定化：这些探针（是否在播 / 播放的是哪个 App / 前台是哪个 App）在切前台、App 切换、
    // 锁屏的瞬间会有一两次瞬时失准。直接跟着变，胶囊就会一会儿有歌名一会儿没有，
    // 宽度来回跳 —— 用户看到的就是"一直闪"。新状态必须稳定 PGLandscapeMusicDebounce 才生效。
    CFTimeInterval now = CACurrentMediaTime();
    if (!self.musicHasApplied) {
        self.musicHasApplied = YES;
        self.musicAppliedVisible = desired;
        self.musicPendingSince = 0.0;
    } else if (desired == self.musicAppliedVisible) {
        self.musicPendingSince = 0.0;
    } else if (self.musicPendingSince <= 0.0 || self.musicPendingVisible != desired) {
        self.musicPendingVisible = desired;
        self.musicPendingSince = now;
    } else if (now - self.musicPendingSince >= PGLandscapeMusicDebounce) {
        self.musicAppliedVisible = desired;
        self.musicPendingSince = 0.0;
        PGLog(@"音乐区%@ (playing=%d app=%@ front=%@)",
              desired ? @"显示" : @"收起", item.isPlaying,
              item.bundleIdentifier ?: @"-", item.frontmostBundleIdentifier ?: @"-");
    }

    BOOL visible = self.musicAppliedVisible;
    [self.bar setMusicVisible:visible
                        title:item.title
                       artist:item.artist
                      playing:item.isPlaying];
    if (visible) {
        [self syncPanelWithNowPlaying:item];
    } else if (self.panelVisible) {
        [self hidePanel];
    }
}

/// 面板要的字段比胶囊多（进度、封面、能不能跳回播放器），统一在这里灌进去。
- (void)syncPanelWithNowPlaying:(PGNowPlaying *)item {
    if (!self.panel) return;
    [self.panel updateTitle:item.title
                     artist:item.artist
                    playing:item.isPlaying
                    elapsed:item.elapsed
                   duration:item.duration
                artworkData:item.artworkData
                 canOpenApp:item.bundleIdentifier.length > 0];
}

- (void)handleBarTap:(UITapGestureRecognizer *)recognizer {
    if (CACurrentMediaTime() < self.suppressTapUntil) return;   // 长按刚开过面板，别被同一串触摸关掉
    if (self.panelVisible) {
        [self hidePanel];
        return;
    }
    if (!self.bar.musicVisible) return;   // 没在放歌就别弹面板
    [self showPanel];
}

- (void)handleBarLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    if (self.panelVisible) return;
    if (!self.bar.musicVisible) return;   // 没在放歌就别弹面板
    // 长按结束后系统还会补一次 tap，抑制掉它，否则面板开了立刻又被关掉 —— 看着就是"闪"。
    self.suppressTapUntil = CACurrentMediaTime() + 0.7;
    [self showPanel];
}

- (void)showPanel {
    if (!self.panel || self.panelVisible) return;
    if (self.window.bounds.size.width <= self.window.bounds.size.height) return;   // 仅横屏空间可用

    PGNowPlaying *nowPlaying = PGNowPlaying.sharedInstance;
    [self syncPanelWithNowPlaying:nowPlaying];

    self.panelVisible = YES;
    self.panel.hidden = NO;
    self.panel.alpha = 0.0;
    [self placePanelInSpace:self.window.bounds];
    [UIView animateWithDuration:0.16
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.panel.alpha = 1.0;
    } completion:nil];

    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (preferences.vibrationFeedback) AudioServicesPlaySystemSound(1519);
    [self schedulePanelHide];
}

- (void)hidePanel {
    [self.panelTimer invalidate];
    self.panelTimer = nil;
    if (!self.panelVisible) return;
    self.panelVisible = NO;
    [self.panel.layer removeAllAnimations];
    self.panel.hidden = YES;
    self.panel.alpha = 1.0;
}

/// 面板不点也会自己收起，免得挡住游戏画面。
- (void)schedulePanelHide {
    [self.panelTimer invalidate];
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:6.0
                                           repeats:NO
                                             block:^(NSTimer *fireTimer) {
        [weakSelf hidePanel];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.panelTimer = timer;
}

- (void)sendMediaCommand:(PGMediaCommand)command {
    [PGNowPlaying.sharedInstance sendCommand:command];
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (preferences.vibrationFeedback) AudioServicesPlaySystemSound(1519);
    [self schedulePanelHide];
}

/// 面板右下角那个按钮：直接跳到正在放歌的 App。
- (void)openNowPlayingApplication {
    NSString *bundleIdentifier = PGNowPlaying.sharedInstance.bundleIdentifier;
    if (bundleIdentifier.length == 0) return;

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return;
    @try {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));
        SEL selector = @selector(openApplicationWithBundleID:);
        if (!workspace || ![workspace respondsToSelector:selector]) return;
        ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, selector, bundleIdentifier);
        PGLog(@"面板: 跳转到 %@", bundleIdentifier);
    } @catch (__unused NSException *exception) {
        PGLog(@"面板: 跳转 %@ 抛异常", bundleIdentifier);
    }
    [self hidePanel];
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

    // 音乐区每拍重新判一次：MediaRemote 的通知不一定来（后台播放尤其容易漏），
    // 只靠 onChange 的话"待生效"状态永远等不到下一次判定，歌名就再也出不来。
    if (self.active) {
        [self applyNowPlaying:PGNowPlaying.sharedInstance];
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

    // 窗口挂在某个 UIScene 上。App 退到桌面再回来时，原先那个场景可能已经 unattached，
    // 窗口成了"孤儿"：window.hidden = NO 只会亮一下又被系统收走 —— 这正是"再次进入一直闪"。
    [self ensureWindowAttached];

    BOOL leftEdgeUp = NO;
    NSString *source = @"-";
    BOOL landscape = [self resolveLandscape:&leftEdgeUp source:&source];
    self.resolvedSource = source;

    CFTimeInterval now = CACurrentMediaTime();

    // 抖动熔断：几秒内"显示↔隐藏"来回超过阈值，就说明方向来源在抖（切前台、锁屏、
    // 探针瞬时失准）。这段时间只认重力（物理事实），其它来源先不做决定 —— 否则用户
    // 看到的就一直是闪。熔断到期自动解除，不会把块永久锁死。
    if (now < self.flickerLockUntil && ![source hasPrefix:@"gravity"]) return;

    if (!landscape) {
        // 竖屏一律隐藏 —— 这是功能定义，不做"竖屏也常驻"的兼容。
        self.landscapeSince = 0.0;
        if (!self.visible) {
            self.portraitSince = 0.0;
            [self logSnapshotShown:NO note:[@"portrait/" stringByAppendingString:source]];
            return;
        }
        // 防抖：必须连续确认 PGLandscapeHideDelay 才真的收起。
        // 否则方向探针抖一下就是一次"隐藏→显示"，看起来就是一直在闪。
        if (self.portraitSince <= 0.0) self.portraitSince = now;
        if (now - self.portraitSince < PGLandscapeHideDelay) return;
        if (now - self.lastShowTime < PGLandscapeMinVisible) return;
        [self noteToggleAt:now];
        [self hideBar];
        self.lastHideTime = now;
        [self logSnapshotShown:NO note:[@"portrait/" stringByAppendingString:source]];
        return;
    }

    self.portraitSince = 0.0;

    // 刚转过来时窗口坐标系还在翻转，等方向稳定一小会儿再画，避免闪一下。
    if (self.landscapeSince <= 0.0) self.landscapeSince = now;
    if (!self.visible) {
        if (now - self.landscapeSince < PGLandscapeShowDelay) return;
        // 刚藏起来又立刻显示，同样是"闪"。留一个最小间隔。
        if (now - self.lastHideTime < PGLandscapeReshowDelay) return;
        [self noteToggleAt:now];
    }

    [self showBarLeftEdgeUp:leftEdgeUp];
    [self logSnapshotShown:YES note:[@"show/" stringByAppendingString:source]];
}

/// 记录一次"显示↔隐藏"翻转。4 秒内翻转 4 次就判定方向来源在抖，锁 3 秒只看重力。
- (void)noteToggleAt:(CFTimeInterval)now {
    if (self.burstWindowStart <= 0.0 || now - self.burstWindowStart > 4.0) {
        self.burstWindowStart = now;
        self.toggleBurst = 0;
    }
    self.toggleBurst++;
    if (self.toggleBurst < 4) return;
    self.toggleBurst = 0;
    self.burstWindowStart = now;
    if (now >= self.flickerLockUntil) {
        self.flickerLockUntil = now + 3.0;
        PGLog(@"显示/隐藏抖动，锁定当前状态 3 秒（只认重力）");
    }
}

/// 窗口必须挂在一个"活着"的 UIScene 上。失效就整体重建，而不是对着一个孤儿窗口反复 hidden = NO。
- (void)ensureWindowAttached {
    if (!self.window) return;
    UIWindowScene *scene = self.window.windowScene;
    if (scene && scene.activationState != UISceneActivationStateUnattached) return;
    // 一个可用场景都拿不到（多见于切前台 / 返回桌面的动画中间），先别拆，等下一次轮询。
    if (!PGLandscapeHostScene()) return;
    // 重建本身也会闪一下，限流：1.5 秒内最多一次。
    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastWindowRebuild > 0.0 && now - self.lastWindowRebuild < 1.5) return;
    self.lastWindowRebuild = now;
    PGLog(@"窗口场景失效(scene=%@ state=%ld)，重建窗口",
          scene ? @"有" : @"无", (long)(scene ? scene.activationState : -1));
    [self teardownWindow];
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
        self.bar.hidden = NO;
        // 只有"第一次出现"或"确实藏了一会儿"才淡入。若是在几百毫秒内又显回来，
        // 再来一次淡入就是肉眼可见的闪 —— 直接给满透明度。
        BOOL longGap = !self.appearedOnce ||
                       (self.lastHideTime > 0.0 && CACurrentMediaTime() - self.lastHideTime > 1.2);
        if (longGap) {
            self.bar.alpha = 0.0;
            [UIView animateWithDuration:PGLandscapeFadeInDuration
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                self.bar.alpha = 1.0;
            } completion:nil];
            self.appearedOnce = YES;
        } else {
            [self.bar.layer removeAllAnimations];
            self.bar.alpha = 1.0;
        }
    }
    self.lastShowTime = CACurrentMediaTime();
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
    // 窗口本身要收触摸（胶囊 / 面板），由 hitTest 保证其它位置全部穿透。
    window.userInteractionEnabled = YES;
    window.accessibilityElementsHidden = YES;
    window.hidden = YES;

    // 根视图换成自定义容器：它随窗口一起变尺寸，旋转动画每一帧都会回调 layoutSubviews 重排胶囊。
    PGLandscapeHostView *host = [[PGLandscapeHostView alloc] initWithFrame:window.bounds];
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    host.backgroundColor = UIColor.clearColor;
    host.userInteractionEnabled = YES;
    host.bar = self;

    UIViewController *controller = [[UIViewController alloc] init];
    controller.view = host;
    window.rootViewController = controller;

    PGLandscapeBarView *bar = [[PGLandscapeBarView alloc] initWithFrame:CGRectZero];
    bar.hidden = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(handleBarTap:)];
    [bar addGestureRecognizer:tap];
    // 长按也能唤出播放面板（和点一下等价，按住不放更不容易误触）。
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleBarLongPress:)];
    longPress.minimumPressDuration = 0.35;
    longPress.allowableMovement = 14.0;
    [bar addGestureRecognizer:longPress];
    [host addSubview:bar];

    PGLandscapeControlPanel *panel = [[PGLandscapeControlPanel alloc] initWithFrame:CGRectZero];
    panel.hidden = YES;
    __weak typeof(self) weakSelf = self;
    panel.onPrevious = ^{ [weakSelf sendMediaCommand:PGMediaCommandPrevious]; };
    panel.onToggle = ^{ [weakSelf sendMediaCommand:PGMediaCommandTogglePlayPause]; };
    panel.onNext = ^{ [weakSelf sendMediaCommand:PGMediaCommandNext]; };
    panel.onOpenApplication = ^{ [weakSelf openNowPlayingApplication]; };
    [host addSubview:panel];

    window.barHitArea = bar;
    window.panelHitArea = panel;

    // 歌名长短变化会改变胶囊宽度，通知宿主立刻重排（否则要等下一次方向轮询）。
    bar.contentWidthDidChange = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.visible) return;
        strongSelf.needsResize = YES;
        [strongSelf layoutBarLeftEdgeUp:strongSelf.anchorLeftEdgeUp];
    };

    self.window = window;
    self.bar = bar;
    self.panel = panel;
    self.laidOut = NO;
    self.barLength = 0.0;
    self.barThickness = 0.0;

    // 窗口刚建好时音乐可能已经在放了，先把当前状态同步进来。
    [self applyNowPlaying:PGNowPlaying.sharedInstance];

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

    BOOL sameSpace = self.laidOut &&
                     self.barLength > 0.0 &&
                     self.laidOutLeftEdgeUp == leftEdgeUp &&
                     fabs(self.laidOutScreenSize.width - spaceWidth) < 0.5 &&
                     fabs(self.laidOutScreenSize.height - spaceHeight) < 0.5;
    if (sameSpace && !self.needsResize) {
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
    self.needsResize = NO;
    self.laidOutLeftEdgeUp = leftEdgeUp;
    self.laidOutScreenSize = CGSizeMake(spaceWidth, spaceHeight);

    // 尺寸变化就在下一帧直接生效（歌名来去已经做过稳定化，不会来回跳，
    // 也就不需要给宽度做动画 —— 动画里的标签重排反而会有半帧错位）。
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

    [self placePanelInSpace:space];
}

/// 面板挨着胶囊下沿居中摆放。竖屏坐标系里不做（旋转瞬间不显示面板，避免旋转补偿把面板甩到屏幕外）。
- (void)placePanelInSpace:(CGRect)space {
    if (!self.panel) return;
    CGFloat spaceWidth = CGRectGetWidth(space);
    CGFloat spaceHeight = CGRectGetHeight(space);
    if (spaceWidth <= spaceHeight) {
        self.panel.hidden = YES;
        return;
    }

    CGFloat panelWidth = MIN(460.0, MAX(300.0, spaceWidth - 80.0));
    CGFloat panelHeight = PGPanelHeight;
    self.panel.transform = CGAffineTransformIdentity;
    self.panel.bounds = CGRectMake(0.0, 0.0, panelWidth, panelHeight);

    CGFloat barBottom = self.bar ? CGRectGetMaxY(self.bar.frame) : 30.0;
    self.panel.center = CGPointMake(spaceWidth / 2.0, barBottom + 10.0 + panelHeight / 2.0);
}

- (void)hideBar {
    if (self.updating) {
        [self.bar stopUpdating];
        self.updating = NO;
    }
    [self hidePanel];
    [self.bar.layer removeAllAnimations];
    self.bar.alpha = 1.0;
    self.bar.hidden = YES;
    self.window.hidden = YES;
    self.laidOut = NO;
    self.needsResize = NO;
    self.visible = NO;
    self.landscapeSince = 0.0;
    self.portraitSince = 0.0;
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
    self.panel = nil;
    self.panelVisible = NO;
    self.laidOut = NO;
    self.needsResize = NO;
    self.visible = NO;
    self.appearedOnce = NO;
    self.barLength = 0.0;
    self.barThickness = 0.0;
}

@end

#pragma mark - 跨线程刷新入口

static void PGRequestRefresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [PGLandscapeBar.sharedBar refreshNow];
    });
}
