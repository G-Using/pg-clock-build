#import "PGLyricsProvider.h"
#import <UIKit/UIKit.h>
#import <math.h>

/// 日志函数在 PGGrabberLandscapeBar.m 里实现，写到 /var/mobile/Media/PerfectGrabber.log。
extern void PGDebugLog(NSString *format, ...);

static NSString *const PGLyricsCacheDirectory = @"/var/mobile/Media/PerfectGrabberLyrics";
static const NSTimeInterval PGLyricsRequestTimeout = 6.0;
/// 匹配失败后冷却这么久再试。以前是 60 秒：游戏里网络抖一下就要等整整一分钟，
/// 用户看到的就是"这首歌唱了半天还是暂无歌词"。15 秒足够避免刷接口。
static const CFTimeInterval PGLyricsFailureCooldown = 15.0;

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

#pragma mark - 候选与判定

/// 一条搜索候选。搜索接口一次给十几条，先打分排序，再逐条去取歌词 ——
/// 只赌第一条会踩到"搜到了但这版没收录歌词"的坑（实测《你看着我说话》就是这样）。
@interface PGLyricsCandidate : NSObject
@property (nonatomic, assign) long long songID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *artists;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) double score;
@end

@implementation PGLyricsCandidate
@end

/// MediaRemote 给的 artist 经常不是一个歌手：
///   「离开我的依赖 · cici_」= 原曲名 + 翻唱歌手
///   「A/B」「A & B」「A feat. B」「A、B」= 合唱
/// 拆成若干段，既用于歌手匹配，也用于"歌名藏在歌手串里"的跨名匹配。
static NSArray<NSString *> *PGArtistTokens(NSString *artist) {
    NSString *text = PGTrimmed(artist);
    if (text.length == 0) return @[];

    NSMutableString *normalized = [text mutableCopy];
    NSArray<NSString *> *separators = @[@"·", @"•", @"／", @"/", @"｜", @"|", @"、", @",", @"，",
                                        @"&", @"＆", @" feat. ", @" feat ", @" ft. ", @" ft "];
    for (NSString *separator in separators) {
        [normalized replaceOccurrencesOfString:separator
                                    withString:@"\n"
                                       options:NSCaseInsensitiveSearch
                                         range:NSMakeRange(0, normalized.length)];
    }

    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *piece in [normalized componentsSeparatedByString:@"\n"]) {
        NSString *token = PGTrimmed(piece);
        // 一两个字符的段没有辨识度（"DJ"、"a"），只会在打分时乱加分。
        if (token.length < 2) continue;
        if ([tokens containsObject:token]) continue;
        [tokens addObject:token];
    }
    return tokens;
}

/// 这一行是不是"作词 : 王艳薇"这类制作信息。
/// 网易云对没收录歌词的歌只返回两行 credit 当占位，必须识别出来，否则会被当成歌词。
static BOOL PGLyricLineIsCredit(NSString *text) {
    static NSArray<NSString *> *prefixes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefixes = @[@"作词", @"作曲", @"编曲", @"制作人", @"监制", @"出品", @"发行", @"录音", @"混音",
                     @"母带", @"和声", @"吉他", @"贝斯", @"弦乐", @"键盘", @"program", @"统筹",
                     @"策划", @"企划", @"宣传", @"设计", @"op", @"sp", @"演唱", @"原唱", @"音乐总监",
                     @"音响总监", @"改编", @"编创", @"人声", @"配唱", @"指导", @"未经许可", @"本歌曲",
                     @"版权", @"助理", @"执行", @"经纪", @"出品人", @"监制人", @"混音室", @"录音室",
                     @"录音棚", @"母带室", @"后期", @"封面", @"文案"];
    });

    NSString *compact = [[text stringByReplacingOccurrencesOfString:@" " withString:@""]
                         stringByReplacingOccurrencesOfString:@"　" withString:@""];
    if (compact.length == 0) return YES;

    // 形如「作词: 王艳薇」「作词 ：王艳薇」：冒号前那一段是关键词就判为制作信息。
    NSRange colon = [compact rangeOfCharacterFromSet:
                     [NSCharacterSet characterSetWithCharactersInString:@"：:"]];
    if (colon.location != NSNotFound && colon.location <= 8) {
        NSString *head = [[compact substringToIndex:colon.location] lowercaseString];
        if (head.length > 0) {
            for (NSString *prefix in prefixes) {
                if ([head isEqualToString:prefix.lowercaseString]) return YES;
            }
        }
    }

    // 没有冒号时只认明确的关键词前缀。
    // ⚠️ 不能收「词」「曲」「鼓」这类单字：歌词里「词不达意」「曲终人散」「鼓声」很常见，
    // 一旦误判就会被当成制作信息丢掉，好好的歌词反而少了一句。
    NSString *lower = compact.lowercaseString;
    for (NSString *prefix in prefixes) {
        if (prefix.length < 2) continue;
        if ([prefix isEqualToString:@"op"] || [prefix isEqualToString:@"sp"]) continue;
        if ([lower hasPrefix:prefix.lowercaseString]) return YES;
    }
    return NO;
}

