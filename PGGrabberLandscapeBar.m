#import "PGGrabberLandscapeBar.h"
#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"
#import "PGNowPlaying.h"
#import "PGHardwareMetrics.h"
#import "PGLyricsProvider.h"
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

/// 控制区松手后保留多久。按按钮会重新计时，所以"正在操作"时不会被收走。
static const CFTimeInterval PGCardControlsGraceSeconds = 3.0;

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


#pragma mark - 横屏音乐卡片

/// 横屏时唯一的一块 UI：一张卡片里塞三段
///   ① 状态行：时间 / 电量（充电带闪电）/ 电池温度 / CPU 占用率
///   ② 歌曲区：封面 + 歌名 + 歌手 + 实时歌词（没在放歌也保留封面区，文案「未播放」）
///   ③ 播放控制区：进度条 + 上一首 / 播放暂停 / 下一首 —— 默认隐藏，长按整张卡片才展开
///
/// 由 1.1 系列的 PGLandscapeControlPanel 演化而来：毛玻璃、进度锚点、按倍数排版全部沿用，
/// 只是从「点胶囊弹出的浮动面板」变成「横屏时唯一常驻的卡片」，并补上状态行与歌词。
/// 旧的胶囊（PGLandscapeBarView）与独立面板一起退役，屏幕上不再同时出现两块东西。
@interface PGLandscapeMusicCard : UIView
@property (nonatomic, copy, nullable) void (^onPrevious)(void);
@property (nonatomic, copy, nullable) void (^onToggle)(void);
@property (nonatomic, copy, nullable) void (^onNext)(void);
/// 点封面跳到正在播放的 App。
@property (nonatomic, copy, nullable) void (^onOpenApplication)(void);
@property (nonatomic, assign, readonly) BOOL controlsVisible;

- (void)updateTitle:(nullable NSString *)title
             artist:(nullable NSString *)artist
            playing:(BOOL)playing
            elapsed:(double)elapsed
           duration:(double)duration
        artworkData:(nullable NSData *)artworkData
         canOpenApp:(BOOL)canOpenApp;

/// 播放控制区的展开 / 收起。卡片高度由宿主（PGLandscapeBar）负责，这里只管内容与透明度。
- (void)setControlsVisible:(BOOL)visible animated:(BOOL)animated;

/// 背景两态切换：收起 = 纯色（或透明），展开 = 整卡毛玻璃。
- (void)applyBackgroundStyleAnimated:(BOOL)animated;

- (void)startTicking;
- (void)stopTicking;
/// 点按落点判定，返回 YES 表示这次点按已被消费（点在封面上 → 跳播放器）。
- (BOOL)handleTapAtPoint:(CGPoint)point;
@end

/// 设计稿尺寸（1.0 倍）。实际尺寸 = 常量 × LandscapeCardScale（0.7 ~ 2.2，默认 1.35）。
static const CGFloat PGCardDesignWidth = 320.0;
/// 收起时的高度：**只留状态行**（时间 / 电量 / 温度 / CPU）。6 + 15 + 6，上下留白对称。
/// 歌曲区（封面 / 歌名 / 歌词）从 33 才开始排，所以在这个高度下会被 clipsToBounds 整个裁掉 ——
/// 收起态不需要额外 hidden，改高度就够了。
static const CGFloat PGCardCollapsedHeight = 27.0;
/// 展开时的高度：状态行 + 歌曲区 + 控制区。
static const CGFloat PGCardExpandedHeight = 150.0;
/// 展开时控制区的起点（歌曲区 33~81 之下）。
/// ⚠️ 不能再用 PGCardCollapsedHeight 当这个值 —— 收起高度变小之后两者不再相等。
static const CGFloat PGCardControlsOffset = 86.0;
static const CGFloat PGCardPadding = 10.0;
static const CGFloat PGCardArtworkSize = 48.0;
static const CGFloat PGCardCornerRadius = 18.0;

/// 卡片的外观偏好。直接读 CFPreferences 而不是走 sharedPreferences 的 3 秒缓存 ——
/// 用户在设置里拖滑块时要立刻看到变化（卡片每 0.5 秒会重排一次）。
static id PGCardPreference(NSString *key, id fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)PGPreferencesDomain);
    return CFBridgingRelease(value) ?: fallback;
}

static CGFloat PGCardBlurRadius(void) {
    id value = PGCardPreference(@"LandscapeGlassBlur", @38.0);
    double radius = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 38.0;
    if (!isfinite(radius)) return 38.0;
    return MAX(0.0, MIN(80.0, radius));
}

static CGFloat PGCardGlassOpacity(void) {
    id value = PGCardPreference(@"LandscapeGlassOpacity", @0.80);
    double opacity = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.80;
    if (!isfinite(opacity) || opacity <= 0.0) return 0.80;
    return MAX(0.30, MIN(1.0, opacity));
}

static UIColor *PGCardTintColor(void) {
    NSString *hex = PGCardPreference(@"LandscapeGlassTint", @"#0B0F14");
    return [PerfectGrabberPreferences colorFromHexString:hex
                                               fallback:[UIColor colorWithWhite:0.04 alpha:1.0]];
}

static BOOL PGCardShowsLyrics(void) {
    id value = PGCardPreference(@"LandscapeLyrics", @YES);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : YES;
}

/// 收起态要不要垫一块纯色底。默认 YES。
/// 关掉就完全透明 —— 只剩文字浮在游戏画面上；展开后仍然是整卡毛玻璃。
static BOOL PGCardCollapsedSolidEnabled(void) {
    id value = PGCardPreference(@"LandscapeCollapsedSolid", @YES);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : YES;
}

/// 卡片当前倍数。0.7 ~ 2.2，默认 1.35（320 → 432 宽，横屏 932 宽下约占 46%）。
static CGFloat PGCardScaleValue(void) {
    id value = PGCardPreference(@"LandscapeCardScale", @1.35);
    double scale = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 1.35;
    if (!isfinite(scale) || scale <= 0.0) return 1.35;
    return MAX(0.7, MIN(2.2, scale));
}

/// 吸附位置。0 顶部居中 / 1 左上 / 2 右上 / 3 底部居中 / 4 左下 / 5 右下 /
/// 6 左侧居中 / 7 右侧居中。默认 0（贴屏幕顶边居中）。
static NSInteger PGCardSnapPosition(void) {
    id value = PGCardPreference(@"LandscapeSnapPosition", @0);
    NSInteger position = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
    return MAX(0, MIN(7, position));
}

/// 卡片与屏幕边缘之间留多少间隙。0 ~ 40，默认 0 = 完全贴边（就是"吸在最边缘"）。
static CGFloat PGCardSnapInset(void) {
    id value = PGCardPreference(@"LandscapeSnapInset", @0.0);
    double inset = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0;
    if (!isfinite(inset) || inset < 0.0) return 0.0;
    return MIN(40.0, inset);
}

static UIImage *_Nullable PGCardSymbol(NSString *name, CGFloat pointSize, UIFontWeight weight) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:MAX(6.0, pointSize) weight:weight];
        return [UIImage systemImageNamed:name withConfiguration:configuration];
    }
    return nil;
}

@class SBUIController;
@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (NSInteger)batteryCapacityAsPercentage;
- (BOOL)isOnAC;
@end

@implementation PGLandscapeMusicCard {
    /// 收起态的纯色底（颜色取「玻璃色调」）。展开后让位给下面的毛玻璃。
    UIView *_solidView;
    UIVisualEffectView *_blurView;
    UIView *_tintView;
    CAGradientLayer *_tintGradient;
    UIView *_sheenView;
    CAGradientLayer *_sheenGradient;

    // ① 状态行
    UILabel *_clockLabel;
    UIImageView *_boltIcon;
    UIImageView *_batteryIcon;
    UILabel *_batteryLabel;
    UIImageView *_thermalIcon;
    UILabel *_thermalLabel;
    UILabel *_cpuLabel;
    UIView *_separator;
    // 收起态还要在这一行里带上播放状态（沿用 1.1 系列胶囊的做法：♪ 歌名 · 歌手 + 播放/暂停图标）。
    // 展开后这部分让位给下面的歌曲区，藏起来。
    UIImageView *_musicNoteView;
    UILabel *_musicLabel;
    UIImageView *_musicStateView;

    // ② 歌曲区
    UIView *_artworkContainer;
    UIImageView *_artworkView;
    UIImageView *_artworkPlaceholder;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UILabel *_lyricLabel;

    // ③ 播放控制区
    UIView *_controlsContainer;
    UIView *_progressTrack;
    UIView *_progressFill;
    CAGradientLayer *_progressGradient;
    UILabel *_elapsedLabel;
    UILabel *_remainingLabel;
    UIButton *_previousButton;
    UIButton *_toggleButton;
    UIButton *_nextButton;

    // 状态缓存
    NSString *_batterySymbol;
    NSString *_shownTitle;
    NSString *_shownArtist;
    NSString *_trackKey;
    /// 收起行播放图标的缓存键（符号 + 倍数），避免每拍重建 SF Symbol。
    NSString *_musicIconKey;
    NSString *_lyricPrimary;
    NSString *_lyricSecondary;
    NSDateFormatter *_clockFormatter;
    NSData *_lastArtworkData;
    BOOL _hasMedia;
    BOOL _controlsVisible;
    BOOL _canOpenApp;
    NSInteger _tickCount;
    NSTimer *_tickTimer;

    // 进度锚点：MediaRemote 的 elapsed 只按秒级更新，两次更新之间用本地时钟补齐。
    double _anchorElapsed;
    double _duration;
    BOOL _playing;
    CFTimeInterval _anchorTime;

    // 上次应用过的大小 / 外观，避免每帧重建字体与滤镜。
    CGFloat _appliedScale;
    CGFloat _appliedTextScale;
    CGFloat _appliedBlur;
    CGFloat _appliedOpacity;
    NSString *_appliedTintKey;
    BOOL _appliedLyrics;
    /// 当前背景处于哪一态（YES = 展开 / 毛玻璃），以及「收起时纯色背景」开关的上次值。
    BOOL _backgroundExpanded;
    BOOL _appliedSolidEnabled;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        self.layer.cornerRadius = PGCardCornerRadius;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        self.layer.borderWidth = 1.2 / MAX(UIScreen.mainScreen.scale, 1.0);
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.38].CGColor;

        // 收起态：一块纯色底，颜色取「玻璃色调」。用户关掉「收起时纯色背景」就完全透明。
        // 放最底层 —— 展开时它的 alpha 归零，让上面的毛玻璃接替。
        _solidView = [UIView new];
        _solidView.userInteractionEnabled = NO;
        _solidView.alpha = 0.0;
        [self addSubview:_solidView];

        // 毛玻璃：ultraThin 最透，背后游戏的色块会被糊开、颜色透上来。
        // 半径与不透明度都可由用户调（设置里的两个滑块），默认值沿用 1.1-33 调通透后的那套。
        UIBlurEffect *effect = nil;
        if (@available(iOS 13.0, *)) {
            effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        } else {
            effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        }
        _blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
        _blurView.userInteractionEnabled = NO;
        // 收起态不显示玻璃：整卡毛玻璃只在展开时出现（背景态由 applyBackgroundStyle 切换）。
        _blurView.alpha = 0.0;
        [self addSubview:_blurView];

        // 用户选的色调叠一层，透明度跟着玻璃浓度走：越不透明，颜色越明显。
        _tintView = [UIView new];
        _tintView.userInteractionEnabled = NO;
        _tintGradient = [CAGradientLayer layer];
        _tintGradient.startPoint = CGPointMake(0.5, 0.0);
        _tintGradient.endPoint = CGPointMake(0.5, 1.0);
        [_tintView.layer addSublayer:_tintGradient];
        [self addSubview:_tintView];

        // 左上角一抹高光，模拟玻璃反光。
        _sheenView = [UIView new];
        _sheenView.userInteractionEnabled = NO;
        _sheenGradient = [CAGradientLayer layer];
        _sheenGradient.colors = @[(__bridge id)[UIColor colorWithWhite:1.0 alpha:0.18].CGColor,
                                  (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.04].CGColor,
                                  (__bridge id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
        _sheenGradient.locations = @[@0.0, @0.35, @1.0];
        _sheenGradient.startPoint = CGPointMake(0.0, 0.0);
        _sheenGradient.endPoint = CGPointMake(0.35, 0.55);
        [_sheenView.layer addSublayer:_sheenGradient];
        [self addSubview:_sheenView];

        [self buildStatusRow];
        [self buildSongSection];
        [self buildControlsSection];

        self.clipsToBounds = YES;
        _controlsVisible = NO;
        _controlsContainer.hidden = YES;
        _controlsContainer.alpha = 0.0;
        _controlsContainer.userInteractionEnabled = NO;
        _separator.hidden = YES;
        // 首帧就摆到收起态该有的样子，避免刚出现时闪一下玻璃。
        [self applyBackgroundStyleAnimated:NO];
    }
    return self;
}

- (void)dealloc {
    [_tickTimer invalidate];
}

