# Top-level make entry point invoked by :elixir_make on the :rpi5
# target. Builds the native Port binaries into priv/:
#
#   camera_capture — one CSI camera via libcamera, JPEG on stdout
#   hailo_detect   — a YOLO HEF on the Hailo-8, boxes on stdout
#
# Both link libraries that only exist in the rpi5 sysroot, which is
# why mix.exs runs elixir_make on that target alone.

PRIV_DIR := $(MIX_APP_PATH)/priv

all: $(PRIV_DIR)/camera_capture $(PRIV_DIR)/hailo_detect

$(PRIV_DIR)/camera_capture: $(wildcard c_src/camera_capture/*.cpp c_src/common/*.cpp c_src/common/*.h)
	mkdir -p $(PRIV_DIR)
	$(MAKE) -C c_src/camera_capture OUT=$@

$(PRIV_DIR)/hailo_detect: $(wildcard c_src/hailo_detect/*.cpp c_src/common/*.cpp c_src/common/*.h)
	mkdir -p $(PRIV_DIR)
	$(MAKE) -C c_src/hailo_detect OUT=$@

clean:
	$(MAKE) -C c_src/camera_capture clean
	$(MAKE) -C c_src/hailo_detect clean
	rm -f $(PRIV_DIR)/camera_capture $(PRIV_DIR)/hailo_detect

.PHONY: all clean
