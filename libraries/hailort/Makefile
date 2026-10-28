# :elixir_make entry on Nerves targets: builds libhailort from the HailoRT
# source release with the Nerves cross toolchain. protobuf, spdlog and the
# other externals HailoRT uses are linked statically into it.

HAILORT_VERSION := 4.24.0
HAILORT_SHA256 := af399b64e59453cb71a6054e71b98e2cb06147701219531ecf780c4584c6ef70
HAILORT_URLS := https://github.com/hailo-ai/hailort/archive/refs/tags/v$(HAILORT_VERSION).tar.gz

# HailoRT's CMake clones these at configure time. They are downloaded here
# instead, at the commits hailort/cmake/external/*.cmake pins, and CMake
# runs disconnected. A HailoRT bump means re-pinning them.
EXTERNALS := protobuf spdlog readerwriterqueue xxhash eigen cli11 json dotwriter

protobuf_URLS := https://github.com/protocolbuffers/protobuf/archive/f0dc78d7e6e331b8c6bb2d5283e06aa26883ca7c.tar.gz
protobuf_SHA256 := d594b561fb41bf243233d8f411c7f2b7d913e5c9c1be4ca439baf7e48384c893
spdlog_URLS := https://github.com/gabime/spdlog/archive/27cb4c76708608465c413f6d0e6b8d99a4d84302.tar.gz
spdlog_SHA256 := 7d512b37019b61646cd6fd1e48f52a3cf3e098f36b33ba9c059fe51301ff40b3
readerwriterqueue_URLS := https://github.com/cameron314/readerwriterqueue/archive/435e36540e306cac40fcfeab8cc0a22d48464509.tar.gz
readerwriterqueue_SHA256 := 0a15f844f129ac585d751534e4eb1498fcbb890ed9cd08f5041573495b46a4b1
xxhash_URLS := https://github.com/Cyan4973/xxHash/archive/bbb27a5efb85b92a0486cf361a8635715a53f6ba.tar.gz
xxhash_SHA256 := 716fbe4fc85ecd36488afbbc635b59b5ab6aba5ed3b69d4a32a46eae5a453d38
# Eigen's 3.4.0 release tarball; Debian's copy is byte-identical.
eigen_URLS := https://gitlab.com/libeigen/eigen/-/archive/3.4.0/eigen-3.4.0.tar.bz2 \
	https://deb.debian.org/debian/pool/main/e/eigen3/eigen3_3.4.0.orig.tar.bz2
eigen_SHA256 := b4c198460eba6f28d34894e3a5710998818515104d6e74e5cc331ce31e46e626
cli11_URLS := https://github.com/hailo-ai/CLI11/archive/ae78ac41cf225706e83f57da45117e3e90d4a5b4.tar.gz
cli11_SHA256 := 12e815f9fa9fd21c9743af2280a5b77d20713ea36095da0e76f12a32f02bf92b
json_URLS := https://github.com/ArthurSonzogni/nlohmann_json_cmake_fetchcontent/archive/391786c6c3abdd3eeb993a3154f1f2a4cfe137a0.tar.gz
json_SHA256 := 614ffcc9812aa2d2cbe0d602e258c2fe7d06eddd68dec0c51039f3f210a33ac6
dotwriter_URLS := https://github.com/hailo-ai/DotWriter/archive/e5fa8f281adca10dd342b1d32e981499b8681daf.tar.gz
dotwriter_SHA256 := 911e1eeb20485d3563d54215ec8cc9ac5e529a1773adbdbf5aed3d7dfd1f8052

DOWNLOAD_DIR ?= $(or $(NERVES_DL_DIR),$(HOME)/.nerves/dl)

NATIVE_DIR := $(MIX_APP_PATH)/native
SOURCE_DIR := $(NATIVE_DIR)/hailort-$(HAILORT_VERSION)
EXTERNAL_DIR := $(SOURCE_DIR)/hailort/external
BUILD_DIR := $(NATIVE_DIR)/build
INCLUDE_DIR := $(NATIVE_DIR)/include
LINK_DIR := $(NATIVE_DIR)/lib
LIB_DIR := $(MIX_APP_PATH)/priv/lib
LIBRARY := $(LIB_DIR)/libhailort.so.$(HAILORT_VERSION)

HAILORT_ARCHIVE := $(DOWNLOAD_DIR)/hailort-$(HAILORT_SHA256)
archive = $(DOWNLOAD_DIR)/hailort-$(1)-$($(1)_SHA256)
extracted = $(EXTERNAL_DIR)/$(1)-src/.extracted

# A failed CMake configure leaves a CMakeCache.txt behind.
.DELETE_ON_ERROR:

