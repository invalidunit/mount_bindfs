TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

# 通过 make SCHEME=xxx 选择编译方案
# 用法：
#   make SCHEME=roothide
#   make SCHEME=rootless
SCHEME ?= roothide
export THEOS_PACKAGE_SCHEME = $(SCHEME)

include $(THEOS)/makefiles/common.mk

TOOL_NAME = mount_bindfs auto-bindfs-prefs

mount_bindfs_FILES = mount_bindfs.c
mount_bindfs_FRAMEWORKS = CoreFoundation
mount_bindfs_INSTALL_PATH = /usr/sbin
mount_bindfs_LDFLAGS += -Wl,-undefined,dynamic_lookup

auto-bindfs-prefs_FILES = auto-bindfs-prefs.c
auto-bindfs-prefs_INSTALL_PATH = /usr/libexec/mount_bindfs
auto-bindfs-prefs_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/aggregate.mk

clean::
	rm -rf packages

before-package::
	ldid -Sentitlements.plist $(THEOS_STAGING_DIR)/usr/sbin/mount_bindfs
	ldid -Sentitlements.plist $(THEOS_STAGING_DIR)/usr/libexec/mount_bindfs/auto-bindfs-prefs
	chmod 0755 $(THEOS_STAGING_DIR)/usr/libexec/mount_bindfs/auto-bindfs-wrapper
	chmod 4755 $(THEOS_STAGING_DIR)/usr/libexec/mount_bindfs/auto-bindfs-prefs
