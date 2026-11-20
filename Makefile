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
PerfectGrabberSettings_CFLAGS = -fobjc-arc
# 注意：不要写 PRIVATE_FRAMEWORKS = Preferences —— iOS SDK 里没有 Preferences.framework 的
# stub 库（只有头文件），显式 -framework Preferences 会导致 ld: framework not found。
# PSListController / PSSpecifier 等符号在设备上由 Preferences.framework 运行时提供，
# bundle 默认的 -undefined dynamic_lookup 足够。
PerfectGrabberSettings_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
