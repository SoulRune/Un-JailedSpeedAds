# Subprojects are built by their own make pass and don't inherit the top Makefile,
# so repeat the arch/target/linker settings here (see ../Makefile for the why).
ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = adspeedprefs

adspeedprefs_FILES = ASPListBase.m ASPRootListController.m ASPAppListController.m
adspeedprefs_INSTALL_PATH = /Library/PreferenceBundles
adspeedprefs_FRAMEWORKS = UIKit
adspeedprefs_PRIVATE_FRAMEWORKS = Preferences
adspeedprefs_CFLAGS = -fobjc-arc
adspeedprefs_LDFLAGS = -Wl,-platform_version,ios,15.0,16.5

include $(THEOS_MAKE_PATH)/bundle.mk