/// 收起态只有 30 来点高，横屏打游戏时手指很容易点偏上下边缘。
/// 命中区上下各放宽 8pt、左右 6pt —— 只影响 hitTest，视觉尺寸不变；
/// 屏幕最上面那条边在游戏里也没有可点的东西，吃掉它没有代价（和 1.1 的胶囊一致）。
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (CGRectContainsPoint(self.bounds, point)) return YES;
    if (_controlsVisible) return NO;
    return CGRectContainsPoint(CGRectInset(self.bounds, -6.0, -8.0), point);
}

#pragma mark 构造

- (void)buildStatusRow {
    _clockLabel = [UILabel new];
    _clockLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
    _clockLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.96];
    _clockLabel.numberOfLines = 1;
    [self addSubview:_clockLabel];

    _boltIcon = [UIImageView new];
    _boltIcon.image = PGCardSymbol(@"bolt.fill", 8.0, UIFontWeightBold);
    _boltIcon.tintColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.22 alpha:1.0];
    _boltIcon.contentMode = UIViewContentModeScaleAspectFit;
    _boltIcon.hidden = YES;
    [self addSubview:_boltIcon];

    _batteryIcon = [UIImageView new];
    _batteryIcon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.90];
    _batteryIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_batteryIcon];

    _batteryLabel = [UILabel new];
    _batteryLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightMedium];
    _batteryLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _batteryLabel.numberOfLines = 1;
    [self addSubview:_batteryLabel];

    _thermalIcon = [UIImageView new];
    if (@available(iOS 15.0, *)) {
        _thermalIcon.image = PGCardSymbol(@"thermometer.medium", 9.0, UIFontWeightMedium);
    }
    if (!_thermalIcon.image) _thermalIcon.image = PGCardSymbol(@"thermometer", 9.0, UIFontWeightMedium);
    _thermalIcon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.88];
    _thermalIcon.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_thermalIcon];

    _thermalLabel = [UILabel new];
    _thermalLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightMedium];
    _thermalLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _thermalLabel.numberOfLines = 1;
    [self addSubview:_thermalLabel];

    _cpuLabel = [UILabel new];
    _cpuLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightMedium];
    _cpuLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _cpuLabel.textAlignment = NSTextAlignmentRight;
    _cpuLabel.numberOfLines = 1;
    [self addSubview:_cpuLabel];

    _separator = [UIView new];
    _separator.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    [self addSubview:_separator];

    // 收起态的播放状态：♪ + 歌名·歌手 + 播放/暂停图标，挤在温度和执行率之间。
    _musicNoteView = [UIImageView new];
    _musicNoteView.image = PGCardSymbol(@"music.note", 8.5, UIFontWeightSemibold);
    _musicNoteView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.80];
    _musicNoteView.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_musicNoteView];

    _musicLabel = [UILabel new];
    _musicLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightMedium];
    _musicLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.90];
    _musicLabel.numberOfLines = 1;
    _musicLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_musicLabel];

    _musicStateView = [UIImageView new];
    _musicStateView.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    _musicStateView.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:_musicStateView];
}

- (void)buildSongSection {
    // 封面用普通容器而不是 UIButton：按钮会把触摸从卡片手势里抢走，
    // 那样"长按整张卡片"在封面上就不成立了。点封面跳 App 改由卡片统一判定落点。
    _artworkContainer = [UIView new];
    _artworkContainer.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    _artworkContainer.userInteractionEnabled = NO;
    _artworkContainer.layer.cornerCurve = kCACornerCurveContinuous;
    _artworkContainer.layer.borderWidth = 1.0 / MAX(UIScreen.mainScreen.scale, 1.0);
    _artworkContainer.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.24].CGColor;
    [self addSubview:_artworkContainer];

    _artworkView = [UIImageView new];
    _artworkView.contentMode = UIViewContentModeScaleAspectFill;
    _artworkView.clipsToBounds = YES;
    _artworkView.userInteractionEnabled = NO;
    [_artworkContainer addSubview:_artworkView];

    _artworkPlaceholder = [UIImageView new];
    _artworkPlaceholder.image = PGCardSymbol(@"music.note", 16.0, UIFontWeightMedium);
    _artworkPlaceholder.tintColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    _artworkPlaceholder.contentMode = UIViewContentModeCenter;
    _artworkPlaceholder.userInteractionEnabled = NO;
    [_artworkContainer addSubview:_artworkPlaceholder];

    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    _titleLabel.textColor = UIColor.whiteColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    _titleLabel.layer.shadowOpacity = 0.45;
    _titleLabel.layer.shadowRadius = 3.0;
    _titleLabel.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    [self addSubview:_titleLabel];

    _artistLabel = [UILabel new];
    _artistLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightRegular];
    _artistLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _artistLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    _artistLabel.layer.shadowOpacity = 0.40;
    _artistLabel.layer.shadowRadius = 3.0;
    _artistLabel.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    [self addSubview:_artistLabel];

    // 歌词：当前行 + 下一行（淡）。长歌名也不会把卡片撑开，最多两行。
    _lyricLabel = [UILabel new];
    _lyricLabel.numberOfLines = 2;
    _lyricLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _lyricLabel.layer.shadowColor = UIColor.blackColor.CGColor;
    _lyricLabel.layer.shadowOpacity = 0.45;
    _lyricLabel.layer.shadowRadius = 3.0;
    _lyricLabel.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    [self addSubview:_lyricLabel];
}

- (void)buildControlsSection {
    _controlsContainer = [UIView new];
    _controlsContainer.hidden = YES;
    [self addSubview:_controlsContainer];

    _progressTrack = [UIView new];
    _progressTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.24];
    _progressTrack.clipsToBounds = YES;
    [_controlsContainer addSubview:_progressTrack];

    _progressFill = [UIView new];
    _progressGradient = [CAGradientLayer layer];
    _progressGradient.colors = @[(__bridge id)[UIColor colorWithWhite:1.0 alpha:0.98].CGColor,
                                 (__bridge id)[UIColor colorWithRed:1.0 green:0.70 blue:0.42 alpha:1.0].CGColor];
    _progressGradient.startPoint = CGPointMake(0.0, 0.5);
    _progressGradient.endPoint = CGPointMake(1.0, 0.5);
    [_progressFill.layer addSublayer:_progressGradient];
    [_progressTrack addSubview:_progressFill];

    _elapsedLabel = [self timeLabelWithAlignment:NSTextAlignmentLeft];
    _remainingLabel = [self timeLabelWithAlignment:NSTextAlignmentRight];
    [_controlsContainer addSubview:_elapsedLabel];
    [_controlsContainer addSubview:_remainingLabel];

    _previousButton = [self buttonWithSymbol:@"backward.fill" pointSize:10.0 action:@selector(tappedPrevious)];
    _nextButton = [self buttonWithSymbol:@"forward.fill" pointSize:10.0 action:@selector(tappedNext)];
    _toggleButton = [self buttonWithSymbol:@"play.fill" pointSize:13.0 action:@selector(tappedToggle)];
    _toggleButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    _toggleButton.layer.borderWidth = 1.0 / MAX(UIScreen.mainScreen.scale, 1.0);
    _toggleButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;

    for (UIButton *button in @[_previousButton, _toggleButton, _nextButton]) {
        [_controlsContainer addSubview:button];
    }
}

- (UILabel *)timeLabelWithAlignment:(NSTextAlignment)alignment {
    UILabel *label = [UILabel new];
    label.font = [UIFont monospacedDigitSystemFontOfSize:8.5 weight:UIFontWeightMedium];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    label.textAlignment = alignment;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    return label;
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol pointSize:(CGFloat)pointSize action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:PGCardSymbol(symbol, pointSize, UIFontWeightSemibold) forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
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
    NSString *resolvedTitle = title.length ? title : @"未播放";
    NSString *resolvedArtist = artist.length ? artist : @"";

    BOOL layoutChanged = NO;
    if (![resolvedTitle isEqualToString:(_shownTitle ?: @"")]) {
        _shownTitle = resolvedTitle;
        _titleLabel.text = resolvedTitle;
        layoutChanged = YES;
    }
    if (![resolvedArtist isEqualToString:(_shownArtist ?: @"")]) {
        _shownArtist = resolvedArtist;
        _artistLabel.text = resolvedArtist;
        _artistLabel.hidden = resolvedArtist.length == 0;
    }

    BOOL hasMedia = title.length > 0 || artist.length > 0;
    _hasMedia = hasMedia;
    _canOpenApp = canOpenApp;

    BOOL playingChanged = (playing != _playing);
    _playing = playing;
    if (playingChanged) [self updateToggleSymbol];
    // 收起态那一行也要跟着更新（歌名 / 播放状态都在这条线上）。
    [self refreshStatusMusicRow];

    // 换曲：请求歌词。同一首反复调用是空操作，provider 自己会去重。
    NSString *trackKey = [NSString stringWithFormat:@"%@|%@", title ?: @"", artist ?: @""];
    if (![trackKey isEqualToString:(_trackKey ?: @"")]) {
        _trackKey = trackKey;
        _lyricPrimary = nil;
        _lyricSecondary = nil;
        // 先清掉上一首的歌词再刷新文案，否则换歌瞬间会闪一下旧歌词。
        [[PGLyricsProvider sharedInstance] requestLyricsForTitle:(hasMedia ? title : nil)
                                                          artist:(hasMedia ? artist : nil)
                                                        duration:duration];
        [self refreshLyricText:YES];
    }

    if (artworkData != _lastArtworkData) {
        [self applyArtworkData:artworkData];
    }

    // 暂停 / 换曲 / 拖动进度：直接对齐；正常播放：只在漂移过大时对齐，避免每秒往回跳。
    BOOL hardSync = playingChanged || fabs(duration - _duration) > 0.5 || !hasMedia;
    if (hardSync) {
        _anchorElapsed = hasMedia ? elapsed : 0.0;
        _anchorTime = CACurrentMediaTime();
    } else if (fabs(elapsed - [self displayedElapsed]) > 0.75) {
        _anchorElapsed = elapsed;
        _anchorTime = CACurrentMediaTime();
    }
    _duration = duration;

    [self refreshProgress];
    if (layoutChanged) [self setNeedsLayout];
}

- (void)applyArtworkData:(NSData *)data {
    _lastArtworkData = data;
    UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
    _artworkView.image = image;
    _artworkView.hidden = (image == nil);
    _artworkPlaceholder.hidden = (image != nil);
    _artworkPlaceholder.image = PGCardSymbol(@"music.note", 16.0, UIFontWeightMedium);
}

- (void)updateToggleSymbol {
    CGFloat textScale = _appliedTextScale > 0.0 ? _appliedTextScale : 1.0;
    UIImage *image = PGCardSymbol(_playing ? @"pause.fill" : @"play.fill", 13.0 * textScale, UIFontWeightBold);
    [_toggleButton setImage:image forState:UIControlStateNormal];
}

