#import "PGGrabberOverlayView.h"
#import "PerfectGrabberPreferences.h"
#import "PGHardwareMetrics.h"
#import <math.h>

@interface SBUIController : NSObject
+ (instancetype)sharedInstance;
- (NSInteger)batteryCapacityAsPercentage;
- (BOOL)isOnAC;
@end

/// 单排时左右内边距。
static const CGFloat PGSingleLinePadding = 10.0;
/// 单排时"时间电量"与音乐区之间的间距（中间夹一条分隔线）。
static const CGFloat PGSingleLineSectionGap = 7.0;
/// 音乐标题最多占多宽，超出就截断，避免歌名把胶囊拉得横贯整条屏幕。
static const CGFloat PGMusicMaxTextWidth = 280.0;

@interface PGGrabberOverlayView ()
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *batteryLabel;
/// 单排最左边的"CPU 频率 + 电池温度"，和中间的时间之间也夹一条分隔线。
@property (nonatomic, strong) UILabel *metricsLabel;
@property (nonatomic, strong) UIView *metricsDivider;
@property (nonatomic, strong) UILabel *musicLabel;
@property (nonatomic, strong) UIImageView *musicStateView;
@property (nonatomic, strong) UIView *divider;
@property (nonatomic, strong) NSTimer *timer;

@property (nonatomic, assign) BOOL musicVisible;
@property (nonatomic, copy) NSString *musicTitle;
@property (nonatomic, copy) NSString *musicArtist;
@property (nonatomic, assign) BOOL musicPlaying;
/// 上次上报给宿主的宽度，用来判断"内容宽度真的变了"。
@property (nonatomic, assign) CGFloat reportedWidth;
@property (nonatomic, assign) BOOL reportedMusicVisible;
/// 防止 "量宽度 → 通知宿主 → 宿主再量宽度" 无限递归。
@property (nonatomic, assign) BOOL reportingSize;
@end

@implementation PGGrabberOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = NO;
        self.layer.cornerRadius = 6.0;

        _timeLabel = [UILabel new];
        _batteryLabel = [UILabel new];
        for (UILabel *label in @[_timeLabel, _batteryLabel]) {
            label.textAlignment = NSTextAlignmentCenter;
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.65;
            label.numberOfLines = 1;
            [self addSubview:label];
        }

        // 左边那截硬件指标：CPU 频率 + 电池温度。
        _metricsLabel = [UILabel new];
        _metricsLabel.numberOfLines = 1;
        _metricsLabel.textAlignment = NSTextAlignmentLeft;
        _metricsLabel.adjustsFontSizeToFitWidth = YES;
        _metricsLabel.minimumScaleFactor = 0.7;
        _metricsLabel.hidden = YES;
        [self addSubview:_metricsLabel];

        _metricsDivider = [UIView new];
        _metricsDivider.hidden = YES;
        [self addSubview:_metricsDivider];

        // 音乐区：分隔线 + 歌名 + 播放/暂停小图标，默认全部隐藏。
        _divider = [UIView new];
        _divider.hidden = YES;
        [self addSubview:_divider];

        _musicLabel = [UILabel new];
        _musicLabel.numberOfLines = 1;
        _musicLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _musicLabel.textAlignment = NSTextAlignmentLeft;
        _musicLabel.hidden = YES;
        [self addSubview:_musicLabel];

        _musicStateView = [UIImageView new];
        _musicStateView.contentMode = UIViewContentModeScaleAspectFit;
        _musicStateView.hidden = YES;
        [self addSubview:_musicStateView];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
}

#pragma mark - 外观

- (UIFont *)configuredFont {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (preferences.fontStyle == 1) {
        return [UIFont systemFontOfSize:preferences.fontSize weight:UIFontWeightBold];
    }
    UIFont *font = [UIFont systemFontOfSize:preferences.fontSize weight:UIFontWeightRegular];
    if (preferences.fontStyle == 2) {
        UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic];
        if (descriptor) font = [UIFont fontWithDescriptor:descriptor size:preferences.fontSize];
    }
    return font;
}

