# :elixir_make entry on :rpi5: builds the camera_capture and hailo_detect
# Port binaries into priv/. camera_capture links libcamera from the rpi5
# sysroot; hailo_detect links libhailort from the :hailort dependency.

PRIV_DIR := $(MIX_APP_PATH)/priv
HAILORT_DIR := $(MIX_BUILD_PATH)/lib/hailort

all: $(PRIV_DIR)/camera_capture $(PRIV_DIR)/hailo_detect

$(PRIV_DIR)/camera_capture: $(wildcard c_src/camera_capture/*.cpp c_src/common/*.cpp c_src/common/*.h)
	mkdir -p $(PRIV_DIR)
	$(MAKE) -C c_src/camera_capture OUT=$@

$(PRIV_DIR)/hailo_detect: $(wildcard c_src/hailo_detect/*.cpp c_src/common/*.cpp c_src/common/*.h) $(HAILORT_DIR)/native/lib/libhailort.so
	mkdir -p $(PRIV_DIR)
	$(MAKE) -C c_src/hailo_detect OUT=$@ \
		HAILORT_INCLUDE_DIR=$(HAILORT_DIR)/native/include \
		HAILORT_LINK_DIR=$(HAILORT_DIR)/native/lib

clean:
	$(MAKE) -C c_src/camera_capture clean
	$(MAKE) -C c_src/hailo_detect clean
	rm -f $(PRIV_DIR)/camera_capture $(PRIV_DIR)/hailo_detect

.PHONY: all clean
