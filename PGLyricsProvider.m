#import "PGLyricsProvider.h"
#import <UIKit/UIKit.h>
#import <math.h>

/// 日志函数在 PGGrabberLandscapeBar.m 里实现，写到 /var/mobile/Media/PerfectGrabber.log。
extern void PGDebugLog(NSString *format, ...);

static NSString *const PGLyricsCacheDirectory = @"/var/mobile/Media/PerfectGrabberLyrics";
static const NSTimeInterval PGLyricsRequestTimeout = 6.0;
/// 匹配失败后冷却这么久再试，避免游戏里每首歌都反复打接口。
static const CFTimeInterval PGLyricsFailureCooldown = 60.0;

#pragma mark - 工具

static NSDictionary *PGJSONObject(NSData *data) {
    if (data.length == 0) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

/// 只保留 unreserved 字符，中文 / 空格 / & 全部转义。
static NSString *PGPercentEncode(NSString *value) {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

/// 同步 GET。只在后台队列调用 —— 主线程等网络就是卡 SpringBoard。
static NSData *PGHTTPGet(NSString *urlString, NSTimeInterval timeout) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:url
                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                            timeoutInterval:timeout];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) "
                      @"AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
     forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"zh-CN,zh;q=0.9" forHTTPHeaderField:@"Accept-Language"];

    __block NSData *result = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:request
                                       completionHandler:^(NSData *data, NSURLResponse *response,
                                                           NSError *error) {
        if (!error) result = data;
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    // 比 timeout 多留 2 秒：URLSession 自己会先超时，这里只是防它卡死不放行。
    dispatch_semaphore_wait(semaphore,
                            dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)((timeout + 2.0) * NSEC_PER_SEC)));
    return result;
}

static NSString *PGLyricsHash(NSString *key) {
    const char *bytes = key.UTF8String;
    unsigned long long hash = 1469598103934665603ULL;
    for (const char *p = bytes; p && *p; p++) {
        hash ^= (unsigned char)*p;
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%016llx", hash];
}

static NSString *PGTrimmed(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *trimmed =
        [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed ?: @"";
}

/// 网易云搜索结果里 artists 是数组，把名字拼起来。
static NSString *PGArtistsString(id artists) {
    if (![artists isKindOfClass:NSArray.class]) return @"";
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id item in (NSArray *)artists) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id name = ((NSDictionary *)item)[@"name"];
        if ([name isKindOfClass:NSString.class] && [(NSString *)name length]) {
            [names addObject:name];
        }
    }
    return [names componentsJoinedByString:@"/"];
}

#pragma mark -

@interface PGLyricsLine : NSObject
@property (nonatomic, assign) double time;
@property (nonatomic, copy) NSString *text;
@end

@implementation PGLyricsLine
@end

@interface PGLyricsProvider ()
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSArray<PGLyricsLine *> *lines;
@property (nonatomic, copy, nullable) NSString *loadingKey;
@property (nonatomic, copy, nullable) NSString *failedKey;
@property (nonatomic, assign) CFTimeInterval failedAt;
@property (nonatomic, strong) dispatch_queue_t queue;
/// key 在主线程写、在取数队列读。不加锁的话 nonatomic copy 属性的读写会互相踩，
/// 轻则读到半截字符串，重则 over-release 把 SpringBoard 带崩。
@property (nonatomic, strong) NSLock *keyLock;
@end

@implementation PGLyricsProvider

+ (instancetype)sharedInstance {
    static PGLyricsProvider *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _key = @"";
        _lines = @[];
        _queue = dispatch_queue_create("com.netskao.perfectgrabber.lyrics", DISPATCH_QUEUE_SERIAL);
        _keyLock = [[NSLock alloc] init];
    }
    return self;
}

- (BOOL)loading {
    return self.loadingKey.length > 0;
}

- (BOOL)hasLyrics {
    return self.lines.count > 0;
}

- (void)setCurrentKey:(NSString *)key {
    [self.keyLock lock];
    self.key = key ?: @"";
    [self.keyLock unlock];
}

