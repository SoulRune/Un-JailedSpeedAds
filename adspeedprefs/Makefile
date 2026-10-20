# A subproject doesn't inherit the top Makefile's settings, so they're repeated here.
# Keep ARCHS = arm64 (see ../Makefile); ARCHS given on the command line overrides it.
ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = adspeedprefs

adspeedprefs_FILES = ASPListBase.m ASPRootListController.m ASPAppListController.m
adspeedprefs_INSTALL_PATH = /Library/PreferenceBundles
adspeedprefs_FRAMEWORKS = UIKit
adspeedprefs_PRIVATE_FRAMEWORKS = Preferences
adspeedprefs_CFLAGS = -fobjc-arc
adspeedprefs_LDFLAGS = -Wl,-platform_version,ios,14.0,16.5

include $(THEOS_MAKE_PATH)/bundle.mk