/// 收起态那一行里的播放状态：♪ 歌名 · 歌手 + 播放/暂停图标（和 1.1 系列的胶囊一致）。
/// 展开后歌曲区已经把这些信息铺开了，这一小段就让位。
- (void)refreshStatusMusicRow {
    NSString *text = nil;
    if (!_hasMedia) {
        text = @"未播放";
    } else if (_shownTitle.length && _shownArtist.length) {
        text = [NSString stringWithFormat:@"%@ · %@", _shownTitle, _shownArtist];
    } else if (_shownTitle.length) {
        text = _shownTitle;
    } else {
        text = _shownArtist ?: @"未播放";
    }
    if (![text isEqualToString:(_musicLabel.text ?: @"")]) {
        _musicLabel.text = text;
        [self setNeedsLayout];
    }

    // 图标只在"符号或缩放倍数变了"时重建，这方法每 0.25 秒会被叫一次。
    CGFloat textScale = _appliedTextScale > 0.0 ? _appliedTextScale : 1.0;
    NSString *symbol = _hasMedia ? (_playing ? @"pause.fill" : @"play.fill") : nil;
    _musicStateView.hidden = (symbol == nil);
    NSString *key = [NSString stringWithFormat:@"%@/%.2f", symbol ?: @"-", textScale];
    if (![key isEqualToString:(_musicIconKey ?: @"")]) {
        _musicIconKey = key;
        _musicStateView.image = symbol ? PGCardSymbol(symbol, 8.5 * textScale, UIFontWeightBold) : nil;
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
    if (_duration > 0.0) ratio = MIN(1.0, MAX(0.0, [self displayedElapsed] / _duration));
    CGFloat fillWidth = trackWidth * (CGFloat)ratio;
    _progressFill.frame = CGRectMake(0.0, 0.0, fillWidth, trackHeight);
    _progressFill.layer.cornerRadius = trackHeight / 2.0;
    _progressGradient.frame = _progressFill.bounds;
    _progressFill.hidden = fillWidth < 1.0;
}

#pragma mark 歌词

- (void)refreshLyricText:(BOOL)force {
    if (!PGCardShowsLyrics()) {
        _lyricLabel.hidden = YES;
        return;
    }
    _lyricLabel.hidden = NO;

    if (!_hasMedia) {
        [self applyLyricPrimary:@"长按卡片可控制播放" secondary:nil force:force];
        return;
    }

    PGLyricsProvider *provider = PGLyricsProvider.sharedInstance;
    double elapsed = [self displayedElapsed];
    NSString *line = [provider lineAtElapsed:elapsed];
    NSString *next = [provider nextLineAtElapsed:elapsed];

    if (line.length == 0) {
        if (provider.loading) {
            [self applyLyricPrimary:@"正在匹配歌词…" secondary:nil force:force];
        } else if (provider.hasLyrics) {
            [self applyLyricPrimary:nil secondary:nil force:force];
        } else {
            [self applyLyricPrimary:@"暂无歌词" secondary:nil force:force];
            // 失败不等于永远没有：网络抖一下、接口刚超时都会走到这里。
            // 每拍都问一次，provider 内部有 15 秒冷却，不会真的反复打接口。
            if (_hasMedia && _shownTitle.length) {
                [provider requestLyricsForTitle:_shownTitle artist:_shownArtist duration:_duration];
            }
        }
        return;
    }
    [self applyLyricPrimary:line secondary:next force:force];
}

- (void)applyLyricPrimary:(NSString *)primary secondary:(NSString *)secondary force:(BOOL)force {
    if (!force && [primary isEqualToString:(_lyricPrimary ?: @"")] &&
        [secondary isEqualToString:(_lyricSecondary ?: @"")]) {
        return;
    }
    _lyricPrimary = primary;
    _lyricSecondary = secondary;
    [self rebuildLyricAttributedText];
}

- (void)rebuildLyricAttributedText {
    CGFloat textScale = _appliedTextScale > 0.0 ? _appliedTextScale : 1.0;
    if (_lyricPrimary.length == 0 && _lyricSecondary.length == 0) {
        _lyricLabel.attributedText = nil;
        _lyricLabel.text = nil;
        return;
    }

    UIFont *primaryFont = [UIFont systemFontOfSize:11.0 * textScale weight:UIFontWeightMedium];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:(_lyricPrimary ?: @"")];
    [text addAttributes:@{NSFontAttributeName: primaryFont,
                          NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.96]}
                  range:NSMakeRange(0, text.length)];

    if (_lyricSecondary.length > 0) {
        UIFont *secondaryFont = [UIFont systemFontOfSize:9.5 * textScale weight:UIFontWeightRegular];
        NSAttributedString *next =
            [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n%@", _lyricSecondary]
                                            attributes:@{NSFontAttributeName: secondaryFont,
                                                         NSForegroundColorAttributeName:
                                                             [UIColor colorWithWhite:1.0 alpha:0.52]}];
        [text appendAttributedString:next];
    }
    _lyricLabel.attributedText = text;
}

#pragma mark 状态行

- (BOOL)refreshClock {
    if (!_clockFormatter) {
        _clockFormatter = [NSDateFormatter new];
        _clockFormatter.locale = [NSLocale currentLocale];
    }
    NSString *format = PerfectGrabberPreferences.sharedPreferences.disable24Hour ? @"h:mm a" : @"HH:mm";
    if (![_clockFormatter.dateFormat isEqualToString:format]) _clockFormatter.dateFormat = format;

    NSString *text = [_clockFormatter stringFromDate:NSDate.date];
    if ([text isEqualToString:(_clockLabel.text ?: @"")]) return NO;
    _clockLabel.text = text;
    return YES;
}