- (BOOL)isCurrentKey:(NSString *)key {
    [self.keyLock lock];
    BOOL current = [self.key isEqualToString:(key ?: @"")];
    [self.keyLock unlock];
    return current;
}

#pragma mark 对外

- (void)requestLyricsForTitle:(NSString *)title artist:(NSString *)artist duration:(double)duration {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self requestLyricsForTitle:title artist:artist duration:duration];
        });
        return;
    }

    NSString *cleanTitle = PGTrimmed(title);
    NSString *cleanArtist = PGTrimmed(artist);

    if (cleanTitle.length == 0) {
        [self setCurrentKey:@""];
        self.lines = @[];
        self.loadingKey = nil;
        self.failedKey = nil;
        return;
    }

    NSString *key = [NSString stringWithFormat:@"%@|%@", cleanTitle.lowercaseString,
                     cleanArtist.lowercaseString];
    if ([self isCurrentKey:key]) {
        // 同一首：已有歌词 / 正在取 / 刚失败过，都直接返回。
        if (self.lines.count > 0) return;
        if (self.loadingKey.length > 0) return;
        if ([self.failedKey isEqualToString:key] &&
            CACurrentMediaTime() - self.failedAt < PGLyricsFailureCooldown) {
            return;
        }
    } else {
        [self setCurrentKey:key];
        self.lines = @[];
        self.failedKey = nil;
        self.loadingKey = nil;
    }

    self.loadingKey = key;
    dispatch_async(self.queue, ^{
        [self fetchForKey:key title:cleanTitle artist:cleanArtist duration:duration];
    });
}

- (NSString *)lineAtElapsed:(double)elapsed {
    NSUInteger index = [self indexForElapsed:elapsed];
    if (index == NSNotFound) return nil;
    return self.lines[index].text;
}

- (NSString *)nextLineAtElapsed:(double)elapsed {
    NSUInteger index = [self indexForElapsed:elapsed];
    if (index == NSNotFound || index + 1 >= self.lines.count) return nil;
    return self.lines[index + 1].text;
}

/// 二分找"最后一个 time <= elapsed"的行。
- (NSUInteger)indexForElapsed:(double)elapsed {
    NSArray<PGLyricsLine *> *lines = self.lines;
    if (lines.count == 0) return NSNotFound;

    NSUInteger low = 0;
    NSUInteger high = lines.count - 1;
    NSUInteger best = NSNotFound;
    while (low <= high) {
        NSUInteger mid = low + (high - low) / 2;
        if (lines[mid].time <= elapsed + 0.001) {
            best = mid;
            low = mid + 1;
        } else {
            if (mid == 0) break;
            high = mid - 1;
        }
    }
    // 进度在首句之前：给第一句，别让卡片空着。
    return best == NSNotFound ? 0 : best;
}

#pragma mark 取数

- (void)fetchForKey:(NSString *)key title:(NSString *)title artist:(NSString *)artist
           duration:(double)duration {
    @autoreleasepool {
        if (![self isCurrentKey:key]) return;   // 已经换歌了，别再打接口
        NSArray<PGLyricsLine *> *lines = [self cachedLinesForKey:key];
        NSString *source = @"缓存";

        if (lines.count == 0) {
            source = @"网络";
            if (![self isCurrentKey:key]) return;
            NSString *lrc = [self networkLRCForTitle:title artist:artist duration:duration];
            if (lrc.length > 0) {
                lines = [PGLyricsProvider parseLRC:lrc];
                if (lines.count > 0) [self storeCache:lrc forKey:key];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self isCurrentKey:key]) return;   // 已经换歌了，丢弃这次结果
            self.loadingKey = nil;
            self.lines = lines ?: @[];
            if (self.lines.count == 0) {
                self.failedKey = key;
                self.failedAt = CACurrentMediaTime();
            } else {
                self.failedKey = nil;
            }
            PGDebugLog(@"歌词: %@ / %@ ← %@ %ld 行", title, artist.length ? artist : @"-",
                       source, (long)self.lines.count);
        });
    }
}

