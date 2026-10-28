# :elixir_make entry on :rpi5: cross-builds the camera_capture and
# hailo_detect Port binaries (vision/rust) into priv/. camera_capture links
# libcamera from the rpi5 sysroot; hailo_detect links libhailort from the
# :hailort dependency. The toolchain and sysroot come from the env
# Nerves exports for a target compile (CC, CXX, AR, CFLAGS, CXXFLAGS,
# NERVES_SDK_SYSROOT, NERVES_TOOLCHAIN, PKG_CONFIG_LIBDIR, TARGET_*).

PRIV_DIR := $(MIX_APP_PATH)/priv
RUST_DIR := $(CURDIR)/../rust
HAILORT_DIR := $(MIX_BUILD_PATH)/lib/hailort
BINARIES := camera_capture hailo_detect
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
	CARGO_TARGET_$(RUST_TARGET_ENV_UPPER)_RUSTFLAGS="-C link-arg=--sysroot=$(SYSROOT)"

all: cargo
	mkdir -p $(PRIV_DIR)
	for binary in $(BINARIES); do install -m 755 $(RUST_OUT)/$$binary $(PRIV_DIR)/$$binary; done

# Phony: cargo decides what is stale.
cargo:
	@test -n "$(SYSROOT)" || { echo "NERVES_SDK_SYSROOT is unset: compile through vision/firmware with MIX_TARGET=rpi5" >&2; exit 1; }
	@test -d "$(CXX_INCLUDE)" || { echo "no C++ headers at $(CXX_INCLUDE)" >&2; exit 1; }
	cd $(RUST_DIR) && $(CARGO_ENV) $(CARGO) build --release --locked --features device \
		--target $(RUST_TARGET) $(addprefix -p ,$(BINARIES))

clean:
	rm -f $(addprefix $(PRIV_DIR)/,$(BINARIES))

.PHONY: all cargo clean