/// 这段 LRC 到底能不能用：至少 3 句真正在唱的词。
/// 少于这个数基本就是"只有作词作曲两行占位"或者残片，显示出来比「暂无歌词」更糟。
static BOOL PGLyricsAreUsable(NSArray<PGLyricsLine *> *lines) {
    NSUInteger real = 0;
    for (PGLyricsLine *line in lines) {
        if (PGLyricLineIsCredit(line.text)) continue;
        real++;
        if (real >= 3) return YES;
    }
    return NO;
}

/// 候选打分。阈值 20：歌名像、或者歌手串里藏着这个歌名，任意一条成立就值得去试。
static double PGScoreCandidate(PGLyricsCandidate *candidate, NSString *title,
                               NSArray<NSString *> *tokens, double wantDuration) {
    double score = 0.0;
    NSString *name = candidate.name.lowercaseString;
    NSString *lowerTitle = title.lowercaseString;

    if (name.length && [name isEqualToString:lowerTitle]) {
        score += 50.0;
    } else if (name.length && lowerTitle.length &&
               ([name containsString:lowerTitle] || [lowerTitle containsString:name])) {
        score += 26.0;
    }

    // 歌名藏在歌手串里：翻唱 / 电台版本常见（"离开我的依赖 · cici_" 里的前一段就是原曲名）。
    for (NSString *token in tokens) {
        NSString *lowerToken = token.lowercaseString;
        if ([name isEqualToString:lowerToken]) {
            score += 45.0;
            break;
        }
        if (name.length > 3 && lowerToken.length > 3 &&
            ([name containsString:lowerToken] || [lowerToken containsString:name])) {
            score += 16.0;
            break;
        }
    }

    NSString *artists = candidate.artists.lowercaseString;
    for (NSString *token in tokens) {
        if (token.length >= 2 && [artists containsString:token.lowercaseString]) {
            score += 25.0;
            break;
        }
    }

    if (wantDuration > 1.0 && candidate.duration > 1.0) {
        double diff = fabs(candidate.duration - wantDuration);
        if (diff <= 3.0) score += 30.0;
        else if (diff <= 8.0) score += 12.0;
        else if (diff > 30.0) score -= 25.0;
    }
    return score;
}

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

/// 取数内部方法。写在扩展里，避免"先调用后定义"被编译器当成返回 id。
- (void)collectNeteaseCandidatesForQuery:(NSString *)query
                                   title:(NSString *)title
                                  tokens:(NSArray<NSString *> *)tokens
                                duration:(double)duration
                                    into:(NSMutableArray<PGLyricsCandidate *> *)pool
                                    seen:(NSMutableSet<NSNumber *> *)seen;
- (NSString *)firstUsableNeteaseLRCInCandidates:(NSArray<PGLyricsCandidate *> *)candidates;
- (NSString *)neteaseLyricTextForSongID:(long long)songID;
- (NSString *)usableSyncedLyricsInItem:(NSDictionary *)item;
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

#pragma mark 网易云

/// 主源：网易云（华语歌覆盖最好）。
///
/// 这里不再"挑一条最好的就走"：搜索结果里排前面的很可能是同名但没收录歌词的版本
/// （实测《你看着我说话》= 只有"作词/作曲"两行占位）。改成按分数排前几条逐条取词，
/// 取到第一条"真的有词"的为止。
- (NSString *)neteaseLRCForTitle:(NSString *)title artist:(NSString *)artist duration:(double)duration {
    NSArray<NSString *> *tokens = PGArtistTokens(artist);
    NSMutableArray<PGLyricsCandidate *> *pool = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];

    [self collectNeteaseCandidatesForQuery:title
                                     title:title
                                    tokens:tokens
                                  duration:duration
                                      into:pool
                                      seen:seen];
    NSString *lrc = [self firstUsableNeteaseLRCInCandidates:pool];
    if (lrc.length > 0) return lrc;

    // 第一轮（歌名）全军覆没：把歌手串里每一段当歌名再搜一次。
    // 「离开我的依赖 · cici_」这类元数据只能靠这一步救回来 —— 前一段才是原曲名。
    NSMutableArray<NSString *> *extraQueries = [NSMutableArray array];
    for (NSString *token in tokens) {
        if ([token isEqualToString:title]) continue;
        if ([extraQueries containsObject:token]) continue;
        [extraQueries addObject:token];
        if (extraQueries.count >= 2) break;
    }
    for (NSString *query in extraQueries) {
        [self collectNeteaseCandidatesForQuery:query
                                         title:title
                                        tokens:tokens
                                      duration:duration
                                          into:pool
                                          seen:seen];
    }
    return [self firstUsableNeteaseLRCInCandidates:pool];
}

