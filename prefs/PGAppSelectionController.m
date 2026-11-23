#import "PGAppSelectionController.h"
#import <objc/message.h>

static NSString *const PGAppDomain = @"com.netskao.perfectgrabber";
static NSString *const PGAppAllowListKey = @"LandscapeAppAllowList";
static NSString *const PGAppChangedNotification = @"com.netskao.perfectgrabber.settingschanged";

/// 每个 App 存一条：name / bundleID / icon。
static NSString *const PGAppNameKey = @"name";
static NSString *const PGAppBundleKey = @"bundleID";
static NSString *const PGAppIconKey = @"icon";

#pragma mark - 偏好读写

static NSArray<NSString *> *PGReadAllowList(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)PGAppAllowListKey,
                                                        (__bridge CFStringRef)PGAppDomain);
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:[NSArray class]] ? object : @[];
}

static void PGWriteAllowList(NSArray<NSString *> *list) {
    NSArray *sorted = [list sortedArrayUsingSelector:@selector(compare:)];
    CFPreferencesSetAppValue((__bridge CFStringRef)PGAppAllowListKey,
                             (__bridge CFPropertyListRef)sorted,
                             (__bridge CFStringRef)PGAppDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)PGAppDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)PGAppChangedNotification,
                                         NULL, NULL, YES);
}

#pragma mark - 已安装 App 枚举

/// LSApplicationWorkspace / LSApplicationProxy 都是私有类，设置进程（Preferences）里需要在运行时
/// 动态取。任何一步拿不到就返回空数组 —— 列表空着总比设置页直接崩好。
static NSArray<NSDictionary *> *PGInstalledUserApplications(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return @[];

    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));
    if (!workspace) return @[];

    NSSet *proxies = nil;
    @try {
        proxies = ((id (*)(id, SEL))objc_msgSend)(workspace, @selector(allInstalledApplications));
    } @catch (NSException *exception) {
        NSLog(@"[PerfectGrabber] allInstalledApplications 抛异常: %@", exception);
        return @[];
    }
    if (![proxies isKindOfClass:[NSSet class]] && ![proxies isKindOfClass:[NSArray class]]) return @[];

    // 图标只在有这个方法时才取（私有 API，个别系统上被移走）。
    SEL iconSelector = @selector(_applicationIconImageForBundleIdentifier:format:scale:);
    BOOL canDrawIcon = [UIApplication.sharedApplication respondsToSelector:iconSelector];
    CGFloat scale = UIScreen.mainScreen.scale > 0.0 ? UIScreen.mainScreen.scale : 3.0;

    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (id proxy in proxies) {
        NSString *bundleIdentifier = nil;
        NSString *name = nil;
        NSString *type = nil;
        @try {
            bundleIdentifier = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleIdentifier));
            name = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(localizedName));
            type = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(applicationType));
        } @catch (NSException *exception) {
            continue;
        }
        if (![bundleIdentifier isKindOfClass:[NSString class]] || bundleIdentifier.length == 0) continue;
        if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;

        // 只要用户装的 App：applicationType 为 "User"；取不到类型时退化成"不是 com.apple.*"。
        BOOL userApp = [type isKindOfClass:[NSString class]]
            ? [type isEqualToString:@"User"]
            : ![bundleIdentifier hasPrefix:@"com.apple."];
        // Web App / 输入法等也会出现在列表里，但它们没有可横屏的界面，直接跳过。
        if (!userApp) continue;
        if ([bundleIdentifier hasPrefix:@"com.apple.webapp"]) continue;

        UIImage *icon = nil;
        if (canDrawIcon) {
            @try {
                icon = ((id (*)(id, SEL, id, NSInteger, CGFloat))objc_msgSend)(UIApplication.sharedApplication,
                                                                              iconSelector,
                                                                              bundleIdentifier,
                                                                              (NSInteger)0,
                                                                              scale);
            } @catch (NSException *exception) {
                icon = nil;
            }
        }

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[PGAppNameKey] = name;
        entry[PGAppBundleKey] = bundleIdentifier;
        if ([icon isKindOfClass:[UIImage class]]) entry[PGAppIconKey] = icon;
        [result addObject:entry];
    }

    [result sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[PGAppNameKey] localizedStandardCompare:right[PGAppNameKey]];
    }];
    return result;
}

