# :elixir_make entry on :rpi5: builds the camera_capture and hailo_detect
# Port binaries into priv/. Both link libraries only the rpi5 sysroot has.

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
