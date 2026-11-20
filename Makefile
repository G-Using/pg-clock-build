ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PerfectGrabber
PerfectGrabber_FILES = Tweak.xm PerfectGrabberPreferences.m PGGrabberOverlayView.m PGGrabberHUDView.m PGGrabberLandscapeBar.m
PerfectGrabber_CFLAGS = -fobjc-arc
PerfectGrabber_FRAMEWORKS = Foundation UIKit AudioToolbox

BUNDLE_NAME = PerfectGrabberSettings
PerfectGrabberSettings_FILES = prefs/PerfectGrabberSettingsController.m
PerfectGrabberSettings_INSTALL_PATH = /Library/PreferenceBundles
PerfectGrabberSettings_FRAMEWORKS = Foundation UIKit
# -fno-autolink 必须有：#import <Preferences/PSListController.h> 会让 clang modules 自动
# 生成 LC_LINKER_OPTION "-framework Preferences"，而 iOS SDK 里没有这个 framework 的 stub，
# ld 直接报 "Could not find or use auto-linked framework 'Preferences'"。
# 关掉 autolink 后这些符号在设备上由 Preferences.framework 运行时提供（bundle 默认
# -undefined dynamic_lookup）。Foundation/UIKit 已显式写在 _FRAMEWORKS 里，不受影响。
PerfectGrabberSettings_CFLAGS = -fobjc-arc -fno-autolink
PerfectGrabberSettings_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