- (BOOL)refreshBattery {
    NSInteger percent = 0;
    BOOL charging = NO;

    Class controllerClass = NSClassFromString(@"SBUIController");
    if ([controllerClass respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [controllerClass sharedInstance];
        if ([controller respondsToSelector:@selector(batteryCapacityAsPercentage)]) {
            percent = MAX(0, MIN(100, [controller batteryCapacityAsPercentage]));
        }
        if ([controller respondsToSelector:@selector(isOnAC)]) charging = [controller isOnAC];
    } else {
        UIDevice.currentDevice.batteryMonitoringEnabled = YES;
        CGFloat level = UIDevice.currentDevice.batteryLevel;
        percent = level < 0 ? 0 : (NSInteger)lround(level * 100.0);
        UIDeviceBatteryState state = UIDevice.currentDevice.batteryState;
        charging = state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
    }

    BOOL changed = NO;
    NSString *text = [NSString stringWithFormat:@"%ld%%", (long)percent];
    if (![text isEqualToString:(_batteryLabel.text ?: @"")]) {
        _batteryLabel.text = text;
        changed = YES;
    }
    if (_boltIcon.hidden == charging) {
        _boltIcon.hidden = !charging;
        changed = YES;
    }

    NSString *symbol = @"battery.100";
    if (percent <= 5) symbol = @"battery.0";
    else if (percent <= 35) symbol = @"battery.25";
    else if (percent <= 60) symbol = @"battery.50";
    else if (percent <= 85) symbol = @"battery.75";
    if (![symbol isEqualToString:(_batterySymbol ?: @"")]) {
        _batterySymbol = symbol;
        _batteryIcon.image = PGCardSymbol(symbol, 12.0, UIFontWeightRegular);
        changed = YES;
    }
    return changed;
}

- (BOOL)refreshMetrics {
    BOOL changed = NO;
    double celsius = PGBatteryTemperatureCelsius();
    NSString *thermal = isnan(celsius) ? @"--" : [NSString stringWithFormat:@"%.1f\u00B0C", celsius];
    if (![thermal isEqualToString:(_thermalLabel.text ?: @"")]) {
        _thermalLabel.text = thermal;
        changed = YES;
    }

    double usage = PGCPUUsagePercent();
    NSString *cpu = isnan(usage) ? @"CPU --" : [NSString stringWithFormat:@"CPU %2.0f%%", usage];
    if (![cpu isEqualToString:(_cpuLabel.text ?: @"")]) {
        _cpuLabel.text = cpu;
        changed = YES;
    }
    return changed;
}

#pragma mark 计时

- (void)startTicking {
    if (_tickTimer) return;
    [self refreshClock];
    [self refreshBattery];
    [self refreshMetrics];
    [self refreshLyricText:YES];
    [self setNeedsLayout];
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *fireTimer) {
        [weakSelf handleTick];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    _tickTimer = timer;
}

- (void)stopTicking {
    [_tickTimer invalidate];
    _tickTimer = nil;
}

- (void)handleTick {
    _tickCount++;
    BOOL statusChanged = [self refreshClock];
    if (_tickCount % 2 == 1) statusChanged = [self refreshMetrics] || statusChanged;   // 1 秒一次
    if (_tickCount % 4 == 1) statusChanged = [self refreshBattery] || statusChanged;   // 2 秒一次
    // 只有文字宽度真的变了才重排：状态行是按文字量宽排的，不变就不用动。
    if (statusChanged) [self setNeedsLayout];
    [self refreshProgress];
    [self refreshLyricText:NO];
}

#pragma mark 交互

- (void)setControlsVisible:(BOOL)visible animated:(BOOL)animated {
    if (_controlsVisible == visible) return;
    _controlsVisible = visible;
    _controlsContainer.userInteractionEnabled = visible;
    // 背景跟着一起换：收起是纯色 / 透明，展开整卡毛玻璃。和高度动画同时进行。
    [self applyBackgroundStyleAnimated:animated];
    // 收起态的卡片只有状态行那么高，分隔线正好压在底边上（看起来像一条脏边）→ 收起时直接藏掉。
    _separator.hidden = !visible;
    // 状态行里的播放状态只在收起态显示（展开后由下面的歌曲区承担），需要重排一次。
    [self setNeedsLayout];

    if (visible) {
        _controlsContainer.hidden = NO;
        _controlsContainer.alpha = 0.0;
    }
    void (^animations)(void) = ^{
        self->_controlsContainer.alpha = visible ? 1.0 : 0.0;
    };
    if (!animated) {
        animations();
        _controlsContainer.hidden = !visible;
        return;
    }
    [UIView animateWithDuration:0.18
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:animations
                     completion:^(BOOL finished) {
        // 用当前状态而不是捕获值：动画途中又展开时，别被上一次的 completion 藏回去。
        if (!self->_controlsVisible) self->_controlsContainer.hidden = YES;
    }];
}

- (void)tappedPrevious {
    if (self.onPrevious) self.onPrevious();
}

- (void)tappedToggle {
    if (self.onToggle) self.onToggle();
}

- (void)tappedNext {
    if (self.onNext) self.onNext();
}

/// 点按落点判定：点在封面上且确实在放歌 → 跳回播放器（返回 YES，调用方不再处理）。
/// 卡片是普通视图，手势统一在宿主 PGLandscapeBar 里，所以这里只做几何判断。
/// 收起态整张卡只有状态行，封面根本不可见 —— 这时候点哪儿都应该是"展开"，不能吃掉这次点按。
- (BOOL)handleTapAtPoint:(CGPoint)point {
    if (!_controlsVisible) return NO;
    if (!_canOpenApp) return NO;
    if (!CGRectContainsPoint(_artworkContainer.frame, point)) return NO;
    if (self.onOpenApplication) self.onOpenApplication();
    return YES;
}

#pragma mark 外观

/// 系统材质的模糊半径是固定的（UltraThin 大概 20 出头），拉到 38 才有真正的毛玻璃观感。
/// 走 UIVisualEffectView 内部的 `_UIVisualEffectBackdropView`，把 CAFilter 数组挂在 `filters` 上。
/// 全是私有层级，类名 / key / filter 名任何一个对不上就什么都不做 —— 每一步都包 @try，
/// 在 SpringBoard 里崩一次就是安全模式，不能赌。
- (BOOL)boostBackdropBlur:(CGFloat)radius {
    UIView *backdrop = [self backdropViewInView:_blurView depth:4];
    if (!backdrop) return NO;
    @try {
        id filters = [backdrop valueForKey:@"filters"];
        NSMutableArray *updated = [NSMutableArray array];
        BOOL hasBlur = NO;
        BOOL hasSaturate = NO;
        if ([filters isKindOfClass:[NSArray class]]) {
            for (id filter in (NSArray *)filters) {
                NSString *name = nil;
                @try {
                    name = [filter valueForKey:@"name"];
                } @catch (NSException *exception) {
                    (void)exception;
                }
                if ([name isKindOfClass:[NSString class]]) {
                    if ([name rangeOfString:@"blur" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        @try {
                            [filter setValue:@(radius) forKey:@"inputRadius"];
                            hasBlur = YES;
                        } @catch (NSException *exception) {
                            (void)exception;
                        }
                    } else if ([name rangeOfString:@"Saturate" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        hasSaturate = YES;
                    }
                }
                [updated addObject:filter];
            }
        }
        if (!hasBlur) return NO;
        // 通透的第二个关键：ultraThin 会把背后的游戏画面洗成灰，补一个 colorSaturate 把颜色拉回来。
        if (!hasSaturate) {
            @try {
                Class filterClass = NSClassFromString(@"CAFilter");
                if (filterClass) {
                    id saturate = ((id (*)(id, SEL, NSString *))objc_msgSend)(
                        filterClass, NSSelectorFromString(@"filterWithName:"), @"colorSaturate");
                    if (saturate) {
                        [saturate setValue:@1.35 forKey:@"inputSaturation"];
                        [updated addObject:saturate];
                    }
                }
            } @catch (NSException *exception) {
                (void)exception;
            }
        }
        [backdrop setValue:updated forKey:@"filters"];
        return YES;
    } @catch (NSException *exception) {
        (void)exception;
        return NO;
    }
}

- (UIView *)backdropViewInView:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth < 0) return nil;
    NSString *className = NSStringFromClass(view.class);
    if ([className rangeOfString:@"backdrop" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *found = [self backdropViewInView:subview depth:depth - 1];
        if (found) return found;
    }
    return nil;
}

/// 背景只有两态，切换点就是"展开 / 收起"：
///   收起 = 一块纯色（颜色取设置里的「玻璃色调」）；把「收起时纯色背景」关掉就完全透明，只留文字。
///   展开 = 整卡毛玻璃（模糊 + 色调 + 高光），这样展开时三层信息压在同一块玻璃上，不会一段一种底色。
- (void)applyBackgroundStyleAnimated:(BOOL)animated {
    BOOL expanded = _controlsVisible;
    BOOL solidEnabled = PGCardCollapsedSolidEnabled();
    CGFloat opacity = PGCardGlassOpacity();

    _solidView.backgroundColor = [PGCardTintColor() colorWithAlphaComponent:0.92];
    _backgroundExpanded = expanded;
    _appliedSolidEnabled = solidEnabled;

    void (^apply)(void) = ^{
        self->_solidView.alpha = (expanded || !solidEnabled) ? 0.0 : 1.0;
        self->_blurView.alpha = expanded ? opacity : 0.0;
        self->_tintView.alpha = expanded ? 1.0 : 0.0;
        self->_sheenView.alpha = expanded ? 1.0 : 0.0;
    };

    if (!animated) {
        apply();
        return;
    }
    [UIView animateWithDuration:0.18
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:apply
                     completion:nil];
}

- (void)applyGlassIfNeeded {
    CGFloat blur = PGCardBlurRadius();
    CGFloat opacity = PGCardGlassOpacity();
    UIColor *tint = PGCardTintColor();

    // ⚠️ 不能用 tint.redComponent：灰度色的 getRed 会抛异常。统一走 getRed:green:blue:alpha:。
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    NSString *tintKey = @"-";
    if ([tint getRed:&red green:&green blue:&blue alpha:&alpha]) {
        tintKey = [NSString stringWithFormat:@"%.3f/%.3f/%.3f/%.3f", red, green, blue, alpha];
    }

    BOOL toneChanged = fabs(opacity - _appliedOpacity) >= 0.01 ||
                       ![tintKey isEqualToString:(_appliedTintKey ?: @"")];
    BOOL blurChanged = fabs(blur - _appliedBlur) >= 0.5;

    if (toneChanged) {
        _appliedOpacity = opacity;
        _appliedTintKey = tintKey;
        // 收起态玻璃整体不可见，这里只在展开态给浓度 —— 否则拖一下滑块收起态就透出模糊底。
        _blurView.alpha = _controlsVisible ? opacity : 0.0;
        // 越不透明，色调越明显；玻璃很透的时候只留一丝色偏，别把游戏画面糊成一块。
        _tintView.backgroundColor = [tint colorWithAlphaComponent:0.10 + 0.30 * opacity];
        _tintGradient.colors = @[(__bridge id)[tint colorWithAlphaComponent:0.0].CGColor,
                                 (__bridge id)[tint colorWithAlphaComponent:0.0].CGColor,
                                 (__bridge id)[tint colorWithAlphaComponent:0.20].CGColor];
    }

    // 模糊半径只能在 backdrop 已经建出来之后才设得进去；建不出来就先不记账，等下一拍再试。
    if (blurChanged && (blur <= 0.5 || [self boostBackdropBlur:blur])) {
        _appliedBlur = blur;
    }
}

#pragma mark 布局

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (width <= 0.0 || height <= 0.0) return;

    CGFloat s = width / PGCardDesignWidth;
    if (!isfinite(s) || s <= 0.0) s = 1.0;
    CGFloat textScale = sqrt(s);

    _solidView.frame = self.bounds;
    _blurView.frame = self.bounds;
    _tintView.frame = self.bounds;
    _tintGradient.frame = _tintView.bounds;
    _sheenView.frame = self.bounds;
    _sheenGradient.frame = _sheenView.bounds;

    [self applyGlassIfNeeded];
    // 色调 / 「收起时纯色背景」开关可能刚被改过（设置页拖动），而展开状态没变 —— 也要立刻跟上。
    _solidView.backgroundColor = [PGCardTintColor() colorWithAlphaComponent:0.92];
    if (_backgroundExpanded != _controlsVisible ||
        _appliedSolidEnabled != PGCardCollapsedSolidEnabled()) {
        [self applyBackgroundStyleAnimated:NO];
    }
    [self applyScale:s textScale:textScale];

    CGFloat pad = PGCardPadding * s;
    CGFloat scale = MAX(UIScreen.mainScreen.scale, 1.0);

    // ① 状态行
    [self layoutStatusRowWithWidth:width padding:pad scale:s];

    _separator.frame = CGRectMake(pad, 26.0 * s, MAX(0.0, width - 2.0 * pad), 1.0 / scale);

    // ② 歌曲区
    CGFloat artSize = PGCardArtworkSize * s;
    CGFloat artY = 33.0 * s;
    _artworkContainer.frame = CGRectMake(pad, artY, artSize, artSize);
    _artworkContainer.layer.cornerRadius = 10.0 * s;
    _artworkView.frame = _artworkContainer.bounds;
    _artworkView.layer.cornerRadius = 10.0 * s;
    _artworkPlaceholder.frame = _artworkContainer.bounds;

    CGFloat textX = pad + artSize + 10.0 * s;
    CGFloat textWidth = MAX(0.0, width - pad - textX);
    _titleLabel.frame = CGRectMake(textX, artY - 2.0 * s, textWidth, 16.0 * s);
    _artistLabel.frame = CGRectMake(textX, artY + 14.0 * s, textWidth, 13.0 * s);
    _lyricLabel.frame = CGRectMake(textX, artY + 27.0 * s, textWidth, 27.0 * s);

    // ③ 播放控制区（高度由宿主的卡片尺寸决定，这里只排内部）
    CGFloat controlsTop = PGCardControlsOffset * s;
    _controlsContainer.frame = CGRectMake(0.0, controlsTop, width,
                                          MAX(0.0, height - controlsTop));
    CGFloat innerWidth = MAX(0.0, width - 2.0 * pad);
    _progressTrack.frame = CGRectMake(pad, 4.0 * s, innerWidth, 3.0 * s);
    _progressTrack.layer.cornerRadius = 1.5 * s;
    [self layoutProgressFill];

    CGFloat timeY = 9.0 * s;
    CGFloat timeWidth = 44.0 * s;
    _elapsedLabel.frame = CGRectMake(pad, timeY, timeWidth, 10.0 * s);
    _remainingLabel.frame = CGRectMake(width - pad - timeWidth, timeY, timeWidth, 10.0 * s);

    CGFloat toggleSize = 32.0 * s;
    CGFloat sideSize = 24.0 * s;
    CGFloat gap = 18.0 * s;
    CGFloat centerY = 36.0 * s;
    CGFloat total = sideSize * 2.0 + toggleSize + gap * 2.0;
    CGFloat originX = (width - total) / 2.0;
    _previousButton.frame = CGRectMake(originX, centerY - sideSize / 2.0, sideSize, sideSize);
    _toggleButton.frame = CGRectMake(originX + sideSize + gap, centerY - toggleSize / 2.0,
                                     toggleSize, toggleSize);
    _nextButton.frame = CGRectMake(originX + sideSize + gap + toggleSize + gap,
                                   centerY - sideSize / 2.0, sideSize, sideSize);
    _toggleButton.layer.cornerRadius = toggleSize / 2.0;
    _toggleButton.layer.cornerCurve = kCACornerCurveContinuous;

    self.layer.cornerRadius = MIN(PGCardCornerRadius * s, height / 2.0);
}

- (void)layoutStatusRowWithWidth:(CGFloat)width padding:(CGFloat)pad scale:(CGFloat)s {
    CGFloat y = 6.0 * s;
    CGFloat h = 15.0 * s;
    CGFloat x = pad;
    CGFloat right = width - pad;

    CGSize clockSize = [_clockLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)];
    _clockLabel.frame = CGRectMake(x, y, ceil(clockSize.width) + 1.0, h);
    x = CGRectGetMaxX(_clockLabel.frame) + 9.0 * s;

    CGFloat iconHeight = 11.0 * s;
    if (!_boltIcon.hidden) {
        _boltIcon.frame = CGRectMake(x, y + (h - iconHeight) / 2.0, 8.0 * s, iconHeight);
        x += 8.0 * s + 1.0 * s;
    } else {
        _boltIcon.frame = CGRectZero;
    }

    _batteryIcon.frame = CGRectMake(x, y + (h - iconHeight) / 2.0, 22.0 * s, iconHeight);
    x += 22.0 * s + 2.0 * s;

    CGSize batterySize = [_batteryLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)];
    _batteryLabel.frame = CGRectMake(x, y, ceil(batterySize.width) + 1.0, h);
    x = CGRectGetMaxX(_batteryLabel.frame) + 9.0 * s;

    CGFloat thermalHeight = 10.0 * s;
    _thermalIcon.frame = CGRectMake(x, y + (h - thermalHeight) / 2.0, 9.0 * s, thermalHeight);
    x += 9.0 * s + 1.0 * s;

    CGSize thermalSize = [_thermalLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)];
    _thermalLabel.frame = CGRectMake(x, y, ceil(thermalSize.width) + 1.0, h);
    x = CGRectGetMaxX(_thermalLabel.frame);

    // 执行率先排（右对齐），中间剩下的宽度全部留给播放状态。
    CGSize cpuSize = [_cpuLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)];
    CGFloat cpuWidth = MIN(ceil(cpuSize.width) + 1.0, MAX(0.0, right - pad));
    _cpuLabel.frame = CGRectMake(right - cpuWidth, y, cpuWidth, h);

    // 播放状态：♪ + 歌名·歌手 + 播放/暂停图标。展开后歌曲区已经铺开这些信息，这一小段藏掉。
    BOOL showMusic = (!_controlsVisible && _musicLabel.text.length > 0);
    if (!showMusic) {
        _musicNoteView.hidden = YES;
        _musicLabel.hidden = YES;
        _musicNoteView.frame = CGRectZero;
        _musicLabel.frame = CGRectZero;
        _musicStateView.frame = CGRectZero;
        return;
    }

    CGFloat musicLeft = x + 9.0 * s;
    CGFloat musicRight = CGRectGetMinX(_cpuLabel.frame) - 9.0 * s;
    CGFloat noteWidth = 9.0 * s;
    CGFloat stateWidth = 9.0 * s;
    CGFloat spacing = 3.0 * s;
    // 窄到放不下图标 + 一个字符就整段不画，别把执行率挤出去。
    if (musicRight - musicLeft < noteWidth + stateWidth + spacing * 2.0 + 8.0 * s) {
        _musicNoteView.hidden = YES;
        _musicLabel.hidden = YES;
        _musicStateView.hidden = YES;
        _musicNoteView.frame = CGRectZero;
        _musicLabel.frame = CGRectZero;
        _musicStateView.frame = CGRectZero;
        return;
    }

    _musicNoteView.hidden = NO;
    _musicLabel.hidden = NO;

    CGFloat musicIconHeight = 10.0 * s;
    _musicNoteView.frame = CGRectMake(musicLeft, y + (h - musicIconHeight) / 2.0,
                                      noteWidth, musicIconHeight);
    CGFloat stateX = musicRight - stateWidth;
    _musicStateView.frame = CGRectMake(stateX, y + (h - musicIconHeight) / 2.0,
                                       stateWidth, musicIconHeight);

    CGFloat labelX = musicLeft + noteWidth + spacing;
    CGFloat labelRight = _musicStateView.hidden ? musicRight : (stateX - spacing);
    _musicLabel.frame = CGRectMake(labelX, y, MAX(0.0, labelRight - labelX), h);
}

- (void)applyScale:(CGFloat)scale textScale:(CGFloat)textScale {
    BOOL sizeChanged = fabs(_appliedScale - scale) > 0.001;
    BOOL textChanged = fabs(_appliedTextScale - textScale) > 0.001;
    if (!sizeChanged && !textChanged) return;

    _appliedScale = scale;
    _appliedTextScale = textScale;

    _clockLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 * textScale weight:UIFontWeightSemibold];
    _batteryLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 * textScale weight:UIFontWeightMedium];
    _thermalLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 * textScale weight:UIFontWeightMedium];
    _cpuLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 * textScale weight:UIFontWeightMedium];
    _musicLabel.font = [UIFont systemFontOfSize:10.0 * textScale weight:UIFontWeightMedium];
    _musicNoteView.image = PGCardSymbol(@"music.note", 8.5 * textScale, UIFontWeightSemibold);
    // 倍数变了图标要按新字号重画：清掉缓存键，下一拍 refreshStatusMusicRow 会重建。
    _musicIconKey = nil;

    _titleLabel.font = [UIFont systemFontOfSize:12.5 * textScale weight:UIFontWeightSemibold];
    _artistLabel.font = [UIFont systemFontOfSize:10.0 * textScale weight:UIFontWeightRegular];

    _elapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:8.5 * textScale weight:UIFontWeightMedium];
    _remainingLabel.font = _elapsedLabel.font;

    CGFloat shadowRadius = 3.0 * textScale;
    // 收起态可以被设成"完全透明"，这时文字直接压在游戏画面上 —— 状态行那几个 label
    // 也必须有投影，否则遇到浅色场景（海面、雪地）就糊成一片看不见。
    for (UILabel *label in @[_clockLabel, _batteryLabel, _thermalLabel, _cpuLabel, _musicLabel,
                             _titleLabel, _artistLabel, _lyricLabel]) {
        label.layer.shadowRadius = shadowRadius;
        label.layer.shadowOffset = CGSizeMake(0.0, textScale);
    }

    [self setSymbol:@"backward.fill" onButton:_previousButton pointSize:10.0 * textScale];
    [self setSymbol:@"forward.fill" onButton:_nextButton pointSize:10.0 * textScale];
    [self setSymbol:(_playing ? @"pause.fill" : @"play.fill")
           onButton:_toggleButton pointSize:13.0 * textScale];

    [self rebuildLyricAttributedText];
}

