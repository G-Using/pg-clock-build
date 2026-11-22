#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 当前 CPU 频率（GHz）。读不到返回 0。
/// 说明：iOS 不向用户态暴露真正的"瞬时主频"，能拿到的是芯片 DVFS 表里该设备
/// 性能核的最高档位（sysctl 若给了 hw.cpufrequency 就用它，否则扫 IORegistry 的
/// pmgr voltage-states 表取最大值）。所以这个数字代表"这颗芯片现在能跑到的频率"，
/// 会随负载在当前档位与最高档之间波动的是占用率，不是它 —— 别把它当动态曲线用。
double PGCPUCurrentFrequencyGHz(void);

/// 电池温度（摄氏度）。读不到返回 NAN。
double PGBatteryTemperatureCelsius(void);

NS_ASSUME_NONNULL_END