- (NSString *)networkLRCForTitle:(NSString *)title artist:(NSString *)artist duration:(double)duration {
    NSString *lrc = [self neteaseLRCForTitle:title artist:artist duration:duration];
    if (lrc.length > 0) return lrc;
    return [self lrclibLRCForTitle:title artist:artist duration:duration];
}

/// 主源：网易云（华语歌覆盖最好）。搜索按歌名，再用歌手 + 时长打分挑一条。
- (NSString *)neteaseLRCForTitle:(NSString *)title artist:(NSString *)artist duration:(double)duration {
    NSString *searchURL = [NSString stringWithFormat:
        @"https://music.163.com/api/search/get/web?s=%@&type=1&offset=0&limit=10",
        PGPercentEncode(title)];
    NSDictionary *json = PGJSONObject(PGHTTPGet(searchURL, PGLyricsRequestTimeout));
    id result = json[@"result"];
    NSArray *songs = [result isKindOfClass:NSDictionary.class] ? ((NSDictionary *)result)[@"songs"] : nil;
    if (![songs isKindOfClass:NSArray.class] || songs.count == 0) return nil;

    NSDictionary *best = nil;
    double bestScore = 0.0;
    for (id item in (NSArray *)songs) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id name = ((NSDictionary *)item)[@"name"];
        if (![name isKindOfClass:NSString.class]) continue;

        NSString *artists = PGArtistsString(((NSDictionary *)item)[@"artists"]);
        id rawDuration = ((NSDictionary *)item)[@"duration"];
        double songDuration = [rawDuration respondsToSelector:@selector(doubleValue)]
            ? [rawDuration doubleValue] / 1000.0 : 0.0;

        double score = 0.0;
        if ([(NSString *)name isEqualToString:title]) {
            score += 40.0;
        } else if ([(NSString *)name containsString:title] || [title containsString:(NSString *)name]) {
            score += 22.0;
        }
        if (artist.length && artists.length && [artists containsString:artist]) score += 25.0;
        if (duration > 0.0 && songDuration > 0.0) {
            double diff = fabs(songDuration - duration);
            if (diff <= 2.5) score += 30.0;
            else if (diff <= 8.0) score += 12.0;
            else if (diff > 30.0) score -= 20.0;
        }
        if (score > bestScore) {
            bestScore = score;
            best = item;
        }
    }
    if (!best || bestScore < 30.0) return nil;

    id songID = best[@"id"];
    if (![songID respondsToSelector:@selector(description)]) return nil;
    NSString *lyricURL = [NSString stringWithFormat:
        @"https://music.163.com/api/song/lyric?id=%@&lv=-1&kv=-1&tv=-1", songID];
    NSDictionary *lyricJSON = PGJSONObject(PGHTTPGet(lyricURL, PGLyricsRequestTimeout));
    id lrc = lyricJSON[@"lrc"];
    if (![lrc isKindOfClass:NSDictionary.class]) return nil;
    id text = ((NSDictionary *)lrc)[@"lyric"];
    return [text isKindOfClass:NSString.class] ? text : nil;
}

/// 备用源：LRCLIB（公开接口，无需鉴权）。
- (NSString *)lrclibLRCForTitle:(NSString *)title artist:(NSString *)artist duration:(double)duration {
    NSMutableString *url = [NSMutableString stringWithFormat:
        @"https://lrclib.net/api/get?track_name=%@", PGPercentEncode(title)];
    if (artist.length) [url appendFormat:@"&artist_name=%@", PGPercentEncode(artist)];
    if (duration > 1.0) [url appendFormat:@"&duration=%ld", (long)lround(duration)];

    NSDictionary *json = PGJSONObject(PGHTTPGet(url, PGLyricsRequestTimeout));
    id synced = json[@"syncedLyrics"];
    if ([synced isKindOfClass:NSString.class] && [(NSString *)synced length] > 0) return synced;
    return nil;
}

#pragma mark 缓存