- (void)setSymbol:(NSString *)symbol onButton:(UIButton *)button pointSize:(CGFloat)pointSize {
    [button setImage:PGCardSymbol(symbol, pointSize, UIFontWeightSemibold) forState:UIControlStateNormal];
}

@end

/// 承载卡片的容器。窗口尺寸一变（旋转）UIKit 就会同步回调 layoutSubviews，
/// 卡片在旋转动画的每一帧都贴在正确的边上，不会出现"先错位、等下一次轮询才跳回来"的闪动。
@class PGLandscapeBar;

@interface PGLandscapeBar (PGPlacement)
- (void)placeCardInBounds:(CGRect)bounds;
@end

@interface PGLandscapeHostView : UIView
@property (nonatomic, weak, nullable) PGLandscapeBar *bar;
@end

@implementation PGLandscapeHostView

- (void)layoutSubviews {
    [super layoutSubviews];
    [self.bar placeCardInBounds:self.bounds];
}

@end

/// 显示 + 只放行卡片上的触摸，其它位置全部穿透给底下的游戏。
///
/// 1.1-38 起不再有"点面板外面收起"这条路：实机上那条链路（手势、命中测试、
/// 透明全屏拦截层、sendEvent 落点判定）反复验证都拿不到触摸事件 ——
/// 日志里连一条痕迹都没有，说明事件在进窗口之前就被别的进程窗口分走了。
/// 现在播放控制默认隐藏，长按整张卡片展开，松手 3 秒后自动收起。
@interface PGLandscapeBarWindow : UIWindow
@property (nonatomic, weak, nullable) UIView *cardHitArea;
@end

@implementation PGLandscapeBarWindow

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (BOOL)canBecomeFocused {
    return NO;
}

/// 这个窗口铺满全屏，如果正常参与命中测试会把游戏的触摸全部吃掉。
/// 只把落在卡片里的点交出去，其余返回 nil —— UIKit 会继续往下层窗口投递。
///
/// 这里刻意保持"最笨"的写法：让 UIKit 自己做命中测试，再判断结果属于哪个子视图。
/// 之前几版尝试过“面板展开时无条件兜住触摸”的各种变体，实机上都出现过
/// 拿不到事件、或者反过来把整屏吃掉的情况，不如老老实实穿透。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self) return nil;

    UIView *card = self.cardHitArea;
    if (card && !card.hidden && [hit isDescendantOfView:card]) return hit;

    return nil;
}

@end

/// 承载窗口所在场景。
///
/// ⚠️ 必须优先挑 **ForegroundActive** 那个。以前是"第一个不是 Unattached 的就用"，
/// 于是切过别的 App 再回来时，很容易挑到留在后台的旧场景 —— 窗口挂上去以后
/// `hidden = NO` 也不会渲染，表现就是"回到游戏，卡片再也不出来了"。
static UIWindowScene *PGLandscapeHostScene(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindowScene *active = nil;
    UIWindowScene *inactive = nil;
    UIWindowScene *background = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        switch (windowScene.activationState) {
            case UISceneActivationStateForegroundActive:
                if (!active) active = windowScene;
                break;
            case UISceneActivationStateForegroundInactive:
                if (!inactive) inactive = windowScene;
                break;
            case UISceneActivationStateBackground:
                if (!background) background = windowScene;
                break;
            default:
                break;
        }
    }
    if (active) return active;
    if (inactive) return inactive;
    if (background) return background;

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

#pragma mark - 当前前台 App

/// 当前前台 App 的 bundle id。
///
/// ⚠️ 这里必须全程**后台线程**探测。1.1-25 就是在 SpringBoard 主线程上直接调
/// `SBSCopyFrontmostApplicationDisplayIdentifier()`（同步 XPC）把整台手机锁死的：
/// 那类"问系统当前前台是谁"的接口会等一个只有 SpringBoard 主线程才能回的答复，
/// 主线程自己在那儿等 → 直接自锁，连设置里的开关都点不动。
/// 现在主线程只读缓存，探测全部扔进自己的串行队列。
///
/// 两路探针（都跑在后台队列）：
///   1) FrontBoardServices 的 display layout —— SpringBoard 自己就是靠它知道"屏幕上显示的是谁"
///   2) LSApplicationWorkspace.frontmostApplication（老实现，留作兜底）
///
/// ⚠️ 关键：返回值现在有三种语义，不能再用 "nil = 放行" 糊过去。
/// iPhone 桌面本身不支持横屏，但用户把手机横过来时重力是横的 —— 插件照样会算出"横屏"。
/// 1.1-26 之前桌面上布局里没有 App 元素 → 探针返回 nil → 按"探针失败"放行，
/// 于是**桌面横屏也会显示横屏块**。现在把"最高层是 SpringBoard 自己"明确识别成桌面。
typedef NS_ENUM(NSInteger, PGFrontmostKind) {
    PGFrontmostKindUnknown = 0,     ///< 这一拍没拿到任何信息（过渡态 / 探针不可用）
    PGFrontmostKindApp,             ///< 拿到了某个 App，identifier 有效
    PGFrontmostKindHomeScreen,      ///< 明确在桌面 / 锁屏 / 通知中心（最高层是 SpringBoard）
};

static NSString *const PGFrontmostLockToken = @"PGFrontmostLock";

static dispatch_queue_t PGFrontmostQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.netskao.perfectgrabber.frontmost", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *PGFrontmostCached = nil;
static BOOL PGFrontmostCachedHomeScreen = NO;
/// 本次 SpringBoard 生命周期内是否成功解析过前台身份（App 或桌面）。
/// 用来区分两种 nil：探针坏了（从未成功）vs. 刚从 App 退回桌面（成功过，只是这一拍没有 App）。
static BOOL PGFrontmostEverResolved = NO;
static CFTimeInterval PGFrontmostCachedAt = 0.0;
static CFTimeInterval PGFrontmostRequestedAt = 0.0;
static BOOL PGFrontmostProbing = NO;
static CFTimeInterval PGFrontmostProbeStartedAt = 0.0;
/// 探针线程一旦卡死就先停一段时间（不是永久停）。
/// 1.1-34 之前这里是"本次进程内不再探测"：游戏里某次切换让这一路 XPC 卡了 2.5 秒，
/// 之后就永远是 Unknown —— 开了白名单的话等于横屏块被永久吞掉（"点了几下横屏就不见了"）。
/// 现在改成冷却 15 秒后重试一次，卡死的代价只是偶发一次 2.5 秒的等待。
static BOOL PGFrontmostQueueStuck = NO;
static CFTimeInterval PGFrontmostStuckAt = 0.0;

/// 探针 1：FBS display layout。只读 currentLayout，不装 transitionHandler
/// （block 签名对不上会崩），创建一次后复用。
///
/// 返回**层级最高的那个元素**的 bundle id —— 包括 SpringBoard 自己。
/// 有 App 在前台时 App 元素的 level 高于 SpringBoard 的桌面元素，赢的是 App；
/// 回到桌面后 App 元素消失，赢的就是 `com.apple.springboard`，调用方据此判定"在桌面"。
static NSString *PGFrontmostFromDisplayLayout(void) {
    static id monitor = nil;
    static CFTimeInterval monitorCreatedAt = 0.0;
    static CFTimeInterval lastUsableAt = 0.0;
    static CFTimeInterval lastRebuildAt = 0.0;
    static NSInteger rebuildCount = 0;

    CFTimeInterval now = CACurrentMediaTime();

    // ⚠️ 注销（respring）刚起来时，插件会被很早唤醒一次：那一刻 FrontBoard 还没准备好，
    // monitor.currentLayout 会一直是 nil —— 而且它"只在有变化时推送"，桌面上什么都不变，
    // 于是这个 nil 会一直挂到某个 App 启动为止。
    // 这正是"刚注销、没打开任何 App 时，桌面横过来会冒出横屏块；开个 App 再回桌面就正常"的成因。
    //
    // 更隐蔽的一种：currentLayout 有值，但 elements 是空数组。游戏切前后台之后 FBS 偶尔会
    // 停在这个状态并且不再推送 —— 以前只在"从未拿到布局"时重建 monitor，拿到过一次就再也不换，
    // 于是这一路永久返回 nil → 永久 Unknown → 横屏卡片再也不出来。
    // 现在"连续 2 秒拿不到非空布局"就换一个新 monitor（5 秒冷却，不限次数）。
    BOOL stale = (lastUsableAt <= 0.0 && now - monitorCreatedAt > 2.0) ||
                 (lastUsableAt > 0.0 && now - lastUsableAt > 2.0);
    BOOL canRebuild = (lastRebuildAt <= 0.0 || now - lastRebuildAt > 5.0);
    if (monitor && stale && canRebuild) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(monitor, @selector(invalidate));
        } @catch (NSException *exception) {
            (void)exception;
        }
        monitor = nil;
        rebuildCount++;
        lastRebuildAt = now;
        lastUsableAt = 0.0;
        PGLog(@"白名单探针: 布局 2 秒没拿到有效元素，重建 monitor（第 %ld 次）", (long)rebuildCount);
    }

    if (!monitor) {
        monitorCreatedAt = now;
        @try {
            Class configClass = NSClassFromString(@"FBSDisplayLayoutMonitorConfiguration");
            Class monitorClass = NSClassFromString(@"FBSDisplayLayoutMonitor");
            if (!configClass || !monitorClass) {
                dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
                configClass = NSClassFromString(@"FBSDisplayLayoutMonitorConfiguration");
                monitorClass = NSClassFromString(@"FBSDisplayLayoutMonitor");
            }
            if (configClass && monitorClass) {
                id config = ((id (*)(id, SEL))objc_msgSend)(
                    configClass, @selector(configurationForDefaultMainDisplayMonitor));
                if (config) {
                    monitor = ((id (*)(id, SEL, id))objc_msgSend)(
                        monitorClass, @selector(monitorWithConfiguration:), config);
                }
            }
        } @catch (NSException *exception) {
            monitor = nil;
        }
        PGLog(@"白名单探针: FBS 显示布局 %@", monitor ? @"可用" : @"不可用");
    }
    if (!monitor) return nil;

    id layout = nil;
    @try {
        layout = ((id (*)(id, SEL))objc_msgSend)(monitor, @selector(currentLayout));
    } @catch (NSException *exception) {
        layout = nil;
    }
    if (!layout) return nil;

    NSArray *elements = nil;
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)(layout, @selector(elements));
        if ([value isKindOfClass:[NSArray class]]) elements = value;
    } @catch (NSException *exception) {
        elements = nil;
    }
    // 必须有元素才算"这一路可用"：空数组同样说明探针废了，交给上面的重建逻辑换 monitor。
    if (elements.count == 0) return nil;
    lastUsableAt = now;

    NSString *winner = nil;
    double winnerLevel = -1.0e9;
    NSUInteger appElementCount = 0;
    for (id element in elements) {
        NSString *identifier = nil;
        double level = 0.0;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(element, @selector(bundleIdentifier));
            if ([value isKindOfClass:[NSString class]]) identifier = value;
            // level 是 CGFloat 返回值，必须按浮点签名接，用 id 接会读到垃圾寄存器。
            if ([element respondsToSelector:@selector(level)]) {
                level = ((double (*)(id, SEL))objc_msgSend)(element, @selector(level));
            }
        } @catch (NSException *exception) {
            continue;
        }
        if (identifier.length == 0) continue;
        if (![identifier isEqualToString:@"com.apple.springboard"]) appElementCount++;
        if (level >= winnerLevel) {
            winnerLevel = level;
            winner = identifier;
        }
    }

    // 只在层级归属变化时打一行，方便排查"桌面上为什么还显示"。
    static NSString *lastWinner = nil;
    static NSUInteger lastAppCount = NSUIntegerMax;
    if (![lastWinner isEqualToString:winner] || lastAppCount != appElementCount) {
        lastWinner = winner;
        lastAppCount = appElementCount;
        PGLog(@"白名单探针: 布局最高层=%@ level=%.1f App元素=%lu 个",
              winner ?: @"(无)", winnerLevel, (unsigned long)appElementCount);
    }
    return winner;
}

/// 探针 2：老实现，留作最后兜底。
static NSString *PGFrontmostFromWorkspace(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return nil;

    id workspace = nil;
    @try {
        workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));
    } @catch (NSException *exception) {
        workspace = nil;
    }
    if (!workspace) return nil;

    SEL frontSelector = @selector(frontmostApplication);
    if (![(NSObject *)workspace respondsToSelector:frontSelector]) return nil;

    NSString *identifier = nil;
    @try {
        id application = ((id (*)(id, SEL))objc_msgSend)(workspace, frontSelector);
        if (application) {
            id value = ((id (*)(id, SEL))objc_msgSend)(application, @selector(bundleIdentifier));
            if ([value isKindOfClass:[NSString class]]) identifier = value;
        }
    } @catch (NSException *exception) {
        identifier = nil;
    }
    return identifier;
}

