################################################################################
#
# kernel-wireless-regdb
#
################################################################################

KERNEL_WIRELESS_REGDB_SOURCE = wireless-regdb-$(WIRELESS_REGDB_VERSION).tar.xz
KERNEL_WIRELESS_REGDB_SITE = http://kernel.org/pub/software/network/wireless-regdb
KERNEL_WIRELESS_REGDB_LICENSE = ISC
KERNEL_WIRELESS_REGDB_LICENSE_FILES = LICENSE

$(eval $(generic-package))
