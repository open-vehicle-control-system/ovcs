################################################################################
# Linux wireless-regdb extension
#
# Patch the linux kernel with the latest wireless-regdb database.
# This enables the CONFIG_CFG80211_INTERNAL_REGDB kernel option.
################################################################################

LINUX_EXTENSIONS += kernel-wireless-regdb

define KERNEL_WIRELESS_REGDB_PREPARE_KERNEL
	cp -pf $(KERNEL_WIRELESS_REGDB_DIR)/db.txt $(LINUX_DIR)/net/wireless/db.txt
endef