/// 只在探针队列里跑。
static void PGFrontmostProbeNow(void) {
    @autoreleasepool {
        NSString *identifier = PGFrontmostFromDisplayLayout();
        NSString *source = identifier.length ? @"FBS" : nil;

        // 布局里最顶层是 SpringBoard 自己 → 桌面 / 锁屏 / 通知中心。
        // 这时候不要再拿 LS 的残留结果去覆盖，否则会把"上一个 App"当现状。
        BOOL homeScreen = [identifier isEqualToString:@"com.apple.springboard"];
        if (homeScreen) identifier = nil;

        if (identifier.length == 0 && !homeScreen) {
            identifier = PGFrontmostFromWorkspace();
            if (identifier.length) source = @"LS";
            // LS 在桌面上也可能直接给 springboard，一并归一成桌面。
            if ([identifier isEqualToString:@"com.apple.springboard"]) {
                identifier = nil;
                homeScreen = YES;
            }
        }

        static NSString *lastReported = nil;      // 只在探针队列里访问，不用加锁
        static CFTimeInterval lastFailureLog = 0.0;

        @synchronized (PGFrontmostLockToken) {
            PGFrontmostCached = identifier;
            PGFrontmostCachedHomeScreen = homeScreen;
            PGFrontmostCachedAt = CACurrentMediaTime();
            if (identifier.length > 0 || homeScreen) PGFrontmostEverResolved = YES;
            PGFrontmostProbing = NO;
            // 这一路成功回来了，说明队列是通的，清掉"卡死"标记。
            PGFrontmostQueueStuck = NO;
            PGFrontmostProbeStartedAt = 0.0;
        }

        CFTimeInterval now = CACurrentMediaTime();
        if (identifier.length) {
            if (![lastReported isEqualToString:identifier]) {
                lastReported = identifier;
                PGLog(@"白名单探针: 前台 App=%@（来源 %@）", identifier, source);
            }
        } else if (homeScreen) {
            if (![lastReported isEqualToString:@"<home>"]) {
                lastReported = @"<home>";
                PGLog(@"白名单探针: 当前在桌面/锁屏（SpringBoard 在最上层）");
            }
        } else if (now - lastFailureLog > 10.0) {
            lastFailureLog = now;
            lastReported = nil;
            PGLog(@"白名单探针: 两路都取不到任何元素（FBS/LS 全空）");
        }
    }
}

/// 主线程只读缓存（最多 3 秒旧），顺手触发一次后台探测。
/// 探测卡住时会一直停在"进行中"，值自然过期 → 返回 Unknown，
/// 绝不会把 SpringBoard 阻塞在这里。
static PGFrontmostKind PGCurrentFrontmost(NSString **outIdentifier) {
    CFTimeInterval now = CACurrentMediaTime();
    NSString *value = nil;
    PGFrontmostKind kind = PGFrontmostKindUnknown;
    BOOL needProbe = NO;
    BOOL justGotStuck = NO;

    @synchronized (PGFrontmostLockToken) {
        if (PGFrontmostCachedAt > 0.0 && now - PGFrontmostCachedAt < 3.0) {
            if (PGFrontmostCached.length > 0) {
                value = PGFrontmostCached;
                kind = PGFrontmostKindApp;
            } else if (PGFrontmostCachedHomeScreen) {
                kind = PGFrontmostKindHomeScreen;
            }
        }
        if (PGFrontmostProbing && PGFrontmostProbeStartedAt > 0.0 &&
            now - PGFrontmostProbeStartedAt > 2.5) {
            // 探测超过 2.5 秒没回来：那一路多半是同步 XPC 卡住了。直接放弃探测，
            // 靠缓存过期走 Unknown 分支 —— 优先保证系统不卡。
            PGFrontmostProbing = NO;
            PGFrontmostProbeStartedAt = 0.0;
            PGFrontmostQueueStuck = YES;
            PGFrontmostStuckAt = now;
            justGotStuck = YES;
        }
        // 冷却 15 秒后允许再试：卡死的队列自己会恢复，永久放弃等于把功能锁死。
        if (PGFrontmostQueueStuck && now - PGFrontmostStuckAt > 15.0) {
            PGFrontmostQueueStuck = NO;
            PGFrontmostRequestedAt = 0.0;
            PGLog(@"白名单探针: 冷却 15 秒后重新尝试探测");
        }
        if (!PGFrontmostProbing && !PGFrontmostQueueStuck && now - PGFrontmostRequestedAt > 0.20) {
            PGFrontmostProbing = YES;
            PGFrontmostRequestedAt = now;
            PGFrontmostProbeStartedAt = now;
            needProbe = YES;
        }
    }

    if (justGotStuck) {
        PGLog(@"白名单探针: 上一次探测超过 2.5s 未返回，暂停 15 秒后重试");
    }
    if (needProbe) {
        dispatch_async(PGFrontmostQueue(), ^{
            PGFrontmostProbeNow();
        });
    }
    if (outIdentifier) *outIdentifier = value;
    return kind;
}

/// 探针是否在本次进程里成功解析过。成功过就说明链路是通的，
/// 之后的 Unknown 只能解释成"当前没有前台 App"（桌面过渡、锁屏），而不是"探针坏了"。
static BOOL PGFrontmostHasEverResolved(void) {
    @synchronized (PGFrontmostLockToken) {
        return PGFrontmostEverResolved;
    }
}

/// 本进程第一次用到探针的时刻。刚注销/刚重启的那一两秒里，探针必然还没回来（Unknown），
/// 这段时间用"保持现状"过渡，不要在桌面上闪出一块横屏信息。
static CFTimeInterval PGFrontmostStartedAt(void) {
    static CFTimeInterval start = 0.0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        start = CACurrentMediaTime();
    });
    return start;
}


#pragma mark - 横屏常驻块

@interface PGLandscapeBar () <UIGestureRecognizerDelegate>

@property (nonatomic, strong, nullable) PGLandscapeBarWindow *window;
@property (nonatomic, strong, nullable) PGLandscapeMusicCard *card;
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
/// 当前卡片尺寸。量一次缓存起来，旋转动画期间每帧重排只做几何计算。
@property (nonatomic, assign) CGFloat cardLength;
@property (nonatomic, assign) CGFloat cardThickness;
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
/// 窗口挂错场景的起始时刻（0 = 当前没问题）。确认 0.8 秒才真的重建。
@property (nonatomic, assign) CFTimeInterval sceneMismatchSince;
/// "应该显示、但 showCard 一直没成功"的起始时刻。用来做最后一道看门狗：
/// 连续 2 秒都显示不出来就推倒重来（清时间戳 + 拆窗口 + 立即重建）。
@property (nonatomic, assign) CFTimeInterval showStallSince;
/// 显示/隐藏抖动检测：窗口期内翻转次数，以及熔断到期时间。
@property (nonatomic, assign) NSInteger toggleBurst;
@property (nonatomic, assign) CFTimeInterval burstWindowStart;
@property (nonatomic, assign) CFTimeInterval flickerLockUntil;
/// 最近一次解析结果，供日志/诊断弹窗使用。
@property (nonatomic, copy) NSString *resolvedSource;
@property (nonatomic, copy, nullable) NSString *lastSnapshot;

/// 横屏时唯一的那张卡片（状态行 / 歌曲区 / 控制区）。
@property (nonatomic, assign) BOOL controlsVisible;
@property (nonatomic, strong, nullable) NSTimer *controlsTimer;
/// 双指捏合卡片时的临时倍数（0 = 没在捏，用偏好里的值）。松手后写回偏好再清零。
@property (nonatomic, assign) CGFloat liveCardScale;
/// 捏合开始那一刻的倍数，作为本次缩放的基准（捏合是相对量）。
@property (nonatomic, assign) CGFloat pinchStartScale;
/// 是否已经在监听系统"正在播放"。
@property (nonatomic, assign) BOOL musicMonitoring;
/// 上一次因为"不在白名单"被隐藏的 App，用来只打一次日志（每拍都打会刷爆文件）。
@property (nonatomic, copy, nullable) NSString *lastBlockedApp;
/// 探针这一拍没拿到前台 App 的起始时刻。用来做 0.45s 的过渡防抖：
/// 从 App 退回桌面的那几拍会有短暂空窗，立刻收块会闪一下。
@property (nonatomic, assign) CFTimeInterval frontmostMissingSince;

/// 把卡片放到屏幕上。返回 YES = 这一次确实把窗口和卡片都摆出来了。
- (BOOL)showCardLeftEdgeUp:(BOOL)leftEdgeUp;

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

    PGLog(@"reload: enabled=%d landscapeAlwaysOn=%d → active=%d（白名单开关=%d 名单=%lu 个）",
          preferences.isEnabled, preferences.landscapeAlwaysOn, self.active,
          preferences.landscapeAppFilterEnabled,
          (unsigned long)preferences.landscapeAppAllowList.count);

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

/// 把系统"正在播放"直接灌给卡片。卡片是常驻的，不再需要"出现 / 消失"的可见性判定 ——
/// 没在放歌就显示「未播放」，封面区照常在，文案由卡片自己兜。
- (void)applyNowPlaying:(PGNowPlaying *)item {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self applyNowPlaying:item];
        });
        return;
    }
    if (!self.card) return;

    [self.card updateTitle:item.title
                    artist:item.artist
                   playing:item.isPlaying
                   elapsed:item.elapsed
                  duration:item.duration
               artworkData:item.artworkData
                canOpenApp:item.bundleIdentifier.length > 0];
}

#pragma mark 播放控制区的展开 / 收起

/// 长按整张卡片展开控制区。手势绑在卡片上（不是歌词上），按卡片哪儿都算。
- (void)handleCardLongPress:(UILongPressGestureRecognizer *)recognizer {
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            // 长按之后系统还会补一次 tap，抑制掉，免得刚展开就被自己收起。
            self.suppressTapUntil = CACurrentMediaTime() + 0.5;
            [self showControls];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            // 松手后留 3 秒，够点上一首 / 播放 / 下一首；按按钮会重新计时。
            [self scheduleControlsHide];
            break;
        default:
            break;
    }
}

/// 单指点卡片：收起态 → 展开（点击就够，不必长按）；展开态 → 点封面跳播放器，其余位置收回。
- (void)handleCardTap:(UITapGestureRecognizer *)recognizer {
    if (CACurrentMediaTime() < self.suppressTapUntil) return;
    if (!self.card) return;

    if (!self.controlsVisible) {
        // 收起态整张卡只有状态行（时间 / 电量 / 温度 / CPU）。单击一下才把歌曲区和播放控制拉出来。
        [self showControls];
        // 给了展开动作就要给收起动作：3 秒不动自动回到状态行。
        [self scheduleControlsHide];
        return;
    }

    // 点在封面上 = 跳回播放器；其它位置 = 收回。
    CGPoint point = [recognizer locationInView:self.card];
    if ([self.card handleTapAtPoint:point]) return;
    [self hideControls];
}

/// 双指点击：横屏双手握持时食指常压在卡片附近，双指点比长按更省事。
- (void)handleCardTwoFingerTap:(UITapGestureRecognizer *)recognizer {
    if (self.controlsVisible) {
        [self scheduleControlsHide];
        return;
    }
    self.suppressTapUntil = CACurrentMediaTime() + 0.4;
    [self showControls];
    [self scheduleControlsHide];
}

/// 按钮上的触摸不交给卡片手势：否则按了"下一首"之后，卡片的 tap 还会跟着把控制区收起来。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *view = touch.view;
    while (view && view != self.card) {
        if ([view isKindOfClass:UIControl.class]) return NO;
        view = view.superview;
    }
    return YES;
}

/// 双指捏合直接改卡片大小（跟手），松手写回设置里那个滑块。
- (void)handleCardPinch:(UIPinchGestureRecognizer *)recognizer {
    if (!self.card) return;
    CGRect space = self.window.bounds;
    if (CGRectGetWidth(space) <= 0.0 || CGRectGetHeight(space) <= 0.0) return;

    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            self.pinchStartScale = self.liveCardScale > 0.0 ? self.liveCardScale : PGCardScaleValue();
            // 捏的时候别让自动收起计时在半路把控制区抢走。
            [self.controlsTimer invalidate];
            self.controlsTimer = nil;
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat target = self.pinchStartScale * recognizer.scale;
            if (!isfinite(target) || target <= 0.0) return;
            self.liveCardScale = MAX(0.7, MIN(2.2, target));
            [self layoutCardLeftEdgeUp:self.anchorLeftEdgeUp];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat finalScale = self.liveCardScale > 0.0 ? self.liveCardScale : self.pinchStartScale;
            self.liveCardScale = 0.0;
            [self persistCardScale:finalScale];
            [self layoutCardLeftEdgeUp:self.anchorLeftEdgeUp];
            [self scheduleControlsHide];
            break;
        }
        default:
            break;
    }
}

