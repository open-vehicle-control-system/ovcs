################################################################################
#
# erlang
#
################################################################################

# When updating Erlang, the ERLANG_ERTS_VSN is found in erts/vsn.mk.
ifeq ($(BR2_PACKAGE_ERLANG_21),y)
ERLANG_VERSION = 21.3.8.24
ERLANG_ERTS_VSN = 10.3.5.19
else
ifeq ($(BR2_PACKAGE_ERLANG_22),y)
ERLANG_VERSION = 22.3.4.26
ERLANG_ERTS_VSN = 10.7.2.18
else
ifeq ($(BR2_PACKAGE_ERLANG_23),y)
ERLANG_VERSION = 23.3.4.14
ERLANG_ERTS_VSN = 11.2.2.13
else
ifeq ($(BR2_PACKAGE_ERLANG_24),y)
ERLANG_VERSION = 24.3.2
ERLANG_ERTS_VSN = 12.3
else
ifeq ($(BR2_PACKAGE_ERLANG_25),y)
ERLANG_VERSION = 25.3.2
ERLANG_ERTS_VSN = 13.2.2
else
ifeq ($(BR2_PACKAGE_ERLANG_26),y)
ERLANG_VERSION = 26.2.5
ERLANG_ERTS_VSN = 14.2.5
else
ERLANG_VERSION = 27.0.1
ERLANG_ERTS_VSN = 15.0.1
endif
endif
endif
endif
endif
endif
ERLANG_RELEASE = $(firstword $(subst ., ,$(ERLANG_VERSION)))
ERLANG_SITE = \
	https://github.com/erlang/otp/releases/download/OTP-$(ERLANG_VERSION)
ERLANG_SOURCE = otp_src_$(ERLANG_VERSION).tar.gz
ERLANG_DEPENDENCIES = host-erlang

ERLANG_LICENSE = Apache-2.0
ERLANG_LICENSE_FILES = LICENSE.txt
ERLANG_CPE_ID_VENDOR = erlang
ERLANG_CPE_ID_PRODUCT = erlang\/otp
ERLANG_INSTALL_STAGING = YES
ERLANG_INSTALL_TARGET = NO

define ERLANG_FIX_AUTOCONF_VERSION
	$(SED) "s/USE_AUTOCONF_VERSION=.*/USE_AUTOCONF_VERSION=$(AUTOCONF_VERSION)/" $(@D)/otp_build
endef

# Patched erts/aclocal.m4
define ERLANG_RUN_AUTOCONF
	cd $(@D) && PATH=$(BR_PATH) ./otp_build update_configure --no-commit
endef
ERLANG_DEPENDENCIES += host-autoconf
ERLANG_PRE_CONFIGURE_HOOKS += \
	ERLANG_FIX_AUTOCONF_VERSION \
	ERLANG_RUN_AUTOCONF
HOST_ERLANG_DEPENDENCIES += host-autoconf
HOST_ERLANG_PRE_CONFIGURE_HOOKS += \
	ERLANG_FIX_AUTOCONF_VERSION \
	ERLANG_RUN_AUTOCONF

# Return the EIV (Erlang Interface Version, EI_VSN)
# $(1): base directory, i.e. either $(HOST_DIR) or $(STAGING_DIR)/usr
erlang_ei_vsn = `sed -r -e '/^erl_interface-(.+)/!d; s//\1/' $(1)/lib/erlang/releases/$(ERLANG_RELEASE)/installed_application_versions`

# The configure checks for these functions fail incorrectly
ERLANG_CONF_ENV = ac_cv_func_isnan=yes ac_cv_func_isinf=yes \
		  i_cv_posix_fallocate_works=yes

# Set erl_xcomp variables. See xcomp/erl-xcomp.conf.template
# for documentation.
ERLANG_CONF_ENV += erl_xcomp_sysroot=$(STAGING_DIR)

# Support for CLOCK_THREAD_CPUTIME_ID cannot be autodetected for
# crosscompiling. The man page for clock_gettime(3) indicates that
# Linux 2.6.12 and later support this.
ERLANG_CONF_ENV += erl_xcomp_clock_gettime_cpu_time=yes

ERLANG_CONF_OPTS = --without-javac

ifeq ($(BR2_REPRODUCIBLE),y)
ERLANG_CONF_OPTS += --enable-deterministic-build
endif

