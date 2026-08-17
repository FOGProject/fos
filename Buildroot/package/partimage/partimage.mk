################################################################################
#
# partimage
#
################################################################################

PARTIMAGE_VERSION = 0.6.9
PARTIMAGE_SOURCE = partimage-$(PARTIMAGE_VERSION).tar.bz2
# https, not http: plain HTTP is what corporate egress filtering drops.
# build.sh seeds the download directory from a mirror before Buildroot looks
# at it; see seedFragileSources() there.
PARTIMAGE_SITE = https://downloads.sourceforge.net/project/partimage/stable/0.6.9
PARTIMAGE_DEPENDENCIES = e2fsprogs
PARTIMAGE_INSTALL_STAGING = YES
PARTIMAGE_CONF_OPTS = ac_cv_func_setpgrp_void=yes --disable-ssl

$(eval $(autotools-package))