#pragma mark - 选择页

@interface PGAppSelectionController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
@property (nonatomic, strong) NSArray<NSDictionary *> *visibleApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedIdentifiers;
@property (nonatomic, copy) NSString *searchText;
@end

@implementation PGAppSelectionController

- (instancetype)init {
    self = [super init];
    if (self) {
        _selectedIdentifiers = [NSMutableSet setWithArray:PGReadAllowList()];
        _searchText = @"";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"选择 App";
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    } else {
        self.view.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    }

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.bounds.size.width, 44.0)];
    _searchBar.delegate = self;
    _searchBar.placeholder = @"搜索 App";
    _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 52.0;
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.tableHeaderView = _searchBar;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_tableView];

    // 枚举几十上百个 App 要读 LS 数据库，别卡住第一帧。
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *apps = PGInstalledUserApplications();
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.allApps = apps;
            [strongSelf applyFilter];
        });
    });
}

- (void)applyFilter {
    NSString *keyword = [self.searchText stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (keyword.length == 0) {
        self.visibleApps = self.allApps ?: @[];
    } else {
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSDictionary *app in self.allApps ?: @[]) {
            NSString *name = app[PGAppNameKey];
            NSString *bundleID = app[PGAppBundleKey];
            if ([name rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [bundleID rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [filtered addObject:app];
            }
        }
        self.visibleApps = filtered;
    }
    [self.tableView reloadData];
}

#pragma mark 搜索

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.searchText = searchText ?: @"";
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self.searchBar resignFirstResponder];
}

#pragma mark 列表

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.allApps.count == 0) return 1;   // 一个 App 都没取到时给一行解释文字
    return self.visibleApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"PGAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0];
    }

    if (self.allApps.count == 0) {
        cell.textLabel.text = @"没读到已安装的 App";
        cell.detailTextLabel.text = @"请退出设置重新进一次";
        cell.imageView.image = nil;
        cell.accessoryView.hidden = YES;
        return cell;
    }

    cell.accessoryView.hidden = NO;
    NSDictionary *app = self.visibleApps[indexPath.row];
    cell.textLabel.text = app[PGAppNameKey];
    cell.detailTextLabel.text = app[PGAppBundleKey];
    UIImage *icon = app[PGAppIconKey];
    if (icon) {
        cell.imageView.image = icon;
        cell.imageView.layer.cornerRadius = 9.0;
        cell.imageView.layer.cornerCurve = kCACornerCurveContinuous;
        cell.imageView.clipsToBounds = YES;
    } else {
        cell.imageView.image = nil;
    }

    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    toggle.on = [self.selectedIdentifiers containsObject:app[PGAppBundleKey]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (self.allApps.count == 0) return;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    [toggle setOn:!toggle.isOn animated:YES];
    [self commitToggle:toggle atIndexPath:indexPath];   // 整行都能点，不用非得戳那个小开关
}

- (void)toggleChanged:(UISwitch *)toggle {
    // 搜索过滤后 indexPath 会变，用触摸点反查行号，别依赖 tag。
    CGPoint point = [toggle convertPoint:CGPointZero toView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (!indexPath) return;
    [self commitToggle:toggle atIndexPath:indexPath];
}

- (void)commitToggle:(UISwitch *)toggle atIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)self.visibleApps.count) return;
    NSString *bundleIdentifier = self.visibleApps[indexPath.row][PGAppBundleKey];
    if (![bundleIdentifier isKindOfClass:[NSString class]]) return;

    if (toggle.isOn) {
        [self.selectedIdentifiers addObject:bundleIdentifier];
    } else {
        [self.selectedIdentifiers removeObject:bundleIdentifier];
    }
    PGWriteAllowList(self.selectedIdentifiers.allObjects);
}

@end
