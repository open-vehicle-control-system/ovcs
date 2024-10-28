# Makefile for building port binaries
#
# Makefile targets:
#
# all/install   build and install the port binary
# clean         clean build products and intermediates
#
# Variables to override:
#
# MIX_APP_PATH  path to the build directory
#
# CC            C compiler
# CROSSCOMPILE	crosscompiler prefix, if any
# CFLAGS	compiler flags for compiling all C files
# LDFLAGS	linker flags for linking all binaries
# PKG_CONFIG_SYSROOT_DIR sysroot for pkg-config (for finding libnl-3)
# PKG_CONFIG_PATH pkg-config metadata
#
ifeq ($(MIX_APP_PATH),)
calling_from_make:
	mix compile
endif

PREFIX = $(MIX_APP_PATH)/priv
BUILD  = $(MIX_APP_PATH)/obj

CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -pedantic

# Check that we're on a supported build platform
ifeq ($(CROSSCOMPILE),)
    # Not crosscompiling, so check that we're on Linux.
    ifeq ($(shell uname -s),Linux)
        CFLAGS += $(shell pkg-config --cflags libnl-genl-3.0)
    else
        $(warning vintage_net_wifi only works on Linux, but crosscompilation)
        $(warning is supported by defining $$CROSSCOMPILE.)
        $(warning See Makefile for details. If using Nerves,)
        $(warning this should be done automatically.)
        $(warning .)
        $(warning Skipping C compilation unless targets explicitly passed to make.)
        DEFAULT_TARGETS ?= $(PREFIX)
    endif
else
    # Crosscompiling
    ifeq ($(PKG_CONFIG_SYSROOT_DIR),)
        # If pkg-config sysroot isn't set, then assume Nerves
        CFLAGS += -I$(NERVES_SDK_SYSROOT)/usr/include/libnl3
    else

        # Use pkg-config to find libnl
        PKG_CONFIG = $(shell which pkg-config)
        ifeq ($(PKG_CONFIG),)
            $(error pkg-config required to build. Install by running "brew install pkg-config")
        endif

        CFLAGS += $(shell $(PKG_CONFIG) --cflags libnl-genl-3.0)
    endif
endif
DEFAULT_TARGETS ?= $(PREFIX) \
		   $(PREFIX)/force_ap_scan \
		   $(PREFIX)/mesh_mode \
		   $(PREFIX)/mesh_param

# Enable for debug messages
# CFLAGS += -DDEBUG

# Unfortunately, depending on the system we're on, we need
# to specify -std=c99 or -std=gnu99. The later is more correct,
# but it fails to build on many setups.
# NOTE: Need to call sh here since file permissions are not preserved
#       in hex packages.
ifeq ($(shell CC=$(CC) sh src/test-c99.sh),yes)
CFLAGS += -std=c99 -D_XOPEN_SOURCE=600
else
CFLAGS += -std=gnu99
endif

all: install

install: $(BUILD) $(PREFIX) $(DEFAULT_TARGETS)

$(BUILD)/%.o: src/%.c
	@echo " CC $(notdir $@)"
	$(CC) -c $(CFLAGS) -o $@ $<

$(PREFIX)/force_ap_scan: $(BUILD)/force_ap_scan.o
	@echo " LD $(notdir $@)"
	$(CC) $^ $(LDFLAGS) -lnl-3 -lnl-genl-3 -o $@

$(PREFIX)/mesh_mode: $(BUILD)/mesh_mode.o
	@echo " LD $(notdir $@)"
	$(CC) $^ $(LDFLAGS) -lnl-3 -lnl-genl-3 -o $@

$(PREFIX)/mesh_param: $(BUILD)/mesh_param.o
	@echo " LD $(notdir $@)"
	$(CC) $^ $(LDFLAGS) -lnl-3 -lnl-genl-3 -o $@

$(PREFIX) $(BUILD):
	mkdir -p $@

mix_clean:
	$(RM) $(PREFIX)/force_ap_scan \
	    $(PREFIX)/mesh_mode \
	    $(PREFIX)/mesh_param \
	    $(BUILD)/*.o
clean:
	mix clean

format:
	astyle \
	    --style=kr \
	    --indent=spaces=4 \
	    --align-pointer=name \
	    --align-reference=name \
	    --convert-tabs \
	    --attach-namespaces \
	    --max-code-length=100 \
	    --max-instatement-indent=120 \
	    --pad-header \
	    --pad-oper \
	    src/*.c

.PHONY: all clean mix_clean calling_from_make install format

# Don't echo commands unless the caller exports "V=1"
${V}.SILENT:
