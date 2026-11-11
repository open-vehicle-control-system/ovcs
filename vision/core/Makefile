# Builds the Port binaries (vision/rust) into priv/; vision_core's README lists them per target.
# A target's toolchain and sysroot come from the env Nerves exports for its compile.

PRIV_DIR := $(MIX_APP_PATH)/priv
RUST_DIR := $(CURDIR)/../rust
HAILORT_DIR := $(MIX_BUILD_PATH)/lib/hailort
ifeq ($(MIX_TARGET),okdo_c100)
BINARIES := v4l2_capture jpeg_codec
FEATURES :=
TARGET_CPU_FLAGS :=
else ifeq ($(MIX_TARGET),arduino_ventuno_q)
BINARIES := v4l2_capture jpeg_codec qnn_detect qnn_segment
FEATURES :=
TARGET_CPU_FLAGS := -C target-cpu=cortex-a78
# The qnn crate's bindings come from the QNN headers of the QAIRT archive the
# firmware's overlay is fetched from (`mise run fetch-qairt`); none is committed.
QAIRT_VERSION := 2.50.0.260828
QAIRT_ZIP ?= $(HOME)/.cache/nerves_system_arduino_ventuno_q/qairt-$(QAIRT_VERSION).zip
QAIRT_INCLUDE := $(MIX_BUILD_PATH)/qairt_include
QAIRT_HEADERS := $(QAIRT_INCLUDE)/qairt/$(QAIRT_VERSION)/include/QNN
else
BINARIES := camera_capture hailo_detect jpeg_codec
FEATURES := --features device
TARGET_CPU_FLAGS := -C target-cpu=cortex-a76
endif
CARGO ?= cargo
# Every Port binary: priv/ is shared by the host and every target, so a
# target build removes the ones it does not build.
ALL_BINARIES := camera_capture hailo_detect jpeg_codec qnn_detect qnn_segment v4l2_capture

SYSROOT := $(NERVES_SDK_SYSROOT)
RUST_TARGET := $(TARGET_ARCH)-unknown-$(TARGET_OS)-$(TARGET_ABI)
RUST_TARGET_ENV := $(subst -,_,$(RUST_TARGET))
RUST_TARGET_ENV_UPPER := $(shell echo $(RUST_TARGET_ENV) | tr a-z A-Z)
RUST_OUT := $(RUST_DIR)/target/$(RUST_TARGET)/release

# bindgen's clang (libcamera-sys, hailo_detect) needs the cross g++
# headers, which it does not find on its own.
GCC_TRIPLE := $(shell $(CC) -dumpmachine)
GCC_VERSION := $(shell $(CC) -dumpfullversion)
CXX_INCLUDE := $(NERVES_TOOLCHAIN)/$(GCC_TRIPLE)/include/c++/$(GCC_VERSION)
BINDGEN_ARGS := --target=$(RUST_TARGET) --sysroot=$(SYSROOT) \
	-isystem $(CXX_INCLUDE) -isystem $(CXX_INCLUDE)/$(GCC_TRIPLE) \
	-isystem $(CXX_INCLUDE)/backward \
	-isystem $(NERVES_TOOLCHAIN)/lib/gcc/$(GCC_TRIPLE)/$(GCC_VERSION)/include \
	-isystem $(SYSROOT)/usr/include

# The Nerves CC, CFLAGS and PKG_CONFIG_* would also apply to the host
# build scripts, so they are passed only under target-scoped names.
# `--sysroot` at link time lets ld resolve libcamera's own dependencies.
CARGO_ENV := env -u CC -u CXX -u AR -u CFLAGS -u CXXFLAGS -u LDFLAGS \
	-u PKG_CONFIG_SYSROOT_DIR -u PKG_CONFIG_LIBDIR \
	CC_$(RUST_TARGET_ENV)="$(CC)" \
	CXX_$(RUST_TARGET_ENV)="$(CXX)" \
	AR_$(RUST_TARGET_ENV)="$(AR)" \
	CFLAGS_$(RUST_TARGET_ENV)="$(CFLAGS)" \
	CXXFLAGS_$(RUST_TARGET_ENV)="$(CXXFLAGS)" \
	HAILORT_INCLUDE_DIR="$(HAILORT_DIR)/native/include" \
	HAILORT_LINK_DIR="$(HAILORT_DIR)/native/lib" \
	QAIRT_INCLUDE_DIR="$(QAIRT_HEADERS)" \
	PKG_CONFIG_ALLOW_CROSS=1 \
	PKG_CONFIG_SYSROOT_DIR_$(RUST_TARGET_ENV)="$(SYSROOT)" \
	PKG_CONFIG_PATH_$(RUST_TARGET_ENV)= \
	PKG_CONFIG_LIBDIR_$(RUST_TARGET_ENV)="$(PKG_CONFIG_LIBDIR):$(SYSROOT)/usr/share/pkgconfig" \
	BINDGEN_EXTRA_CLANG_ARGS_$(RUST_TARGET_ENV)="$(BINDGEN_ARGS)" \
	CARGO_TARGET_$(RUST_TARGET_ENV_UPPER)_LINKER="$(CC)" \
	CARGO_TARGET_$(RUST_TARGET_ENV_UPPER)_RUSTFLAGS="-C link-arg=--sysroot=$(SYSROOT) $(TARGET_CPU_FLAGS)"

ifeq ($(MIX_TARGET),host)
# A workstation run builds jpeg_codec natively, for JPEG camera frames.
HOST_BINARIES := jpeg_codec
all:
	cd $(RUST_DIR) && $(CARGO) build --release --locked $(addprefix -p ,$(HOST_BINARIES))
	mkdir -p $(PRIV_DIR)
	for binary in $(HOST_BINARIES); do install -m 755 $(RUST_DIR)/target/release/$$binary $(PRIV_DIR)/$$binary; done
else
all: cargo
	mkdir -p $(PRIV_DIR)
	rm -f $(addprefix $(PRIV_DIR)/,$(filter-out $(BINARIES),$(ALL_BINARIES)))
	for binary in $(BINARIES); do install -m 755 $(RUST_OUT)/$$binary $(PRIV_DIR)/$$binary; done
endif

ifneq ($(QAIRT_HEADERS),)
cargo: $(QAIRT_HEADERS)/QnnInterface.h

$(QAIRT_HEADERS)/QnnInterface.h:
	@test -f "$(QAIRT_ZIP)" || { echo "no QAIRT archive at $(QAIRT_ZIP): run mise run fetch-qairt" >&2; exit 1; }
	mkdir -p $(QAIRT_INCLUDE)
	unzip -q -o $(QAIRT_ZIP) 'qairt/$(QAIRT_VERSION)/include/QNN/*' -d $(QAIRT_INCLUDE)
	touch $@
endif

# Phony: cargo decides what is stale.
cargo:
	@test -n "$(SYSROOT)" || { echo "NERVES_SDK_SYSROOT is unset: compile through vision/firmware with MIX_TARGET=rpi5, okdo_c100 or arduino_ventuno_q" >&2; exit 1; }
	@test -d "$(CXX_INCLUDE)" || { echo "no C++ headers at $(CXX_INCLUDE)" >&2; exit 1; }
	cd $(RUST_DIR) && $(CARGO_ENV) $(CARGO) build --release --locked $(FEATURES) \
		--target $(RUST_TARGET) $(addprefix -p ,$(BINARIES))

clean:
	rm -f $(addprefix $(PRIV_DIR)/,$(BINARIES) $(HOST_BINARIES))

.PHONY: all cargo clean