/// 把双指调出来的大小写回偏好，设置页那个滑块下次打开就是这个值。
- (void)persistCardScale:(CGFloat)scale {
    if (!isfinite(scale) || scale <= 0.0) return;
    scale = MAX(0.7, MIN(2.2, scale));
    CFPreferencesSetAppValue(CFSTR("LandscapeCardScale"),
                             (__bridge CFPropertyListRef)@(scale),
                             (__bridge CFStringRef)PGPreferencesDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)PGPreferencesDomain);
    PGLog(@"卡片: 双指缩放已保存，倍数 %.2f（约 %.0fx%.0f）",
          scale, PGCardDesignWidth * scale, PGCardCollapsedHeight * scale);
}

- (void)showControls {
    if (!self.card || self.controlsVisible || !self.window) return;
    [self.controlsTimer invalidate];
    self.controlsTimer = nil;
    self.controlsVisible = YES;
    [self.card setControlsVisible:YES animated:YES];
    [self animateCardLayout];
    if (PerfectGrabberPreferences.sharedPreferences.vibrationFeedback) {
        AudioServicesPlaySystemSound(1519);
    }
    PGLog(@"卡片: 展开播放控制");
}

- (void)hideControls {
    [self.controlsTimer invalidate];
    self.controlsTimer = nil;
    if (!self.controlsVisible) return;
    self.controlsVisible = NO;
    [self.card setControlsVisible:NO animated:YES];
    [self animateCardLayout];
    PGLog(@"卡片: 收起播放控制");
}

/// 松手后自动收起控制区。任何一次按按钮都会重新计时，正在操作时不会被收走。
- (void)scheduleControlsHide {
    [self.controlsTimer invalidate];
    self.controlsTimer = nil;
    if (!self.controlsVisible) return;
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:PGCardControlsGraceSeconds
                                           repeats:NO
                                             block:^(NSTimer *fireTimer) {
        [weakSelf hideControls];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.controlsTimer = timer;
}

/// 卡片高度变了（展开 / 收起），带动画重排一次。
- (void)animateCardLayout {
    if (!self.window || !self.card) return;
    [UIView animateWithDuration:0.20
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        [self placeCardInBounds:self.window.bounds];
    } completion:nil];
}

- (void)sendMediaCommand:(PGMediaCommand)command {
    [PGNowPlaying.sharedInstance sendCommand:command];
    if (PerfectGrabberPreferences.sharedPreferences.vibrationFeedback) {
        AudioServicesPlaySystemSound(1519);
    }
    // 按按钮说明还在用，把自动收起往后推。
    [self scheduleControlsHide];
}

/// 点封面：直接跳到正在放歌的 App。
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
        PGLog(@"卡片: 跳转到 %@", bundleIdentifier);
    } @catch (__unused NSException *exception) {
        PGLog(@"卡片: 跳转 %@ 抛异常", bundleIdentifier);
    }
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
        // 系统下拉面板自己会显示时间电量，控制区先收起来。
        [self hideControls];
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
    // 属性非 nil 不代表还活着：定时器可能已经被系统 / runloop 收掉。
    // 不校验 isValid 的话，一旦它失效，整条可见性轮询就永久停了 —— 卡片再也出不来。
    if (self.pollTimer && self.pollTimer.isValid) return;
    if (self.pollTimer) {
        PGLog(@"轮询定时器已失效，重新启动");
        [self.pollTimer invalidate];
        self.pollTimer = nil;
    }
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

    // 音乐每拍重新灌一次：MediaRemote 的通知不一定来（后台播放尤其容易漏），
    // 只靠 onChange 的话歌名 / 进度可能一直停在旧值。卡片内部会做去重，不会白刷 UI。
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

    // 前台 App 判定：桌面/锁屏一律隐藏；开了"仅指定 App 生效"时再按名单过滤。
    // 细节见 isFrontmostAppAllowed 的注释。
    if (![self isFrontmostAppAllowed]) {
        self.landscapeSince = 0.0;
        self.portraitSince = 0.0;
        if (self.visible) {
            [self hideBar];
            self.lastHideTime = CACurrentMediaTime();
            [self logSnapshotShown:NO note:@"not-allowed"];
        }
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

    if ([self showCardLeftEdgeUp:leftEdgeUp]) {
        self.showStallSince = 0.0;
    } else if (self.showStallSince <= 0.0) {
        self.showStallSince = now;
        PGLog(@"显示看门狗: 这一拍没能建出窗口，开始计时");
    } else if (now - self.showStallSince > 2.0) {
        // 最后一道看门狗。判定该显示、却连续 2 秒建不出窗口 —— 把所有状态清干净再重来一次。
        // 只有"横屏 + 前台放行"的分支才会走到这里，桌面 / 竖屏不会误触发。
        PGLog(@"显示看门狗: 连续 %.1fs 该显示却没窗口 → 清空状态并强制重建",
              now - self.showStallSince);
        self.showStallSince = 0.0;
        self.lastHideTime = 0.0;
        self.landscapeSince = now;
        self.portraitSince = 0.0;
        self.flickerLockUntil = 0.0;
        self.sceneMismatchSince = 0.0;
        [self teardownWindow];
        [self showCardLeftEdgeUp:leftEdgeUp];
    }
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
    UIWindowScene *best = PGLandscapeHostScene();

    // ① 窗口已经脱场景（场景 nil / unattached）：必须重建，只 hidden = NO 是亮不出来的。
    if (!scene || scene.activationState == UISceneActivationStateUnattached) {
        if (!best) return;   // 一个场景都拿不到（切前台动画中），等下一拍
        [self rebuildWindowForReason:@"窗口已脱离场景" scene:scene];
        return;
    }

    // ② 窗口挂在一个"不是当前前台活跃"的场景上 —— 退桌面、开别的 App、再回游戏时最常见。
    //    这种窗口 hidden 设成 NO 也不会渲染，表现就是"回到游戏，卡片再也不出来了"。
    //    先确认 0.8 秒再动，避免旋转 / 切前台瞬间场景列表抖动导致反复重建。
    BOOL wrongScene = (best && best != scene &&
                       scene.activationState != UISceneActivationStateForegroundActive);
    if (!wrongScene) {
        self.sceneMismatchSince = 0.0;
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (self.sceneMismatchSince <= 0.0) {
        self.sceneMismatchSince = now;
        return;
    }
    if (now - self.sceneMismatchSince < 0.8) return;
    [self rebuildWindowForReason:@"窗口所挂场景已不是前台活跃场景" scene:scene];
}

/// 拆掉窗口等下一拍重建（限流 1.5 秒，重建本身也会闪一下）。
- (void)rebuildWindowForReason:(NSString *)reason scene:(UIWindowScene *)scene {
    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastWindowRebuild > 0.0 && now - self.lastWindowRebuild < 1.5) return;
    self.lastWindowRebuild = now;
    self.sceneMismatchSince = 0.0;
    PGLog(@"窗口重建（%@）：scene=%@ state=%ld", reason,
          scene ? @"有" : @"无", (long)(scene ? scene.activationState : -1));
    [self teardownWindow];
}

/// 白名单判定。返回"这一拍允不允许显示横屏块"。
///
/// 顺序很重要：
/// 1) **桌面 / 锁屏 → 一律隐藏**（不管有没有开过滤）。iPhone 桌面不支持横屏，但把手机
///    横过来时重力是横的，插件照样会算出"横屏"；以前桌面布局里没有 App 元素 → 探针返回 nil
///    → 按"探针失败"放行，于是桌面上也冒出横屏块。现在"最高层是 SpringBoard"被明确识别成桌面。
/// 2) 没开过滤 → 全部放行；
/// 3) 开了过滤、名单为空 → **全部隐藏**。开关叫"仅指定 App 生效"，名单空着就是谁都不匹配；
///    以前这里按"不过滤"处理，于是用户打开开关、还没勾任何 App 时，表现和全局生效一模一样。
/// 4) 探针从未成功过（本次进程内）→ 放行。这是链路彻底不可用，不能让功能整个消失。
- (BOOL)isFrontmostAppAllowed {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    BOOL filtering = preferences.landscapeAppFilterEnabled;

    NSString *frontmost = nil;
    PGFrontmostKind kind = PGCurrentFrontmost(&frontmost);

    // ① 桌面 / 锁屏 / 通知中心：这里不存在"横屏内容"，直接不显示。
    if (kind == PGFrontmostKindHomeScreen) {
        self.frontmostMissingSince = 0.0;
        if (![self.lastBlockedApp isEqualToString:@"<home>"]) {
            self.lastBlockedApp = @"<home>";
            PGLog(@"前台: 当前在桌面/锁屏 → 隐藏横屏块");
        }
        return NO;
    }

    // 探针链路断过又恢复不了的兜底：从进程启动到现在一次都没成功 → 当成不可用。
    BOOL everResolved = PGFrontmostHasEverResolved();

    // ② 这一拍没拿到。
    //    从没成功解析过（刚注销/刚重启的那一两秒）：保持现状不动 —— 默认是隐藏，
    //    所以不会在桌面上冒出来；等探针回来（通常 <1 秒）再按真实前台判断。
    //    8 秒还解析不出来就认定探针在本机不可用，放行（宁可全局显示，也别把功能整个吞掉）。
    //
    //    ⚠️ 这一段以前是"没开白名单就直接放行"，于是刚注销时桌面上横屏会冒出一块
    //    （1.1-34 用户反馈），打开任意 App 触发一次布局更新后就又正常了。现在统一按上面的规则处理。
    if (kind == PGFrontmostKindUnknown || frontmost.length == 0) {
        if (!everResolved) {
            // 注销 / 开机早期：FBS 与 LS 都是空的，实测要 9 秒左右才第一次拿到前台 App。
            // 这段窗口期一律隐藏 —— 以前这里是"8 秒后放行"，于是注销后桌面横屏会冒出一块，
            // 等到探针就绪才消失（1.1-36 反馈）。白名单模式下宁可晚几秒显示，也不能在桌面上乱冒。
            CFTimeInterval elapsed = CACurrentMediaTime() - PGFrontmostStartedAt();
            if (elapsed < 60.0) {
                self.frontmostMissingSince = 0.0;
                if (![self.lastBlockedApp isEqualToString:@"<boot>"]) {
                    self.lastBlockedApp = @"<boot>";
                    PGLog(@"前台: 探针尚未就绪（已 %.0fs，注销/开机早期）→ 隐藏横屏块", elapsed);
                }
                return NO;
            }
            // 整整一分钟都没成功过：认定本机探针不可用，退回全局显示，
            // 否则白名单模式会让整个功能静默失效。
            if (![self.lastBlockedApp isEqualToString:@"<probe>"]) {
                self.lastBlockedApp = @"<probe>";
                PGLog(@"前台: 探针 60s 内从未成功，判定不可用 → 放行（全局显示）");
            }
            self.frontmostMissingSince = 0.0;
            return YES;
        }
        // 已经成功过：这一拍拿不到 = 过渡态，或者探针刚好卡住了。
        // 给 2.5 秒的宽限（正好等于探针的"卡死判定"阈值），期间的抖动不影响显示；
        // 真的回到桌面时走的是 ① 那条（布局会明确报 SpringBoard），不需要靠这里兜。
        CFTimeInterval now = CACurrentMediaTime();
        if (self.frontmostMissingSince <= 0.0) {
            self.frontmostMissingSince = now;
            return self.visible;
        }
        if (now - self.frontmostMissingSince < 2.5) return self.visible;
        // ⚠️ 以前这里直接 return NO。后果是：探针一旦坏掉（FBS 的 displayLayout 返回空数组，
        // 游戏切前后台时很容易出现），就永久判定"不在前台"，而且这段状态活在 SpringBoard 进程里
        // —— 退游戏、杀游戏重进都救不回来，只能注销（用户实测连续三个版本都是这个现象）。
        // 现在改成降级放行：真在桌面时 FBS 会明确报 com.apple.springboard，走上面的 HomeScreen 分支，
        // 不会因此在桌面上乱冒卡片。宁可偶尔多显示，也不能让功能整个消失。
        if (![self.lastBlockedApp isEqualToString:@"<probe-degraded>"]) {
            self.lastBlockedApp = @"<probe-degraded>";
            PGLog(@"前台: 探针持续 2.5s 无响应 → 降级放行，避免横屏卡片被永久隐藏");
        }
        return YES;
    }

    self.frontmostMissingSince = 0.0;

    // ③ 没开过滤 → 全部放行。
    if (!filtering) {
        self.lastBlockedApp = nil;
        return YES;
    }

    NSArray<NSString *> *allowList = preferences.landscapeAppAllowList;
    if (allowList.count == 0) {
        if (![self.lastBlockedApp isEqualToString:@"<empty>"]) {
            self.lastBlockedApp = @"<empty>";
            PGLog(@"白名单: 开关已打开但名单为空（0 个 App）→ 全部隐藏");
        }
        return NO;
    }

    // ④ 名单判定。
    if ([allowList containsObject:frontmost]) {
        self.lastBlockedApp = nil;
        return YES;
    }
    if (![self.lastBlockedApp isEqualToString:frontmost]) {
        self.lastBlockedApp = frontmost;
        PGLog(@"白名单: %@ 不在名单里（共 %lu 个）→ 隐藏横屏块",
              frontmost, (unsigned long)allowList.count);
    }
    return NO;
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

- (BOOL)showCardLeftEdgeUp:(BOOL)leftEdgeUp {
    // 长时间隐藏之后再出现（退桌面 / 切别的 App / 回游戏）：直接把窗口拆了重来。
    // 旧窗口可能挂在一个已失效或已退到后台的场景上，也可能成了孤儿 ——
    // 这几种情况 window.hidden = NO 都不会把它画出来。重建一次最省心，代价只有几毫秒。
    CFTimeInterval now = CACurrentMediaTime();
    if (!self.visible && self.lastHideTime > 0.0 && now - self.lastHideTime > 2.5) {
        PGLog(@"卡片重现：已隐藏 %.1fs → 重建窗口", now - self.lastHideTime);
        [self teardownWindow];
        self.lastHideTime = 0.0;
    }

    if (![self ensureWindowAndSubviews]) return NO;

    // 场景自检：还有可用的 windowScene，但窗口自己没挂上（legacy 窗口 / 场景被系统回收）。
    // 这种窗口把 hidden 设成 NO 也不会渲染 —— 必须重建。
    if (PGLandscapeHostScene() && !self.window.windowScene) {
        PGLog(@"卡片场景自检: 有可用场景但窗口没挂上 → 重建");
        [self teardownWindow];
        if (![self ensureWindowAndSubviews]) return NO;
    }

    if (!self.updating) {
        [self.card startTicking];
        self.updating = YES;
    }
    self.anchorLeftEdgeUp = leftEdgeUp;
    [self layoutCardLeftEdgeUp:leftEdgeUp];
    self.window.hidden = NO;
    // 无条件放出来：以前只在"从隐藏变显示"那一刻设一次，万一中途有别的地方把 card.hidden
    // 置成 YES（重建 / 回收），visible 还是 YES 就再也不会修回来 —— 表现同样是"卡片不见了"。
    self.card.hidden = NO;

    if (!self.visible) {
        // 只有"第一次出现"或"确实藏了一会儿"才淡入。若是在几百毫秒内又显回来，
        // 再来一次淡入就是肉眼可见的闪 —— 直接给满透明度。
        BOOL longGap = !self.appearedOnce ||
                       (self.lastHideTime > 0.0 && CACurrentMediaTime() - self.lastHideTime > 1.2);
        if (longGap) {
            self.card.alpha = 0.0;
            [UIView animateWithDuration:PGLandscapeFadeInDuration
                                  delay:0.0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                self.card.alpha = 1.0;
            } completion:nil];
            self.appearedOnce = YES;
        } else {
            [self.card.layer removeAllAnimations];
            self.card.alpha = 1.0;
        }
    } else if (self.card.alpha < 0.5) {
        // visible 已经是 YES 但透明度还被上一次淡入动画 / 中途打断留在半路：补一次。
        [self.card.layer removeAllAnimations];
        self.card.alpha = 1.0;
    }
    self.lastShowTime = CACurrentMediaTime();
    self.visible = YES;
    return YES;
}

