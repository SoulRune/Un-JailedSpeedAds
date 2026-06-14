export THEOS_PACKAGE_SCHEME = rootless   # default; for a rootful .deb: make package THEOS_PACKAGE_SCHEME=

# arm64 only by default: the Linux Swift toolchain's clang doesn't tag arm64e with a
# distinct CPU subtype, so lipo can't merge the two slices.
#
# arm64 already covers App Store / user apps (which run as arm64) — the main target for
# ad blocking/speed-up. On A12+ devices the system processes run as arm64e, so add an
# arm64e slice to also hook those, which needs a macOS toolchain. The GitHub Actions
# build (macOS) does exactly that:  make package ARCHS="arm64 arm64e"
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

# JAILED=1 -> standalone "just speed-up" dylib for .ipa injection. The prefs/blocking
# code paths are #ifdef'd out, leaving those helpers unused, so silence -Werror on them.
ifeq ($(JAILED),1)
adspeed_CFLAGS += -DADSPEED_JAILED -Wno-unused-function -Wno-unused-const-variable -Wno-unused-variable
SUBPROJECTS =
endif

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

# `make jailed` builds the injection dylib (web speed-up only) and drops it into
# packages/ next to the .debs. Inject it into an .ipa via TrollFools / Sideloadly.
.PHONY: jailed
jailed:
	@$(MAKE) JAILED=1
	@mkdir -p packages
	@cp "$$(ls $(THEOS_OBJ_DIR)/adspeed.dylib 2>/dev/null || find .theos/obj -name adspeed.dylib | head -n1)" packages/adspeed-jailed.dylib
	@echo "==> packages/adspeed-jailed.dylib"
