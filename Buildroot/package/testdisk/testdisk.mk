#############################################################
#
# testdisk
#
#############################################################
TESTDISK_VERSION:=7.2
TESTDISK_SOURCE:=testdisk-$(TESTDISK_VERSION).tar.bz2
# https, not http: plain HTTP is what corporate egress filtering drops.
# build.sh seeds the download directory from a mirror before Buildroot looks
# at it; see seedFragileSources() there.
TESTDISK_SITE:=https://www.cgsecurity.org
TESTDISK_INSTALL_STAGING=YES
TESTDISK_LIBTOOL_PATCH=NO
TESTDISK_CONF_OPTS = --program-transform-name=
TESTDISK_DEPENDENCIES = ncurses

$(eval $(autotools-package))