- (void)collectNeteaseCandidatesForQuery:(NSString *)query
                                   title:(NSString *)title
                                  tokens:(NSArray<NSString *> *)tokens
                                duration:(double)duration
                                    into:(NSMutableArray<PGLyricsCandidate *> *)pool
                                    seen:(NSMutableSet<NSNumber *> *)seen {
    if (query.length == 0) return;
    NSString *searchURL = [NSString stringWithFormat:
        @"https://music.163.com/api/search/get?s=%@&type=1&offset=0&limit=15",
        PGPercentEncode(query)];
    NSDictionary *json = PGJSONObject(PGHTTPGet(searchURL, PGLyricsRequestTimeout));
    id result = json[@"result"];
    NSArray *songs = [result isKindOfClass:NSDictionary.class] ? ((NSDictionary *)result)[@"songs"] : nil;
    if (![songs isKindOfClass:NSArray.class] || songs.count == 0) {
        PGDebugLog(@"歌词: 搜索「%@」无结果", query);
        return;
    }

    NSUInteger added = 0;
    for (id item in (NSArray *)songs) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id name = ((NSDictionary *)item)[@"name"];
        id songID = ((NSDictionary *)item)[@"id"];
        if (![name isKindOfClass:NSString.class]) continue;
        if (![songID respondsToSelector:@selector(longLongValue)]) continue;
        long long identifier = [songID longLongValue];
        if (identifier == 0) continue;
        NSNumber *boxed = @(identifier);
        if ([seen containsObject:boxed]) continue;

        PGLyricsCandidate *candidate = [PGLyricsCandidate new];
        candidate.songID = identifier;
        candidate.name = name;
        candidate.artists = PGArtistsString(((NSDictionary *)item)[@"artists"]);
        id rawDuration = ((NSDictionary *)item)[@"duration"];
        candidate.duration = [rawDuration respondsToSelector:@selector(doubleValue)]
            ? [rawDuration doubleValue] / 1000.0 : 0.0;

        double score = PGScoreCandidate(candidate, title, tokens, duration);
        // 分数太低的没必要浪费一次歌词请求。
        if (score < 20.0) continue;

        candidate.score = score;
        [pool addObject:candidate];
        [seen addObject:boxed];
        added++;
    }
    PGDebugLog(@"歌词: 搜索「%@」%lu 条，收下 %lu 个候选",
               query, (unsigned long)songs.count, (unsigned long)added);
}

