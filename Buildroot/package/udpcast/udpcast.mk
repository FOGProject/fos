################################################################################
#
# udpcast
#
################################################################################

# FOS override: a copy of Buildroot 2026.02.1's udpcast.mk, pointed at
# FOGProject/udpcast. That release is upstream 20250223 plus FOG's IPv6 port,
# with a generated configure, so the build needs no autoreconf.
# Buildroot's own patch 0001 (musl) still applies.
# Re-diff this file against upstream on a BUILDROOT_VERSION bump.
# Bump the version and udpcast.hash together.
UDPCAST_VERSION = v20250223-fog.1
UDPCAST_SOURCE = udpcast-$(UDPCAST_VERSION).tar.gz
UDPCAST_SITE = https://github.com/FOGProject/udpcast/releases/download/$(UDPCAST_VERSION)
UDPCAST_DEPENDENCIES = host-m4
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