all: check-environment $(LIBRARY) $(LINK_DIR)/libhailort.so $(INCLUDE_DIR)/hailo/hailort.h

check-environment:
	@test -n "$(NERVES_SDK_SYSROOT)" || { echo "hailort: NERVES_SDK_SYSROOT is not set; libhailort is built only for Nerves targets" >&2; exit 1; }
	@command -v cmake >/dev/null || { echo "hailort: cmake is required" >&2; exit 1; }
	@command -v curl >/dev/null || { echo "hailort: curl is required" >&2; exit 1; }

# $(call download,urls,sha256): fetches $@ from the first URL that answers.
download = mkdir -p $(DOWNLOAD_DIR) && downloaded= && \
	for url in $(1); do curl -fsSL --retry 3 -o $@.part "$$url" && { downloaded=1; break; }; done; \
	test -n "$$downloaded" || { echo "hailort: could not download $(notdir $@) from: $(1)" >&2; rm -f $@.part; exit 1; }; \
	echo "$(2)  $@.part" | sha256sum -c --quiet - || { echo "hailort: checksum mismatch for $(notdir $@)" >&2; rm -f $@.part; exit 1; }; \
	mv $@.part $@

$(HAILORT_ARCHIVE):
	$(call download,$(HAILORT_URLS),$(HAILORT_SHA256))

$(SOURCE_DIR)/.extracted: $(HAILORT_ARCHIVE)
	rm -rf $(SOURCE_DIR)
	mkdir -p $(SOURCE_DIR)
	tar -xf $< -C $(SOURCE_DIR) --strip-components=1
	touch $@

define external_rules
$(call archive,$(1)):
	$$(call download,$$($(1)_URLS),$$($(1)_SHA256))

$(call extracted,$(1)): $(call archive,$(1)) $(SOURCE_DIR)/.extracted
	rm -rf $(EXTERNAL_DIR)/$(1)-src
	mkdir -p $(EXTERNAL_DIR)/$(1)-src
	tar -xf $$< -C $(EXTERNAL_DIR)/$(1)-src --strip-components=1
	touch $$@
endef

$(foreach external,$(EXTERNALS),$(eval $(call external_rules,$(external))))

# The host protoc HailoRT needs is built by its protobuf.cmake in a clean
# environment, so it gets the host compiler, not the cross one below.
$(BUILD_DIR)/CMakeCache.txt: $(foreach external,$(EXTERNALS),$(call extracted,$(external)))
	cmake -S $(SOURCE_DIR) -B $(BUILD_DIR) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		-DCMAKE_SYSTEM_NAME=Linux \
		-DCMAKE_SYSTEM_PROCESSOR=$(firstword $(subst -, ,$(shell $(CC) -dumpmachine))) \
		-DCMAKE_SYSROOT=$(NERVES_SDK_SYSROOT) \
		-DCMAKE_C_COMPILER=$(CC) \
		-DCMAKE_CXX_COMPILER=$(CXX) \
		-DCMAKE_FIND_ROOT_PATH=$(NERVES_SDK_SYSROOT) \
		-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
		-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
		-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
		-DFETCHCONTENT_FULLY_DISCONNECTED=ON \
		-DBUILD_SHARED_LIBS=OFF \
		-DHAILO_BUILD_SERVICE=OFF \
		-DHAILO_BUILD_GSTREAMER=OFF \
		-DHAILO_BUILD_EXAMPLES=OFF \
		-DHAILO_BUILD_UT=OFF \
		-DHAILO_BUILD_PYHAILORT_INTERNAL=OFF

$(LIBRARY): $(BUILD_DIR)/CMakeCache.txt
	cmake --build $(BUILD_DIR) --target libhailort --parallel $(shell nproc)
	mkdir -p $(LIB_DIR)
	cp $(BUILD_DIR)/hailort/libhailort/src/libhailort.so.$(HAILORT_VERSION) $@
	$(STRIP) --strip-unneeded $@

# Outside priv: a release copies a symlink as a second copy of its target.
$(LINK_DIR)/libhailort.so: $(LIBRARY)
	mkdir -p $(LINK_DIR)
	ln -sf $< $@

$(INCLUDE_DIR)/hailo/hailort.h: $(SOURCE_DIR)/.extracted
	rm -rf $(INCLUDE_DIR)
	mkdir -p $(INCLUDE_DIR)
	cp -r $(SOURCE_DIR)/hailort/libhailort/include/hailo $(INCLUDE_DIR)/

clean:
	rm -rf $(NATIVE_DIR) $(LIB_DIR)

.PHONY: all check-environment clean
