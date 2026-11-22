#import "PGNowPlaying.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

/// 日志函数在 PGGrabberLandscapeBar.m 里实现，写到 /var/mobile/Media/PerfectGrabber.log。
extern void PGDebugLog(NSString *format, ...);

#pragma mark - MediaRemote 符号

static void (*PGMRRegister)(dispatch_queue_t);
static void (*PGMRGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
static void (*PGMRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
static void (*PGMRGetClient)(dispatch_queue_t, void (^)(id));
static void (*PGMRGetPID)(dispatch_queue_t, void (^)(int));
static Boolean (*PGMRSendCommand)(int, CFDictionaryRef);

static dispatch_once_t PGMRLoadOnce;
static BOOL PGMRRegistered = NO;

static void PGLoadMediaRemote(void) {
    dispatch_once(&PGMRLoadOnce, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
                              RTLD_LAZY);
        if (!handle) {
            PGDebugLog(@"MediaRemote: dlopen 失败 (%s)", dlerror() ?: "-");
            return;
        }
        PGMRRegister = (void (*)(dispatch_queue_t))dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        PGMRGetInfo = (void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        PGMRGetIsPlaying = (void (*)(dispatch_queue_t, void (^)(Boolean)))dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        PGMRGetClient = (void (*)(dispatch_queue_t, void (^)(id)))dlsym(handle, "MRMediaRemoteGetNowPlayingClient");
        PGMRGetPID = (void (*)(dispatch_queue_t, void (^)(int)))dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        PGMRSendCommand = (Boolean (*)(int, CFDictionaryRef))dlsym(handle, "MRMediaRemoteSendCommand");
        PGDebugLog(@"MediaRemote: 已加载 注册=%d 状态=%d 命令=%d 客户端=%d",
                   PGMRRegister != NULL, PGMRGetInfo != NULL,
                   PGMRSendCommand != NULL, PGMRGetClient != NULL);
    });
}

#pragma mark - 前台 App / pid → bundle id

static NSString *PGStringFromObject(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *PGFrontmostBundleIdentifier(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return nil;
    @try {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));
        if (!workspace) return nil;
        SEL selector = @selector(frontmostApplication);
        if (![workspace respondsToSelector:selector]) return nil;
        id application = ((id (*)(id, SEL))objc_msgSend)(workspace, selector);
        return PGStringFromObject(application, @"bundleIdentifier");
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *PGBundleIdentifierForPID(int pid) {
    if (pid <= 0) return nil;
    Class controllerClass = NSClassFromString(@"SBApplicationController");
    if (!controllerClass) return nil;
    @try {
        id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, @selector(sharedInstance));
        SEL selector = @selector(applicationWithPid:);
        if (![controller respondsToSelector:selector]) return nil;
        id application = ((id (*)(id, SEL, int))objc_msgSend)(controller, selector, pid);
        return PGStringFromObject(application, @"bundleIdentifier");
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

#pragma mark -

@interface PGNowPlaying ()
@property (nonatomic, assign) BOOL monitoring;
@property (nonatomic, assign, getter=isPlaying) BOOL playing;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *artist;
@property (nonatomic, copy, nullable) NSString *bundleIdentifier;
@property (nonatomic, copy, nullable) NSString *frontmostBundleIdentifier;
@property (nonatomic, copy) NSString *signature;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) dispatch_queue_t queue;
@end

@implementation PGNowPlaying

+ (instancetype)sharedInstance {
    static PGNowPlaying *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _signature = @"";
        _queue = dispatch_queue_create("com.netskao.perfectgrabber.nowplaying", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark 生命周期

- (void)startMonitoring {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startMonitoring];
        });
        return;
    }
    if (self.monitoring) return;

    PGLoadMediaRemote();
    if (!PGMRRegister) {
        PGDebugLog(@"MediaRemote: 注册函数缺失，音乐功能不可用");
        return;
    }

    self.monitoring = YES;
    if (!PGMRRegistered) {
        PGMRRegistered = YES;
        // 注册到主队列：通知回调直接落在主线程，读取状态和刷新 UI 都不用再跨线程。
        PGMRRegister(dispatch_get_main_queue());
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
            [center addObserver:self selector:@selector(handleMediaNotification:) name:name object:nil];
        }
    }

    // 兜底轮询：少数 App 不发声通知，2.5 秒对一次状态，代价可忽略。
    [self.pollTimer invalidate];
    NSTimer *timer = [NSTimer timerWithTimeInterval:2.5
                                             target:self
                                           selector:@selector(handlePollTimer)
                                           userInfo:nil
                                            repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    self.pollTimer = timer;

    [self refresh];
}

