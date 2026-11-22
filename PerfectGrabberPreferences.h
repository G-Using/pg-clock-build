#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const PGPreferencesDomain;
FOUNDATION_EXPORT NSString *const PGPreferencesChangedNotification;

@interface PerfectGrabberPreferences : NSObject

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) BOOL vibrationFeedback;
@property (nonatomic, readonly) BOOL showOnSwipeUp;
@property (nonatomic, readonly) BOOL landscapeAlwaysOn;
/// 横屏块是否附带"正在播放的音乐"信息（前台是游戏/别的 App、后台在放歌时）。
@property (nonatomic, readonly) BOOL landscapeMusic;
/// 横屏块使用独立的自定义背景色，不再跟随上面那组"背景"设置。
@property (nonatomic, readonly) BOOL landscapeCustomBackground;
@property (nonatomic, readonly) UIColor *landscapeBackgroundColor;
@property (nonatomic, readonly) BOOL disable24Hour;
@property (nonatomic, readonly) BOOL chargingIcon;
@property (nonatomic, readonly) BOOL twoLine;
@property (nonatomic, readonly) NSInteger grabberStyle;
@property (nonatomic, readonly) CGFloat fontSize;
@property (nonatomic, readonly) NSInteger fontStyle;
@property (nonatomic, readonly) BOOL backgroundColorEnabled;
@property (nonatomic, readonly) BOOL swipeUpBackgroundColorEnabled;
@property (nonatomic, readonly) UIColor *textColor;
@property (nonatomic, readonly) UIColor *backgroundColor;
@property (nonatomic, readonly) UIColor *swipeUpBackgroundColor;

+ (instancetype)sharedPreferences;
+ (UIColor *)colorFromHexString:(NSString *)value fallback:(UIColor *)fallback;
- (void)reload;

@end

NS_ASSUME_NONNULL_END