- (BOOL)ensureWindowAndSubviews {
    if (self.window) {
        // 窗口还在、但卡片已经不在视图树里（系统回收 / 场景重建的残留）：一样按"没有"处理。
        if (self.card && self.card.superview) return YES;
        PGLog(@"窗口在但卡片已脱离视图树 → 整体重建");
        [self teardownWindow];
    }

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
    // 手动写成竖屏尺寸会把卡片算到屏幕外。
    if (!scene) window.frame = base;
    // 必须远高于普通 App 窗口：全屏视频时前台 App 的层级很高。
    // 系统自带 HUD 都是这个量级，照抄才不会"窗口建好了但看不见"。
    window.windowLevel = UIWindowLevelAlert + 1000000.0;
    window.backgroundColor = UIColor.clearColor;
    // 窗口本身要收触摸（卡片），由 hitTest 保证其它位置全部穿透。
    window.userInteractionEnabled = YES;
    window.accessibilityElementsHidden = YES;
    window.hidden = YES;

    // 根视图换成自定义容器：它随窗口一起变尺寸，旋转动画每一帧都会回调 layoutSubviews 重排卡片。
    PGLandscapeHostView *host = [[PGLandscapeHostView alloc] initWithFrame:window.bounds];
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    host.backgroundColor = UIColor.clearColor;
    host.userInteractionEnabled = YES;
    host.bar = self;

    UIViewController *controller = [[UIViewController alloc] init];
    controller.view = host;
    window.rootViewController = controller;

    PGLandscapeMusicCard *card = [[PGLandscapeMusicCard alloc] initWithFrame:CGRectZero];
    card.hidden = YES;

    // 手势全部绑在整张卡片上 —— 按封面、歌名、歌词、空白处都算，不存在"只有歌词能长按"。
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(handleCardTap:)];
    tap.delegate = self;
    [card addGestureRecognizer:tap];

    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardLongPress:)];
    longPress.minimumPressDuration = 0.35;
    longPress.allowableMovement = 20.0;
    longPress.cancelsTouchesInView = NO;
    longPress.delegate = self;
    [card addGestureRecognizer:longPress];

    // 双指点击：横屏双手握持时食指常压在卡片附近，双指点比长按更省事
    //（单指 tap 要求 touches == 1，两根手指落下时它直接判失败，两者不冲突）。
    UITapGestureRecognizer *twoFingerTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardTwoFingerTap:)];
    twoFingerTap.numberOfTouchesRequired = 2;
    twoFingerTap.delegate = self;
    [card addGestureRecognizer:twoFingerTap];

    // 双指捏合直接改大小（松手写回设置里那个倍数，滑块那边同步保留）。
    UIPinchGestureRecognizer *pinch =
        [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardPinch:)];
    pinch.delegate = self;
    [card addGestureRecognizer:pinch];

    __weak typeof(self) weakSelf = self;
    card.onPrevious = ^{ [weakSelf sendMediaCommand:PGMediaCommandPrevious]; };
    card.onToggle = ^{ [weakSelf sendMediaCommand:PGMediaCommandTogglePlayPause]; };
    card.onNext = ^{ [weakSelf sendMediaCommand:PGMediaCommandNext]; };
    card.onOpenApplication = ^{ [weakSelf openNowPlayingApplication]; };
    [host addSubview:card];

    window.cardHitArea = card;

    self.window = window;
    self.card = card;
    self.controlsVisible = NO;
    self.laidOut = NO;
    self.cardLength = 0.0;
    self.cardThickness = 0.0;

    // 窗口刚建好时音乐可能已经在放了，先把当前状态同步进来。
    [self applyNowPlaying:PGNowPlaying.sharedInstance];

    PGLog(@"窗口已创建: scene=%@ bounds=%.0fx%.0f level=%.0f",
          scene ? @"有" : @"无(legacy)",
          CGRectGetWidth(base), CGRectGetHeight(base), window.windowLevel);
    return YES;
}

- (void)layoutCardLeftEdgeUp:(BOOL)leftEdgeUp {
    if (!self.window || !self.card) return;
    CGRect space = self.window.bounds;
    if (CGRectGetWidth(space) <= 0.0 || CGRectGetHeight(space) <= 0.0) return;

    self.anchorLeftEdgeUp = leftEdgeUp;
    self.laidOut = YES;
    self.laidOutLeftEdgeUp = leftEdgeUp;
    self.laidOutScreenSize = space.size;
    [self placeCardInBounds:space];
}

/// 卡片尺寸：宽度 = 设计稿 320 × 倍数（受屏幕可用宽度收），高度按展开 / 收起取比例。
/// 纯算术，不量文字 —— 所以旋转动画里每帧调用也不心疼。
- (CGSize)cardSizeForSpace:(CGRect)space {
    CGFloat spaceWidth = CGRectGetWidth(space);
    CGFloat spaceHeight = CGRectGetHeight(space);
    BOOL landscapeSpace = spaceWidth > spaceHeight;
    // 用户视角的可用宽度：横屏坐标系是 spaceWidth，竖屏坐标系（游戏自己转画面）是 spaceHeight。
    CGFloat available = (landscapeSpace ? spaceWidth : spaceHeight) - 2.0 * PGLandscapeBarEdgeInset - 24.0;
    // 倍数优先取双指捏合中的临时值（跟手），否则读设置里那个滑块的值。
    CGFloat scale = self.liveCardScale > 0.0 ? self.liveCardScale : PGCardScaleValue();
    CGFloat width = MIN(PGCardDesignWidth * scale, MAX(180.0, available));
    CGFloat ratio = (self.controlsVisible ? PGCardExpandedHeight : PGCardCollapsedHeight) / PGCardDesignWidth;
    return CGSizeMake(ceil(width), ceil(width * ratio));
}

/// 只做几何摆放：按「吸附位置」贴到屏幕边缘；万一窗口仍是竖屏基准，就贴"物理朝上"的
/// 那条长边并旋转 90°。两种分支在同一物理姿态下看起来是同一个位置，所以旋转过程中切换分支不会跳。
- (void)placeCardInBounds:(CGRect)space {
    if (!self.card) return;
    CGFloat spaceWidth = CGRectGetWidth(space);
    CGFloat spaceHeight = CGRectGetHeight(space);
    if (spaceWidth <= 0.0 || spaceHeight <= 0.0) return;

    CGSize size = [self cardSizeForSpace:space];
    self.cardLength = size.width;
    self.cardThickness = size.height;

    // 0 顶部居中 / 1 左上 / 2 右上 / 3 底部居中 / 4 左下 / 5 右下 / 6 左侧居中 / 7 右侧居中
    NSInteger snap = PGCardSnapPosition();
    CGFloat inset = PGCardSnapInset();
    BOOL alignLeft = (snap == 1 || snap == 4 || snap == 6);
    BOOL alignRight = (snap == 2 || snap == 5 || snap == 7);
    BOOL alignTop = (snap == 0 || snap == 1 || snap == 2);
    BOOL alignBottom = (snap == 3 || snap == 4 || snap == 5);

    self.card.transform = CGAffineTransformIdentity;
    self.card.bounds = CGRectMake(0.0, 0.0, size.width, size.height);

    if (spaceWidth > spaceHeight) {
        // 横屏坐标系：y=0 那条边就是用户视角的顶边。贴顶时展开往下长，贴底时往上长 ——
        // 这里只算 center，height 变化时被吸附的那条边自然钉住。
        CGFloat x = alignLeft ? inset
                  : alignRight ? (spaceWidth - inset - size.width)
                  : (spaceWidth - size.width) / 2.0;
        CGFloat y = alignTop ? inset
                  : alignBottom ? (spaceHeight - inset - size.height)
                  : (spaceHeight - size.height) / 2.0;
        self.card.center = CGPointMake(x + size.width / 2.0, y + size.height / 2.0);
    } else {
        // 竖屏坐标系（旋转未能同步到这里时）：用户视角的顶边是左右两条长边，卡片旋转 90° 贴上去。
        // 这一支只在方向同步失败时才会走到，沿长边方向一律居中 —— 免得和上面那支来回跳。
        BOOL leftSide = self.anchorLeftEdgeUp;
        CGFloat centerX = leftSide ? (inset + size.height / 2.0)
                                   : (spaceWidth - inset - size.height / 2.0);
        self.card.center = CGPointMake(centerX, spaceHeight / 2.0);
        self.card.transform = CGAffineTransformMakeRotation(leftSide ? -M_PI_2 : M_PI_2);
    }
}

- (void)hideBar {
    BOOL wasVisible = self.visible;
    if (self.updating) {
        [self.card stopTicking];
        self.updating = NO;
    }
    [self hideControls];
    [self.card.layer removeAllAnimations];
    self.card.alpha = 1.0;
    self.card.hidden = YES;
    self.window.hidden = YES;
    self.laidOut = NO;
    self.needsResize = NO;
    self.visible = NO;
    self.landscapeSince = 0.0;
    self.portraitSince = 0.0;
    // 隐藏期间不算"该显示却没显示"，否则下次转回横屏第一拍就会误触发看门狗。
    self.showStallSince = 0.0;
    // 只记"真的从显示变成隐藏"那一次。inactive / suspended 每拍都会调到这里，
    // 若无条件刷新，重新启用时永远算不出"藏了多久"，那条重建窗口的兜底就失效了。
    if (wasVisible) self.lastHideTime = CACurrentMediaTime();
}

- (void)teardownWindow {
    if (self.updating) {
        [self.card stopTicking];
        self.updating = NO;
    }
    [self.controlsTimer invalidate];
    self.controlsTimer = nil;
    self.window.hidden = YES;
    self.window.rootViewController = nil;
    self.window = nil;
    self.card = nil;
    self.liveCardScale = 0.0;
    self.controlsVisible = NO;
    self.laidOut = NO;
    self.needsResize = NO;
    self.visible = NO;
    self.appearedOnce = NO;
    self.cardLength = 0.0;
    self.cardThickness = 0.0;
}

@end

#pragma mark - 跨线程刷新入口

static void PGRequestRefresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [PGLandscapeBar.sharedBar refreshNow];
    });
}
