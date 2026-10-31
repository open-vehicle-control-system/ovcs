# :elixir_make entry on a vision target: cross-builds the Port binaries
# (vision/rust) into priv/. On :rpi5, camera_capture links libcamera from
# its sysroot, hailo_detect links libhailort from the :hailort dependency,
# and everything is tuned for the Cortex-A76; on :okdo_c100, v4l2_capture
# needs only libc; jpeg_codec, on both, and stereo_match, on :rpi5, are
# pure Rust. The toolchain and sysroot come from the env
# Nerves exports for a target compile (CC, CXX, AR, CFLAGS, CXXFLAGS,
# NERVES_SDK_SYSROOT, NERVES_TOOLCHAIN, PKG_CONFIG_LIBDIR, TARGET_*).

PRIV_DIR := $(MIX_APP_PATH)/priv
RUST_DIR := $(CURDIR)/../rust
HAILORT_DIR := $(MIX_BUILD_PATH)/lib/hailort
ifeq ($(MIX_TARGET),okdo_c100)
BINARIES := v4l2_capture jpeg_codec
FEATURES :=
TARGET_CPU_FLAGS :=
else
BINARIES := camera_capture hailo_detect jpeg_codec stereo_match
FEATURES := --features device
TARGET_CPU_FLAGS := -C target-cpu=cortex-a76
endif
CARGO ?= cargo

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
	PKG_CONFIG_ALLOW_CROSS=1 \
	PKG_CONFIG_SYSROOT_DIR_$(RUST_TARGET_ENV)="$(SYSROOT)" \
	PKG_CONFIG_PATH_$(RUST_TARGET_ENV)= \
	PKG_CONFIG_LIBDIR_$(RUST_TARGET_ENV)="$(PKG_CONFIG_LIBDIR):$(SYSROOT)/usr/share/pkgconfig" \
	BINDGEN_EXTRA_CLANG_ARGS_$(RUST_TARGET_ENV)="$(BINDGEN_ARGS)" \
	CARGO_TARGET_$(RUST_TARGET_ENV_UPPER)_LINKER="$(CC)" \
	CARGO_TARGET_$(RUST_TARGET_ENV_UPPER)_RUSTFLAGS="-C link-arg=--sysroot=$(SYSROOT) $(TARGET_CPU_FLAGS)"

ifeq ($(MIX_TARGET),host)
# A workstation run builds jpeg_codec natively, for JPEG camera frames, and
# stereo_match, for a pipeline matching on the CPU.
HOST_BINARIES := jpeg_codec stereo_match
all:
	cd $(RUST_DIR) && $(CARGO) build --release --locked $(addprefix -p ,$(HOST_BINARIES))
	mkdir -p $(PRIV_DIR)
	for binary in $(HOST_BINARIES); do install -m 755 $(RUST_DIR)/target/release/$$binary $(PRIV_DIR)/$$binary; done
else
all: cargo
	mkdir -p $(PRIV_DIR)
	for binary in $(BINARIES); do install -m 755 $(RUST_OUT)/$$binary $(PRIV_DIR)/$$binary; done
endif

# Phony: cargo decides what is stale.
cargo:
	@test -n "$(SYSROOT)" || { echo "NERVES_SDK_SYSROOT is unset: compile through vision/firmware with MIX_TARGET=rpi5 or okdo_c100" >&2; exit 1; }
	@test -d "$(CXX_INCLUDE)" || { echo "no C++ headers at $(CXX_INCLUDE)" >&2; exit 1; }
	cd $(RUST_DIR) && $(CARGO_ENV) $(CARGO) build --release --locked $(FEATURES) \
		--target $(RUST_TARGET) $(addprefix -p ,$(BINARIES))

clean:
	rm -f $(addprefix $(PRIV_DIR)/,$(BINARIES) $(HOST_BINARIES))

.PHONY: all cargo clean