- (NSInteger)currentBatteryPercentage {
    Class controllerClass = NSClassFromString(@"SBUIController");
    if ([controllerClass respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [controllerClass sharedInstance];
        if ([controller respondsToSelector:@selector(batteryCapacityAsPercentage)]) {
            return MAX(0, MIN(100, [controller batteryCapacityAsPercentage]));
        }
    }

    UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    CGFloat level = UIDevice.currentDevice.batteryLevel;
    return level < 0 ? 0 : (NSInteger)lround(level * 100.0);
}

- (BOOL)isCharging {
    Class controllerClass = NSClassFromString(@"SBUIController");
    if ([controllerClass respondsToSelector:@selector(sharedInstance)]) {
        SBUIController *controller = [controllerClass sharedInstance];
        if ([controller respondsToSelector:@selector(isOnAC)]) return [controller isOnAC];
    }
    UIDeviceBatteryState state = UIDevice.currentDevice.batteryState;
    return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
}

- (NSString *)timeText {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale currentLocale];
    formatter.dateFormat = preferences.disable24Hour ? @"h:mm a" : @"HH:mm";
    return [formatter stringFromDate:NSDate.date];
}

- (NSString *)batteryText {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    NSInteger battery = [self currentBatteryPercentage];
    NSString *chargingPrefix = preferences.chargingIcon && [self isCharging] ? @"\u26A1 " : @"";
    return [NSString stringWithFormat:@"%@%ld%%", chargingPrefix, (long)battery];
}

- (void)updateContents {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    NSString *time = [self timeText];
    NSString *battery = [self batteryText];

    if (preferences.twoLine && !self.forceSingleLine) {
        self.batteryLabel.text = battery;
        self.batteryLabel.hidden = NO;
        self.timeLabel.text = time;
    } else {
        // 单排：时间与电量用空格隔开，比斜杠更干净；有音乐时再接一段"♪ 歌名"。
        self.timeLabel.text = [NSString stringWithFormat:@"%@ %@", time, battery];
        self.batteryLabel.text = nil;
        self.batteryLabel.hidden = YES;
    }
    [self updateMetricsText];
    [self applyAppearance];
    [self setNeedsLayout];
    [self reportWidthIfNeeded];
}

