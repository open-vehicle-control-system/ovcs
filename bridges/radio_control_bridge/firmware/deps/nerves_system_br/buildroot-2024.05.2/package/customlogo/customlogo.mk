################################################################################
#
# customlogo
#
################################################################################

CUSTOMLOGO_SOURCE =

ifneq ($(findstring _clut224.ppm,$(BR2_PACKAGE_CUSTOMLOGO_PATH)),)
define CUSTOMLOGO_BUILD_CMDS
	cp $(BR2_PACKAGE_CUSTOMLOGO_PATH) $(@D)/logo_linux_clut224.ppm
endef
else ifneq ($(findstring .pbm,$(BR2_PACKAGE_CUSTOMLOGO_PATH)),)
define CUSTOMLOGO_BUILD_CMDS
	cp $(BR2_PACKAGE_CUSTOMLOGO_PATH) $(@D)/logo_linux_mono.pbm
endef
else
define CUSTOMLOGO_BUILD_CMDS
	convert $(BR2_PACKAGE_CUSTOMLOGO_PATH) \
		-dither None -colors 224 -compress none \
		$(@D)/logo_linux_clut224.ppm
endef
endif

$(eval $(generic-package))
