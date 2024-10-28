################################################################################
#
# flutter-image-example
#
################################################################################

FLUTTER_IMAGE_EXAMPLE_VERSION = $(FLUTTER_PACKAGES_VERSION)
FLUTTER_IMAGE_EXAMPLE_SITE = $(FLUTTER_PACKAGES_SITE)
FLUTTER_IMAGE_EXAMPLE_SITE_METHOD = $(FLUTTER_PACKAGES_SITE_METHOD)
FLUTTER_IMAGE_EXAMPLE_SOURCE = $(FLUTTER_PACKAGES_SOURCE)
FLUTTER_IMAGE_EXAMPLE_LICENSE = $(FLUTTER_PACKAGES_LICENSE)
FLUTTER_IMAGE_EXAMPLE_LICENSE_FILES = $(FLUTTER_PACKAGES_LICENSE_FILES)
FLUTTER_IMAGE_EXAMPLE_DL_SUBDIR = $(FLUTTER_PACKAGES_DL_SUBDIR)
FLUTTER_IMAGE_EXAMPLE_DEPENDENCIES = $(FLUTTER_PACKAGES_DEPENDENCIES)
FLUTTER_IMAGE_EXAMPLE_PKG_NAME = flutter_image_example
FLUTTER_IMAGE_EXAMPLE_INSTALL_DIR = $(TARGET_DIR)/usr/share/flutter/$(FLUTTER_IMAGE_EXAMPLE_PKG_NAME)/$(FLUTTER_ENGINE_RUNTIME_MODE)
FLUTTER_IMAGE_EXAMPLE_SUBDIR = packages/flutter_image/example

define FLUTTER_IMAGE_EXAMPLE_CONFIGURE_CMDS
	cd $(FLUTTER_IMAGE_EXAMPLE_BUILDDIR) && \
		$(HOST_FLUTTER_SDK_BIN_FLUTTER) clean && \
		$(HOST_FLUTTER_SDK_BIN_FLUTTER) pub get && \
		$(HOST_FLUTTER_SDK_BIN_FLUTTER) build bundle
endef

define FLUTTER_IMAGE_EXAMPLE_BUILD_CMDS
	cd $(FLUTTER_IMAGE_EXAMPLE_BUILDDIR) && \
		$(HOST_FLUTTER_SDK_BIN_DART_BIN) \
			--native-assets $(FLUTTER_IMAGE_EXAMPLE_BUILDDIR)/.dart_tool/flutter_build/*/native_assets.yaml \
			package:$(FLUTTER_IMAGE_EXAMPLE_PKG_NAME)/main.dart && \
		$(HOST_FLUTTER_SDK_BIN_ENV) $(FLUTTER_ENGINE_GEN_SNAPSHOT) \
			--deterministic \
			--obfuscate \
			--snapshot_kind=app-aot-elf \
			--elf=libapp.so \
			.dart_tool/flutter_build/*/app.dill
endef

define FLUTTER_IMAGE_EXAMPLE_INSTALL_TARGET_CMDS
	mkdir -p $(FLUTTER_IMAGE_EXAMPLE_INSTALL_DIR)/{data,lib}
	cp -dprf $(FLUTTER_IMAGE_EXAMPLE_BUILDDIR)/build/flutter_assets $(FLUTTER_IMAGE_EXAMPLE_INSTALL_DIR)/data/

	$(INSTALL) -D -m 0755 $(FLUTTER_IMAGE_EXAMPLE_BUILDDIR)/libapp.so \
		$(FLUTTER_IMAGE_EXAMPLE_INSTALL_DIR)/lib/libapp.so

	ln -sf /usr/share/flutter/$(FLUTTER_ENGINE_RUNTIME_MODE)/data/icudtl.dat \
	$(FLUTTER_IMAGE_EXAMPLE_INSTALL_DIR)/data/

	ln -sf /usr/lib/libflutter_engine.so $(FLUTTER_IMAGE_EXAMPLE_INSTALL_DIR)/lib/
	$(RM) $(FLUTTER_IMAGE_EXAMPLE_INSTALL_DIR)/data/flutter_assets/kernel_blob.bin
	touch $(FLUTTER_IMAGE_EXAMPLE_INSTALL_DIR)/data/flutter_assets/kernel_blob.bin
endef

$(eval $(generic-package))