- (void)stopMonitoring {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopMonitoring];
        });
        return;
    }
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    if (self.monitoring) {
        [NSNotificationCenter.defaultCenter removeObserver:self];
    }
    self.monitoring = NO;
}

- (void)handleMediaNotification:(NSNotification *)notification {
    [self refresh];
}

- (void)handlePollTimer {
    [self refresh];
}

#pragma mark 查询

- (void)refresh {
    if (!self.monitoring) return;
    [self fetchInfo];
    [self fetchIsPlaying];
    [self fetchClient];
    self.frontmostBundleIdentifier = PGFrontmostBundleIdentifier();
}

- (void)fetchInfo {
    if (!PGMRGetInfo) return;
    __weak typeof(self) weakSelf = self;
    PGMRGetInfo(self.queue, ^(CFDictionaryRef information) {
        NSDictionary *dictionary = information ? [(__bridge NSDictionary *)information copy] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf applyInformation:dictionary];
        });
    });
}

- (void)fetchIsPlaying {
    if (!PGMRGetIsPlaying) return;
    __weak typeof(self) weakSelf = self;
    PGMRGetIsPlaying(self.queue, ^(Boolean isPlaying) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.playing = isPlaying ? YES : NO;
            [weakSelf notifyIfChanged];
        });
    });
}

- (void)fetchClient {
    __weak typeof(self) weakSelf = self;
    if (PGMRGetClient) {
        PGMRGetClient(self.queue, ^(id client) {
            NSString *bundle = PGStringFromObject(client, @"bundleIdentifier");
            int pid = 0;
            if (bundle.length == 0) {
                SEL selector = @selector(pid);
                if ([client respondsToSelector:selector]) {
                    @try {
                        pid = ((int (*)(id, SEL))objc_msgSend)(client, selector);
                    } @catch (__unused NSException *exception) {
                        pid = 0;
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf applyBundleIdentifier:bundle pid:pid];
            });
        });
        return;
    }
    if (PGMRGetPID) {
        PGMRGetPID(self.queue, ^(int pid) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf applyBundleIdentifier:nil pid:pid];
            });
        });
    }
}

- (void)applyInformation:(NSDictionary *)dictionary {
    if (!dictionary) {
        self.title = nil;
        self.artist = nil;
    } else {
        id title = dictionary[@"kMRMediaRemoteNowPlayingInfoTitle"];
        id artist = dictionary[@"kMRMediaRemoteNowPlayingInfoArtist"];
        self.title = [title isKindOfClass:NSString.class] ? title : nil;
        self.artist = [artist isKindOfClass:NSString.class] ? artist : nil;

        id rate = dictionary[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
        if ([rate respondsToSelector:@selector(doubleValue)]) {
            // 有的设备 isPlaying 回调不来，用播放速率兜一下。
            self.playing = [rate doubleValue] > 0.01;
        }
    }
    [self notifyIfChanged];
}

- (void)applyBundleIdentifier:(NSString *)bundleIdentifier pid:(int)pid {
    NSString *resolved = bundleIdentifier.length ? bundleIdentifier : PGBundleIdentifierForPID(pid);
    self.bundleIdentifier = resolved;
    [self notifyIfChanged];
}

- (void)notifyIfChanged {
    NSString *signature = [NSString stringWithFormat:@"%d|%@|%@|%@|%@",
                           self.playing,
                           self.title ?: @"", self.artist ?: @"",
                           self.bundleIdentifier ?: @"",
                           self.frontmostBundleIdentifier ?: @""];
    if ([signature isEqualToString:self.signature]) return;
    BOOL firstTime = self.signature.length == 0;
    self.signature = signature;
    if (firstTime) {
        PGDebugLog(@"NowPlaying: 首个状态 playing=%d title=%@ app=%@ front=%@",
                   self.playing, self.title ?: @"-", self.bundleIdentifier ?: @"-",
                   self.frontmostBundleIdentifier ?: @"-");
    }
    if (self.onChange) self.onChange(self);
}

#pragma mark 控制

- (void)sendCommand:(PGMediaCommand)command {
    PGLoadMediaRemote();
    if (!PGMRSendCommand) {
        PGDebugLog(@"MediaRemote: 无法发送命令 %ld（符号缺失）", (long)command);
        return;
    }
    @try {
        Boolean result = PGMRSendCommand((int)command, NULL);
        PGDebugLog(@"MediaRemote: 命令 %ld 发送 %@", (long)command, result ? @"成功" : @"失败");
    } @catch (__unused NSException *exception) {
        PGDebugLog(@"MediaRemote: 命令 %ld 抛出异常", (long)command);
    }
    // MediaRemote 的状态推送有延迟，300ms 后再对一次，让按钮立刻跟上。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self refresh];
    });
}

@end