- (NSString *)cachePathForKey:(NSString *)key {
    NSString *name = [NSString stringWithFormat:@"%@.lrc", PGLyricsHash(key)];
    return [PGLyricsCacheDirectory stringByAppendingPathComponent:name];
}

- (NSArray<PGLyricsLine *> *)cachedLinesForKey:(NSString *)key {
    NSString *path = [self cachePathForKey:key];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (text.length == 0) return @[];

    NSArray<PGLyricsLine *> *lines = [PGLyricsProvider parseLRC:text];
    // 解析不出来（缓存被写坏 / 没有时间轴）：删掉，下次重新联网取。
    if (lines.count == 0) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    return lines;
}

- (void)storeCache:(NSString *)lrc forKey:(NSString *)key {
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager fileExistsAtPath:PGLyricsCacheDirectory]) {
        [manager createDirectoryAtPath:PGLyricsCacheDirectory
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:NULL];
    }
    [lrc writeToFile:[self cachePathForKey:key]
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:NULL];
}

#pragma mark LRC 解析

/// 支持 `[mm:ss.xx]` / `[mm:ss:xx]` / 一行多个时间戳；`[ti:]` 这类元信息自动跳过。
+ (NSArray<PGLyricsLine *> *)parseLRC:(NSString *)lrc {
    if (lrc.length == 0) return @[];

    NSMutableArray<PGLyricsLine *> *lines = [NSMutableArray array];
    NSArray<NSString *> *rawLines =
        [lrc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];

    for (NSString *raw in rawLines) {
        if (raw.length == 0) continue;

        NSUInteger cursor = 0;
        NSMutableArray<NSNumber *> *stamps = [NSMutableArray array];
        while (cursor < raw.length && [raw characterAtIndex:cursor] == '[') {
            NSRange searchRange = NSMakeRange(cursor, raw.length - cursor);
            NSRange close = [raw rangeOfString:@"]" options:0 range:searchRange];
            if (close.location == NSNotFound) break;

            NSString *inner = [raw substringWithRange:NSMakeRange(cursor + 1,
                                                                  close.location - cursor - 1)];
            double seconds = 0.0;
            if (![self parseTimestamp:inner into:&seconds]) break;   // [ti:...] 之类
            [stamps addObject:@(seconds)];
            cursor = close.location + 1;
        }
        if (stamps.count == 0) continue;

        NSString *text = [[raw substringFromIndex:MIN(cursor, raw.length)]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (text.length == 0) continue;

        for (NSNumber *stamp in stamps) {
            PGLyricsLine *line = [PGLyricsLine new];
            line.time = stamp.doubleValue;
            line.text = text;
            [lines addObject:line];
        }
    }

    [lines sortUsingComparator:^NSComparisonResult(PGLyricsLine *a, PGLyricsLine *b) {
        if (a.time < b.time) return NSOrderedAscending;
        if (a.time > b.time) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return lines;
}

+ (BOOL)parseTimestamp:(NSString *)text into:(double *)outSeconds {
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@":"];
    if (parts.count < 2 || parts.count > 3) return NO;

    // `[ti:标题]`、`[ar:歌手]` 这类元信息也会被冒号切开，必须先确认每一段都是纯数字，
    // 否则 "ti" 会被当成 0 分 0 秒，整条元信息就被当成第一句歌词塞进时间轴。
    NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789."];
    for (NSString *part in parts) {
        if (part.length == 0) return NO;
        if ([part rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound) return NO;
    }

    if (parts.count == 3) {
        // [hh:mm:ss]
        double hours = parts[0].doubleValue;
        double minutes = parts[1].doubleValue;
        double seconds = parts[2].doubleValue;
        if (outSeconds) *outSeconds = hours * 3600.0 + minutes * 60.0 + seconds;
        return YES;
    }

    double minutes = parts[0].doubleValue;
    double seconds = parts[1].doubleValue;
    if (minutes < 0.0 || seconds < 0.0) return NO;
    if (outSeconds) *outSeconds = minutes * 60.0 + seconds;
    return YES;
}

@end
