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
PerfectGrabberSettings_PRIVATE_FRAMEWORKS = Preferences
PerfectGrabberSettings_CFLAGS = -fobjc-arc
PerfectGrabberSettings_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
