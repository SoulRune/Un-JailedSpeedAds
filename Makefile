export THEOS_PACKAGE_SCHEME = rootless   # rootless-only package

# arm64 only: the Linux Swift toolchain's clang doesn't tag arm64e with a distinct
# CPU subtype, so lipo can't merge the two slices. arm64 is enough for App Store /
# user apps (which run as arm64); add arm64e back when building on a macOS toolchain.
ARCHS = arm64
# platform:compiler:sdk:deployment. iOS 15.0 minimum (rootless-only tweak).
# A modern minimum also makes clang emit the new -platform_version flag that
# ld64.lld requires. "latest" picks the newest installed SDK.
TARGET = iphone:clang:latest:15.0
DEBUG = 0
FINALPACKAGE = 1
FOR_RELEASE = 1
IGNORE_WARNINGS = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = adspeed

adspeed_FILES = Tweak.xm
adspeed_CFLAGS = -fobjc-arc
adspeed_CCFLAGS = -std=c++11 -fno-rtti -fno-exceptions -DNDEBUG
adspeed_FRAMEWORKS = UIKit QuartzCore CoreGraphics AVFoundation WebKit
adspeed_LDFLAGS = -Wl,-platform_version,ios,15.0,16.5

# Build the per-app Settings panel together with the tweak.
SUBPROJECTS = adspeedprefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
