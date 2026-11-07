export THEOS_PACKAGE_SCHEME = rootless   # rootful: make package THEOS_PACKAGE_SCHEME=

# arm64 only, because of Linux/WSL builds: that toolchain's clang doesn't give arm64e
# its own CPU subtype, so lipo can't merge the two slices. arm64 is enough for App Store
# apps. On A12+ the Settings panel and system processes need arm64e, so release builds
# are made on macOS (GitHub Actions) with ARCHS="arm64 arm64e" on the command line,
# which also applies to adspeedprefs.
ARCHS = arm64
# iOS 14.0 minimum (rootful; rootless jailbreaks start at 15). "latest" = newest SDK.
TARGET = iphone:clang:latest:14.0
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
adspeed_LDFLAGS = -Wl,-platform_version,ios,14.0,16.5

# Build the per-app Settings panel together with the tweak.
SUBPROJECTS = adspeedprefs

# JAILED=1 -> standalone dylib for .ipa injection, configured by an optional adspeed.plist.
# The Settings-panel helpers are unused there, so silence -Werror on them.
ifeq ($(JAILED),1)
adspeed_CFLAGS += -DADSPEED_JAILED -Wno-unused-function -Wno-unused-const-variable -Wno-unused-variable
SUBPROJECTS =
endif

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

# Package icon for Sileo / Zebra / Cydia; the path follows the rootless/rootful prefix.
before-package:: $(THEOS_STAGING_DIR)/DEBIAN/control
	@echo "Icon: file://$(THEOS_PACKAGE_INSTALL_PREFIX)/Library/PreferenceBundles/adspeedprefs.bundle/package-icon.png" >> "$(THEOS_STAGING_DIR)/DEBIAN/control"

# `make jailed` builds packages/adspeed-jailed.zip: the dylib, adspeed.plist and README.txt.
.PHONY: jailed
jailed:
	@$(MAKE) JAILED=1
	@rm -rf packages/jailed && mkdir -p packages/jailed
	@cp "$$(ls $(THEOS_OBJ_DIR)/adspeed.dylib 2>/dev/null || find .theos/obj -name adspeed.dylib | head -n1)" packages/jailed/adspeed-jailed.dylib
	@cp adspeed-jailed.example.plist packages/jailed/adspeed.plist
	@cp jailed-README.txt packages/jailed/README.txt
	@rm -f packages/adspeed-jailed.zip
	@cd packages/jailed && zip -q -X ../adspeed-jailed.zip adspeed-jailed.dylib adspeed.plist README.txt
	@echo "==> packages/adspeed-jailed.zip"
