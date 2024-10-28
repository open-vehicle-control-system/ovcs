################################################################################
#
# Custom logo
#
################################################################################

LINUX_EXTENSIONS += customlogo

define CUSTOMLOGO_PREPARE_KERNEL
	cp $(CUSTOMLOGO_DIR)/logo_linux_*.p?m $(LINUX_DIR)/drivers/video/logo
endef
