################################################################################
#
# udpcast
#
################################################################################

# FOS override: a copy of Buildroot 2026.02.1's udpcast.mk plus
# UDPCAST_AUTORECONF. Re-diff it against upstream on a BUILDROOT_VERSION bump.
# Patch 0001 is Buildroot's own (musl); FOS's IPv6 patches are 0002-0004.
UDPCAST_VERSION = 20250223
UDPCAST_SITE = https://www.udpcast.linux.lu/download
UDPCAST_DEPENDENCIES = host-m4
# Patch 0004 changes configure.ac; without autoreconf the build stays IPv4 only.
UDPCAST_AUTORECONF = YES
UDPCAST_LICENSE = BSD-2-Clause, GPL-2.0+
UDPCAST_LICENSE_FILES = COPYING
UDPCAST_TARGETS = \
	$(if $(BR2_PACKAGE_UDPCAST_RECEIVER),udp-receiver) \
	$(if $(BR2_PACKAGE_UDPCAST_SENDER),udp-sender)
UDPCAST_MAKE_OPTS = $(UDPCAST_TARGETS)

define UDPCAST_INSTALL_TARGET_CMDS
	$(foreach f,$(UDPCAST_TARGETS),\
		$(INSTALL) -D -m 755 $(@D)/$(f) $(TARGET_DIR)/usr/sbin/$(f)
	)
endef

$(eval $(autotools-package))