/// 单排最左边那段：`CPU 37% 38.1°C`（或选了频率模式时 `3.46GHz 38.1°C`）。
/// 读不到的项直接不写，两项都读不到就整段隐藏。
- (void)updateMetricsText {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    if (!self.forceSingleLine || !preferences.landscapeMetrics) {
        self.metricsLabel.text = nil;
        self.metricsLabel.hidden = YES;
        return;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (preferences.landscapeMetricsUsage) {
        // 占比固定两位宽（7% 写成 " 7%"），占用率在个位/十位之间跳时胶囊宽度不会抖。
        double usage = PGCPUUsagePercent();
        if (!isnan(usage)) {
            [parts addObject:[NSString stringWithFormat:@"CPU %2.0f%%", usage]];
        }
    } else {
        double gigahertz = PGCPUCurrentFrequencyGHz();
        if (gigahertz > 0.0) {
            if (gigahertz >= 1.0) {
                [parts addObject:[NSString stringWithFormat:@"%.2fGHz", gigahertz]];
            } else {
                [parts addObject:[NSString stringWithFormat:@"%.0fMHz", gigahertz * 1000.0]];
            }
        }
    }
    double celsius = PGBatteryTemperatureCelsius();
    if (!isnan(celsius)) {
        [parts addObject:[NSString stringWithFormat:@"%.1f\u00B0C", celsius]];
    }

    self.metricsLabel.text = parts.count ? [parts componentsJoinedByString:@" "] : nil;
    self.metricsLabel.hidden = parts.count == 0;
}

- (void)applyAppearance {
    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    UIFont *font = [self configuredFont];
    UIColor *textColor = preferences.textColor;

    for (UILabel *label in @[self.timeLabel, self.batteryLabel]) {
        label.font = font;
        label.textColor = textColor;
        label.numberOfLines = 1;
    }
    self.musicLabel.font = font;
    self.musicLabel.textColor = [textColor colorWithAlphaComponent:0.95];
    self.metricsLabel.font = font;
    self.metricsLabel.textColor = [textColor colorWithAlphaComponent:0.92];
    if (@available(iOS 13.0, *)) {
        self.musicStateView.tintColor = textColor;
    }
    self.divider.backgroundColor = [textColor colorWithAlphaComponent:0.30];
    self.metricsDivider.backgroundColor = [textColor colorWithAlphaComponent:0.30];

    UIColor *background = self.backgroundOverrideColor;
    if (!background) {
        background = preferences.backgroundColorEnabled ? preferences.backgroundColor : UIColor.clearColor;
    }
    self.backgroundColor = background;
    // 有背景色就四角都圆；透明时圆角也保留（子类会按自己的半径覆盖），避免切换时跳变。
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                               kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
}

- (void)refreshAppearance {
    [self applyAppearance];
    [self setNeedsLayout];
    [self updateContents];
}

#pragma mark - 音乐区

- (void)setMusicVisible:(BOOL)visible title:(NSString *)title
                 artist:(NSString *)artist playing:(BOOL)playing {
    NSString *newTitle = title ?: @"";
    NSString *newArtist = artist ?: @"";
    BOOL changed = visible != self.musicVisible ||
                   playing != self.musicPlaying ||
                   ![newTitle isEqualToString:(self.musicTitle ?: @"")] ||
                   ![newArtist isEqualToString:(self.musicArtist ?: @"")];
    if (!changed) return;

    self.musicVisible = visible;
    self.musicPlaying = playing;
    self.musicTitle = newTitle;
    self.musicArtist = newArtist;

    if (visible) {
        NSString *composed = nil;
        if (self.musicTitle.length && self.musicArtist.length) {
            composed = [NSString stringWithFormat:@"\u266A %@ \u00B7 %@", self.musicTitle, self.musicArtist];
        } else if (self.musicTitle.length) {
            composed = [NSString stringWithFormat:@"\u266A %@", self.musicTitle];
        } else if (self.musicArtist.length) {
            composed = [NSString stringWithFormat:@"\u266A %@", self.musicArtist];
        } else {
            composed = @"\u266A 正在播放";
        }
        self.musicLabel.text = composed;
        if (@available(iOS 13.0, *)) {
            self.musicStateView.image = [UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"];
        }
    } else {
        self.musicLabel.text = nil;
        self.musicStateView.image = nil;
    }

    self.musicLabel.hidden = !visible;
    self.musicStateView.hidden = !visible;
    self.divider.hidden = !visible;
    // 字体/颜色必须先就位再量宽度，否则首次量到的是系统默认字号。
    [self applyAppearance];
    [self setNeedsLayout];
    [self reportWidthIfNeeded];
}

- (CGFloat)musicIntrinsicWidth {
    if (!self.musicVisible || self.musicLabel.text.length == 0) return 0.0;
    CGSize size = [self.musicLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    return MIN(ceil(size.width), PGMusicMaxTextWidth);
}

/// 内容宽度变化时通知宿主重排（胶囊会跟着歌名变宽变窄）。
- (void)reportWidthIfNeeded {
    if (self.reportingSize) return;
    CGFloat width = [self intrinsicWidth];
    if (fabs(width - self.reportedWidth) < 1.0 && self.reportedMusicVisible == self.musicVisible) return;
    self.reportedWidth = width;
    self.reportedMusicVisible = self.musicVisible;
    if (!self.contentWidthDidChange) return;
    self.reportingSize = YES;
    self.contentWidthDidChange();
    self.reportingSize = NO;
}

/// 不含 maxWidth 限制的"贴合内容"宽度。
- (CGFloat)intrinsicWidth {
    if (self.forceSingleLine) {
        CGFloat width = 2.0 * PGSingleLinePadding;
        if (self.metricsLabel.text.length > 0 && !self.metricsLabel.hidden) {
            // 指标文字 + 分隔线两侧间距
            CGSize metricsSize = [self.metricsLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
            width += ceil(metricsSize.width) + PGSingleLineSectionGap + 1.0 + PGSingleLineSectionGap;
        }
        CGSize timeSize = [self.timeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        width += ceil(timeSize.width);
        if (self.musicVisible) {
            // 分隔线 + 两段间距 + 音乐文字 + 间距 + 播放图标
            width += PGSingleLineSectionGap + 1.0 + PGSingleLineSectionGap;
            width += [self musicIntrinsicWidth];
            width += 10.0 + 12.0;
        }
        return width;
    }

    CGFloat width = 0.0;
    for (UILabel *label in @[self.timeLabel, self.batteryLabel]) {
        if (label.hidden || label.text.length == 0) continue;
        width = MAX(width, [label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width);
    }
    return width + 16.0;
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.forceSingleLine) {
        [self layoutSingleLine];
        return;
    }

    PerfectGrabberPreferences *preferences = PerfectGrabberPreferences.sharedPreferences;
    CGRect contentBounds = CGRectInset(self.bounds, 8.0, 0.0);
    self.musicLabel.hidden = YES;
    self.musicStateView.hidden = YES;
    self.divider.hidden = YES;
    self.metricsLabel.hidden = YES;
    self.metricsDivider.hidden = YES;

    if (preferences.twoLine) {
        CGFloat rowHeight = CGRectGetHeight(contentBounds) / 2.0;
        self.timeLabel.frame = CGRectMake(CGRectGetMinX(contentBounds), CGRectGetMinY(contentBounds),
                                          CGRectGetWidth(contentBounds), rowHeight);
        self.batteryLabel.frame = CGRectMake(CGRectGetMinX(contentBounds), CGRectGetMinY(contentBounds) + rowHeight,
                                             CGRectGetWidth(contentBounds), rowHeight);
        NSTextAlignment alignment = preferences.grabberStyle == 1 ? NSTextAlignmentLeft :
                                    (preferences.grabberStyle == 2 ? NSTextAlignmentRight : NSTextAlignmentCenter);
        self.timeLabel.textAlignment = alignment;
        self.batteryLabel.textAlignment = alignment;
    } else {
        self.timeLabel.frame = contentBounds;
        self.batteryLabel.frame = CGRectZero;
        self.timeLabel.textAlignment = preferences.grabberStyle == 1 ? NSTextAlignmentLeft :
                                       (preferences.grabberStyle == 2 ? NSTextAlignmentRight : NSTextAlignmentCenter);
    }
}

/// 单排：`3.46GHz 38.1°C │ 15:04 45% │ ♪ 歌名 · 歌手  ⏸`
- (void)layoutSingleLine {
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat pad = PGSingleLinePadding;
    CGFloat scale = MAX(UIScreen.mainScreen.scale, 1.0);
    CGFloat lineHeight = MIN(14.0, height - 6.0);
    CGFloat contentRight = width - pad;

    self.batteryLabel.frame = CGRectZero;
    self.batteryLabel.hidden = YES;

    // 第一段：CPU 频率 + 电池温度（没内容就整段让位给时间）。
    CGFloat cursor = pad;
    if (self.metricsLabel.text.length > 0 && !self.metricsLabel.hidden) {
        self.metricsLabel.hidden = NO;
        CGSize metricsSize = [self.metricsLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)];
        CGFloat metricsWidth = MIN(ceil(metricsSize.width), MAX(0.0, contentRight - pad));
        self.metricsLabel.frame = CGRectMake(cursor, 0.0, metricsWidth, height);
        cursor += metricsWidth + PGSingleLineSectionGap;
        self.metricsDivider.hidden = NO;
        self.metricsDivider.frame = CGRectMake(cursor, (height - lineHeight) / 2.0, 1.0 / scale, lineHeight);
        cursor += 1.0 + PGSingleLineSectionGap;
    } else {
        self.metricsLabel.frame = CGRectZero;
        self.metricsDivider.hidden = YES;
        self.metricsDivider.frame = CGRectZero;
    }

    if (!self.musicVisible) {
        // 没有音乐时，时间在剩下的空间里居中（有指标时是"指标右边的剩余空间"）。
        self.timeLabel.textAlignment = NSTextAlignmentCenter;
        self.timeLabel.frame = CGRectMake(cursor, 0.0, MAX(0.0, contentRight - cursor), height);
        self.musicLabel.frame = CGRectZero;
        self.musicStateView.frame = CGRectZero;
        self.divider.frame = CGRectZero;
        return;
    }

    CGSize timeSize = [self.timeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)];
    CGFloat timeWidth = MIN(ceil(timeSize.width), MAX(0.0, contentRight - cursor));
    self.timeLabel.textAlignment = NSTextAlignmentLeft;
    self.timeLabel.frame = CGRectMake(cursor, 0.0, timeWidth, height);

    cursor += timeWidth + PGSingleLineSectionGap;
    self.divider.frame = CGRectMake(cursor, (height - lineHeight) / 2.0, 1.0 / scale, lineHeight);

    cursor += 1.0 + PGSingleLineSectionGap;
    CGFloat glyphWidth = 12.0;
    CGFloat glyphX = contentRight - glyphWidth;
    CGFloat musicWidth = MAX(0.0, glyphX - 8.0 - cursor);
    self.musicLabel.frame = CGRectMake(cursor, 0.0, musicWidth, height);

    CGFloat glyphHeight = MIN(12.0, height - 6.0);
    self.musicStateView.frame = CGRectMake(glyphX, (height - glyphHeight) / 2.0, glyphWidth, glyphHeight);
}

#pragma mark - 尺寸

- (CGSize)preferredContentSizeForMaxWidth:(CGFloat)maxWidth {
    // 先刷新一次内容，否则宿主首次排版时标签还是空的，量出来的宽度不可用。
    [self updateContents];
    UIFont *font = [self configuredFont];

    if (self.forceSingleLine) {
        CGSize timeSize = [self.timeLabel sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        CGFloat width = MIN([self intrinsicWidth], MAX(44.0, maxWidth));
        CGFloat height = MAX(ceil(MAX(timeSize.height, font.lineHeight)) + 12.0, 22.0);
        return CGSizeMake(width, height);
    }

    CGFloat textWidth = 0.0;
    CGFloat textHeight = 0.0;
    for (UILabel *label in @[self.timeLabel, self.batteryLabel]) {
        if (label.hidden || label.text.length == 0) continue;
        CGSize size = [label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        textWidth = MAX(textWidth, size.width);
        textHeight += size.height;
    }
    if (textHeight <= 0.0) {
        textWidth = font.pointSize * 6.0;
        textHeight = font.lineHeight;
    }

    // 左右各 8pt 是 layoutSubviews 里的内边距，宽高再各留一点余量。
    CGFloat width = ceil(textWidth) + 16.0;
    CGFloat height = ceil(textHeight) + 8.0;
    return CGSizeMake(MIN(width, MAX(44.0, maxWidth)), MAX(height, 20.0));
}

#pragma mark - 刷新

- (void)startUpdating {
    [self stopUpdating];
    [self refreshAppearance];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(updateContents)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)stopUpdating {
    [self.timer invalidate];
    self.timer = nil;
}

@end