# Force ERL_TOP to the downloaded source directory. This prevents
# Erlang's configure script from inadvertantly using files from
# a version of Erlang installed on the host.
ERLANG_CONF_ENV += ERL_TOP=$(@D)
HOST_ERLANG_CONF_ENV += ERL_TOP=$(@D)

# erlang uses openssl for all things crypto. Since the host tools (such as
# rebar) uses crypto, we need to build host-erlang with support for openssl.
HOST_ERLANG_DEPENDENCIES += host-openssl
HOST_ERLANG_CONF_OPTS = --without-javac --with-ssl=$(HOST_DIR)

HOST_ERLANG_CONF_OPTS += --without-termcap

ifeq ($(BR2_PACKAGE_NCURSES),y)
ERLANG_CONF_OPTS += --with-termcap
ERLANG_DEPENDENCIES += ncurses
else
ERLANG_CONF_OPTS += --without-termcap
endif

ifeq ($(BR2_PACKAGE_OPENSSL),y)
ERLANG_CONF_OPTS += --with-ssl
ERLANG_DEPENDENCIES += openssl
else
ERLANG_CONF_OPTS += --without-ssl
endif

ifeq ($(BR2_PACKAGE_UNIXODBC),y)
ERLANG_DEPENDENCIES += unixodbc
ERLANG_CONF_OPTS += --with-odbc
else
ERLANG_CONF_OPTS += --without-odbc
endif

# Always use Buildroot's zlib
ERLANG_CONF_OPTS += --disable-builtin-zlib
ERLANG_DEPENDENCIES += zlib

# Remove source, example, gs and wx files from staging and target.
ERLANG_REMOVE_PACKAGES = gs wx

ifneq ($(BR2_PACKAGE_ERLANG_MEGACO),y)
ERLANG_REMOVE_PACKAGES += megaco
endif

define ERLANG_REMOVE_STAGING_UNUSED
	# Remove intermediate build products that can get copied Erlang
	# release tools.
	find $(STAGING_DIR)/usr/lib/erlang -type d -name obj -prune -exec rm -rf {} \;

	# Remove unwanted packages from being found by the Erlang compiler
	for package in $(ERLANG_REMOVE_PACKAGES); do \
		rm -rf $(STAGING_DIR)/usr/lib/erlang/lib/$${package}-*; \
	done
endef

define ERLANG_REMOVE_TARGET_UNUSED
	# Remove top level installation files
	rm -rf $(TARGET_DIR)/usr/lib/erlang/misc
	rm -f $(TARGET_DIR)/usr/lib/erlang/Install

	# Remove intermediate build products
	find $(TARGET_DIR)/usr/lib/erlang -type d -name obj -prune -exec rm -rf {} \;
	find $(TARGET_DIR)/usr/lib/erlang -name "*.a" -delete

	# Remove source and documentation
	find $(TARGET_DIR)/usr/lib/erlang -name "*.h" -delete
	find $(TARGET_DIR)/usr/lib/erlang -name "*.idl" -delete
	find $(TARGET_DIR)/usr/lib/erlang -name "*.mk" -delete
	find $(TARGET_DIR)/usr/lib/erlang -name "*.erl" -delete
	find $(TARGET_DIR)/usr/lib/erlang -name "README" -delete
	for dir in $(TARGET_DIR)/usr/lib/erlang/erts-* \
		   $(TARGET_DIR)/usr/lib/erlang/lib/*; do \
		rm -rf $${dir}/src $${dir}/c_src $${dir}/doc \
		       $${dir}/man $${dir}/examples $${dir}/emacs; \
	done

	# Remove unwanted packages
	for package in $(ERLANG_REMOVE_PACKAGES); do \
		rm -rf $(TARGET_DIR)/usr/lib/erlang/lib/$${package}-*; \
	done

	# Remove all folders that are now empty
	find $(TARGET_DIR)/usr/lib/erlang -type d -empty -delete
endef

ERLANG_POST_INSTALL_STAGING_HOOKS += ERLANG_REMOVE_STAGING_UNUSED
ERLANG_POST_INSTALL_TARGET_HOOKS += ERLANG_REMOVE_TARGET_UNUSED

$(eval $(autotools-package))
$(eval $(host-autotools-package))
