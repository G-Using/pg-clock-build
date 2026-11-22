#import "PGHardwareMetrics.h"
#import <IOKit/IOKitLib.h>
#import <sys/sysctl.h>
#import <string.h>
#import <math.h>

/// 日志函数在 PGGrabberLandscapeBar.m 里实现，写到 /var/mobile/Media/PerfectGrabber.log。
extern void PGDebugLog(NSString *format, ...);

/// 合理的处理器频率区间，超出就当没读到（防止把电压值之类的东西当频率显示）。
static const double PGPlausibleMinHz = 1.0e8;
static const double PGPlausibleMaxHz = 6.0e9;

#pragma mark - CPU 频率

/// sysctl 读一个整数值。老芯片是 32 位、新芯片是 64 位，两种都试一遍，
/// 都失败才认为不存在（小端下 4 字节写进 8 字节缓冲的低位，值不会错）。
static double PGSysctlValue(const char *name, BOOL *found) {
    if (found) *found = NO;
    uint64_t wide = 0;
    size_t size = sizeof(wide);
    if (sysctlbyname(name, &wide, &size, NULL, 0) == 0 && size > 0) {
        if (found) *found = YES;
        return (double)wide;
    }
    uint32_t narrow = 0;
    size = sizeof(narrow);
    if (sysctlbyname(name, &narrow, &size, NULL, 0) == 0 && size > 0) {
        if (found) *found = YES;
        return (double)narrow;
    }
    return 0.0;
}

/// voltage-states 里存的是 {频率, 电压} 表。老芯片 4+4 字节，新芯片 8+8 字节，
/// 挨个步长试着解析，取落在合理区间里的最大值。
static double PGMaxFrequencyInVoltageStates(CFTypeRef value) {
    if (!value) return 0.0;

    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        double number = 0.0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number) &&
            number > PGPlausibleMinHz && number < PGPlausibleMaxHz) {
            return number;
        }
        return 0.0;
    }

    if (CFGetTypeID(value) != CFDataGetTypeID()) return 0.0;
    CFDataRef data = (CFDataRef)value;
    CFIndex length = CFDataGetLength(data);
    const UInt8 *bytes = CFDataGetBytePtr(data);
    if (!bytes || length < 4) return 0.0;

    for (NSUInteger stride = 16; stride >= 4; stride /= 2) {
        if (length % (CFIndex)stride != 0) continue;
        double best = 0.0;
        for (CFIndex offset = 0; offset + (CFIndex)stride <= length; offset += (CFIndex)stride) {
            uint64_t frequency = 0;
            if (stride >= 8) {
                memcpy(&frequency, bytes + offset, sizeof(uint64_t));
            } else {
                uint32_t narrow = 0;
                memcpy(&narrow, bytes + offset, sizeof(uint32_t));
                frequency = narrow;
            }
            if (frequency > PGPlausibleMinHz && frequency < PGPlausibleMaxHz && frequency > best) {
                best = (double)frequency;
            }
        }
        if (best > 0.0) return best;
    }
    return 0.0;
}

static BOOL PGNodeLooksInteresting(io_object_t entry) {
    io_name_t name = {0};
    if (IORegistryEntryGetName(entry, name) == KERN_SUCCESS) {
        NSString *text = [[NSString stringWithUTF8String:name] lowercaseString];
        if ([text containsString:@"pmgr"] || [text containsString:@"cpu"] ||
            [text containsString:@"arm-io"]) {
            return YES;
        }
    }
    io_name_t className = {0};
    if (IOObjectGetClass(entry, className) == KERN_SUCCESS) {
        NSString *text = [[NSString stringWithUTF8String:className] lowercaseString];
        if ([text containsString:@"pmgr"] || [text containsString:@"cpu"]) return YES;
    }
    return NO;
}

