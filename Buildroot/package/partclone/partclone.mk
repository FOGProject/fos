################################################################################
#
# partclone
#
################################################################################

PARTCLONE_VERSION = 52fe01431e1ab00d5a47dee83014515b29c36e61
PARTCLONE_SITE = $(call github,FOGProject,partclone,$(PARTCLONE_VERSION))
PARTCLONE_INSTALL_STAGING = YES
PARTCLONE_AUTORECONF = YES
PARTCLONE_DEPENDENCIES += attr e2fsprogs libgcrypt lzo xz zlib xfsprogs ncurses host-pkgconf
PARTCLONE_CONF_OPTS = --enable-static --enable-xfs --enable-btrfs --enable-ntfs --enable-extfs --enable-fat --enable-hfsp --enable-apfs --enable-ncursesw

define PARTCLONE_LINK_LIBRARIES_TOOL
	ln -f -s $(BUILD_DIR)/xfsprogs-*/include/xfs $(STAGING_DIR)/usr/include/
	ln -f -s $(BUILD_DIR)/xfsprogs-*/libxfs/.libs/libxfs.* $(STAGING_DIR)/usr/lib/
	ln -f -s $(@D)/fail-mbr/fail-mbr.bin $(@D)/fail-mbr/fail-mbr.bin.orig
endef

PARTCLONE_POST_PATCH_HOOKS += PARTCLONE_LINK_LIBRARIES_TOOL

$(eval $(autotools-package))
