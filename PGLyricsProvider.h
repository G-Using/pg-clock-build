#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 歌词来源：按「歌名 + 歌手 + 时长」联网匹配 LRC，命中后缓存到
/// /var/mobile/Media/PerfectGrabberLyrics/，之后同一首歌离线也能显示。
/// 全部在后台队列跑，主线程只读结果，绝不阻塞 SpringBoard。
@interface PGLyricsProvider : NSObject

+ (instancetype)sharedInstance;

/// 请求某首歌的歌词。同一首歌重复调用是空操作；失败后 60 秒内不再重试。
/// title/artist 传 nil 或空串 = 清空当前歌词。
- (void)requestLyricsForTitle:(nullable NSString *)title
                       artist:(nullable NSString *)artist
                     duration:(double)duration;

/// 按播放进度取当前行。没有歌词返回 nil。
- (nullable NSString *)lineAtElapsed:(double)elapsed;
/// 当前行的下一行（用于淡色预览）。没有就返回 nil。
- (nullable NSString *)nextLineAtElapsed:(double)elapsed;

/// 正在联网匹配。
@property (nonatomic, readonly) BOOL loading;
/// 当前这首歌已经有可用歌词。
@property (nonatomic, readonly) BOOL hasLyrics;

@end

NS_ASSUME_NONNULL_END