/// 按分数从高到低逐条取歌词，最多 4 条 —— 再多就是浪费流量，正常一两首就够。
- (NSString *)firstUsableNeteaseLRCInCandidates:(NSArray<PGLyricsCandidate *> *)candidates {
    if (candidates.count == 0) return nil;

    NSArray<PGLyricsCandidate *> *sorted =
        [candidates sortedArrayUsingComparator:^NSComparisonResult(PGLyricsCandidate *a,
                                                                    PGLyricsCandidate *b) {
        if (a.score > b.score) return NSOrderedAscending;
        if (a.score < b.score) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    CFTimeInterval deadline = CACurrentMediaTime() + 9.0;
    NSUInteger limit = MIN(sorted.count, 4);
    for (NSUInteger index = 0; index < limit; index++) {
        if (CACurrentMediaTime() > deadline) {
            PGDebugLog(@"歌词: 取词超时，放弃剩余 %lu 个候选", (unsigned long)(limit - index));
            break;
        }
        PGLyricsCandidate *candidate = sorted[index];
        NSString *lrc = [self neteaseLyricTextForSongID:candidate.songID];
        NSArray<PGLyricsLine *> *lines = [PGLyricsProvider parseLRC:lrc];
        BOOL usable = PGLyricsAreUsable(lines);
        PGDebugLog(@"歌词: 候选#%lu %@ / %@ id=%lld 分=%.0f → %lu 行 %@",
                   (unsigned long)(index + 1), candidate.name,
                   candidate.artists.length ? candidate.artists : @"-",
                   candidate.songID, candidate.score, (unsigned long)lines.count,
                   usable ? @"可用" : @"无效");
        if (usable) return lrc;
    }
    return nil;
}

- (NSString *)neteaseLyricTextForSongID:(long long)songID {
    NSString *lyricURL = [NSString stringWithFormat:
        @"https://music.163.com/api/song/lyric?id=%lld&lv=-1&kv=-1&tv=-1", songID];
    NSDictionary *lyricJSON = PGJSONObject(PGHTTPGet(lyricURL, PGLyricsRequestTimeout));
    id lrc = lyricJSON[@"lrc"];
    if (![lrc isKindOfClass:NSDictionary.class]) return nil;
    id text = ((NSDictionary *)lrc)[@"lyric"];
    return [text isKindOfClass:NSString.class] ? text : nil;
}

#pragma mark LRCLIB

/// 备用源：LRCLIB（公开接口，无需鉴权）。
/// `/api/get` 要求「歌名 + 歌手 + 时长」三者都对，华语歌命中率一般；
/// 拿不到就走 `/api/search` 模糊搜，按时长最接近的顺序逐条挑。
- (NSString *)lrclibLRCForTitle:(NSString *)title artist:(NSString *)artist duration:(double)duration {
    NSArray<NSString *> *tokens = PGArtistTokens(artist);

    NSMutableString *url = [NSMutableString stringWithFormat:
        @"https://lrclib.net/api/get?track_name=%@", PGPercentEncode(title)];
    if (tokens.firstObject.length) {
        [url appendFormat:@"&artist_name=%@", PGPercentEncode(tokens.firstObject)];
    }
    if (duration > 1.0) [url appendFormat:@"&duration=%ld", (long)lround(duration)];

    NSDictionary *json = PGJSONObject(PGHTTPGet(url, PGLyricsRequestTimeout));
    NSString *lrc = [self usableSyncedLyricsInItem:json];
    if (lrc.length > 0) return lrc;

    NSMutableArray<NSString *> *queries = [NSMutableArray arrayWithObject:title];
    for (NSString *token in tokens) {
        if ([token isEqualToString:title]) continue;
        [queries addObject:token];
        if (queries.count >= 2) break;
    }

    CFTimeInterval deadline = CACurrentMediaTime() + 8.0;
    for (NSString *query in queries) {
        if (CACurrentMediaTime() > deadline) break;
        NSString *searchURL = [NSString stringWithFormat:
            @"https://lrclib.net/api/search?track_name=%@", PGPercentEncode(query)];
        NSData *raw = PGHTTPGet(searchURL, PGLyricsRequestTimeout);
        if (raw.length == 0) continue;
        id parsed = [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
        if (![parsed isKindOfClass:NSArray.class]) continue;

        NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
        for (id item in (NSArray *)parsed) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            id synced = item[@"syncedLyrics"];
            if (![synced isKindOfClass:NSString.class] || [(NSString *)synced length] == 0) continue;
            [items addObject:item];
        }
        if (items.count == 0) continue;

        // 时长最接近的优先：同名歌的现场版 / 翻唱版词序常常不一样。
        [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double left = fabs([a[@"duration"] doubleValue] - duration);
            double right = fabs([b[@"duration"] doubleValue] - duration);
            if (left < right) return NSOrderedAscending;
            if (left > right) return NSOrderedDescending;
            return NSOrderedSame;
        }];

        NSUInteger limit = MIN(items.count, 6);
        for (NSUInteger index = 0; index < limit; index++) {
            NSString *synced = [self usableSyncedLyricsInItem:items[index]];
            if (synced.length > 0) return synced;
        }
    }
    return nil;
}

/// 取一条 LRCLIB 结果里的 `syncedLyrics`，顺手校验"真有词"。
- (NSString *)usableSyncedLyricsInItem:(NSDictionary *)item {
    if (![item isKindOfClass:NSDictionary.class]) return nil;
    id synced = item[@"syncedLyrics"];
    if (![synced isKindOfClass:NSString.class] || [(NSString *)synced length] == 0) return nil;
    NSArray<PGLyricsLine *> *lines = [PGLyricsProvider parseLRC:synced];
    return PGLyricsAreUsable(lines) ? synced : nil;
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
    // 解析不出来（缓存被写坏 / 没有时间轴），或者只有"作词/作曲"两行占位：
    // 删掉，下次重新联网取 —— 否则一条无效缓存会把这首歌永久钉死在「暂无歌词」。
    if (!PGLyricsAreUsable(lines)) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        return @[];
    }
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
    // 网易云有 `[00:00.00-1]` 这种写法：`-1` 是行偏移标记，不属于时间本身。
    // 不剥掉它，这一行就会被当成"元信息"整行丢弃 —— 有些歌的歌词全是这个格式，
    // 结果解析出来一句都不剩，卡片永远显示「暂无歌词」。
    NSString *stamp = text;
    NSRange dash = [text rangeOfString:@"-" options:NSBackwardsSearch];
    if (dash.location != NSNotFound) {
        NSString *suffix = [text substringFromIndex:dash.location + 1];
        NSCharacterSet *digitsOnly = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
        if (suffix.length > 0 &&
            [suffix rangeOfCharacterFromSet:digitsOnly.invertedSet].location == NSNotFound) {
            stamp = [text substringToIndex:dash.location];
        }
    }

    NSArray<NSString *> *parts = [stamp componentsSeparatedByString:@":"];
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
