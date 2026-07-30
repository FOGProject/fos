################################################################################
#
# partclone
#
################################################################################

PARTCLONE_VERSION = 0.3.47
PARTCLONE_SOURCE = partclone-$(PARTCLONE_VERSION).tar.gz
PARTCLONE_SITE = $(call github,Thomas-Tsai,partclone,$(PARTCLONE_VERSION))
PARTCLONE_INSTALL_STAGING = YES
PARTCLONE_AUTORECONF = YES
PARTCLONE_DEPENDENCIES += host-pkgconf host-gettext util-linux e2fsprogs liburcu
PARTCLONE_CONF_OPTS = --enable-static-linking --enable-xfs --enable-btrfs --enable-ntfs --enable-extfs --enable-fat --enable-hfsp --enable-apfs --enable-ncursesw --enable-f2fs --disable-xxhash
PARTCLONE_EXTRA_LIBS = -ldl -latomic
PARTCLONE_CONF_ENV += LIBS="$(PARTCLONE_EXTRA_LIBS)"

define PARTCLONE_PRE_CONFIGURE_AUTOGEN
    cd $(@D)/ && ./autogen
endef

PARTCLONE_PRE_CONFIGURE_HOOKS += PARTCLONE_PRE_CONFIGURE_AUTOGEN

$(eval $(autotools-package))