static double PGScanNodeFrequency(io_object_t entry, int depth) {
    double best = 0.0;

    if (PGNodeLooksInteresting(entry)) {
        CFMutableDictionaryRef rawProperties = NULL;
        if (IORegistryEntryCreateCFProperties(entry, &rawProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS &&
            rawProperties) {
            NSDictionary *properties = CFBridgingRelease(rawProperties);
            for (id key in properties) {
                if (![key isKindOfClass:NSString.class]) continue;
                if (![(NSString *)key containsString:@"voltage-states"]) continue;
                double value = PGMaxFrequencyInVoltageStates((__bridge CFTypeRef)properties[key]);
                if (value > best) best = value;
            }
        }
    }

    if (depth <= 0) return best;

    io_iterator_t children = 0;
    if (IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS) {
        io_object_t child = 0;
        while ((child = IOIteratorNext(children))) {
            double value = PGScanNodeFrequency(child, depth - 1);
            if (value > best) best = value;
            IOObjectRelease(child);
        }
        IOObjectRelease(children);
    }
    return best;
}

/// 扫 arm-io 下面 3 层子节点，找名字/类名像 pmgr/cpu 的，读它的 voltage-states 表。
static double PGScanFrequencyFromRegistry(void) {
    io_iterator_t iterator = 0;
    // 0 == 主端口，iOS 上没有 kIOMasterPortDefault 这个符号，传 0 等价。
    if (IOServiceGetMatchingServices(0, IOServiceMatching("AppleARMIODevice"), &iterator) != KERN_SUCCESS) {
        return 0.0;
    }
    double best = 0.0;
    io_object_t device = 0;
    while ((device = IOIteratorNext(iterator))) {
        double value = PGScanNodeFrequency(device, 3);
        if (value > best) best = value;
        IOObjectRelease(device);
    }
    IOObjectRelease(iterator);
    return best;
}

double PGCPUCurrentFrequencyGHz(void) {
    // IORegistry 扫描比较重，频率又是静态的，缓存 60 秒足够。
    static double cachedGHz = 0.0;
    static CFAbsoluteTime cachedAt = 0.0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (cachedAt > 0.0 && now - cachedAt < 60.0) return cachedGHz;

    cachedAt = now;

    BOOL found = NO;
    double hertz = PGSysctlValue("hw.cpufrequency", &found);
    NSString *source = @"sysctl hw.cpufrequency";
    if (hertz < PGPlausibleMinHz || hertz > PGPlausibleMaxHz) {
        hertz = PGSysctlValue("hw.cpufrequency_max", &found);
        source = @"sysctl hw.cpufrequency_max";
    }
    if (hertz < PGPlausibleMinHz || hertz > PGPlausibleMaxHz) {
        hertz = PGScanFrequencyFromRegistry();
        source = @"IORegistry pmgr voltage-states";
    }

    double gigahertz = (hertz >= PGPlausibleMinHz && hertz <= PGPlausibleMaxHz) ? hertz / 1e9 : 0.0;
    cachedGHz = gigahertz;
    PGDebugLog(@"硬件指标: CPU 频率来源=%@ 值=%.2fGHz", source, gigahertz);
    return gigahertz;
}

#pragma mark - 电池温度

/// 不同机型/系统的 Temperature 单位不一样（0.01℃、0.1℃、甚至开尔文），
/// 逐个换算，取第一个落在"手机可能出现的温度"区间里的。
static double PGPlausibleCelsius(double raw) {
    double candidates[4] = {
        raw / 100.0,             // 0.01℃（iOS 上最常见）
        raw / 10.0,              // 0.1℃ / 0.1K
        raw,                     // 已经是℃
        raw / 1000.0 - 273.15    // 毫开尔文
    };
    for (int index = 0; index < 4; index++) {
        double celsius = candidates[index];
        if (celsius > 5.0 && celsius < 95.0) return celsius;
    }
    return NAN;
}

static double PGReadTemperatureFromService(NSString *className) {
    io_service_t service = IOServiceGetMatchingService(0, IOServiceMatching(className.UTF8String));
    if (!service) return NAN;

    double result = NAN;
    for (NSString *key in @[@"Temperature", @"VirtualTemperature"]) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key,
                                                          kCFAllocatorDefault, 0);
        if (!value) continue;
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            double raw = 0.0;
            if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &raw)) {
                result = PGPlausibleCelsius(raw);
            }
        }
        CFRelease(value);
        if (!isnan(result)) break;
    }

    IOObjectRelease(service);
    return result;
}

double PGBatteryTemperatureCelsius(void) {
    static BOOL loggedFailure = NO;
    for (NSString *name in @[@"AppleSmartBattery", @"AppleARMPMUCharger", @"IOPMPowerSource"]) {
        double celsius = PGReadTemperatureFromService(name);
        if (!isnan(celsius)) return celsius;
    }
    if (!loggedFailure) {
        loggedFailure = YES;
        PGDebugLog(@"硬件指标: 读不到电池温度（IOKit 三个服务都没有 Temperature）");
    }
    return NAN;
}
