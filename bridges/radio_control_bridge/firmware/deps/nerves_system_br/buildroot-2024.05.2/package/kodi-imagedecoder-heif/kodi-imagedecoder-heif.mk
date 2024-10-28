################################################################################
#
# kodi-imagedecoder-heif
#
################################################################################

KODI_IMAGEDECODER_HEIF_VERSION = bf9771060dddc753ac7cf1dbf561059cad54dfb0
KODI_IMAGEDECODER_HEIF_SITE = $(call github,xbmc,imagedecoder.heif,$(KODI_IMAGEDECODER_HEIF_VERSION))
KODI_IMAGEDECODER_HEIF_LICENSE = GPL-2.0+
KODI_IMAGEDECODER_HEIF_LICENSE_FILES = LICENSE.md
KODI_IMAGEDECODER_HEIF_DEPENDENCIES = kodi libde265 libheif tinyxml2

$(eval $(cmake-package))
