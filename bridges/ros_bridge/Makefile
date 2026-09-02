# Top-level make entry point invoked by :elixir_make on the :rpi5
# target. Builds the camera_capture binary into priv/.
#
# Hailo inference is no longer a native Port binary — the
# `nx_hailo` NIF replaces it (see mix.exs deps).

PRIV_DIR := $(MIX_APP_PATH)/priv

all: $(PRIV_DIR)/camera_capture

$(PRIV_DIR)/camera_capture: $(wildcard c_src/camera_capture/*.cpp c_src/camera_capture/*.h)
	mkdir -p $(PRIV_DIR)
	$(MAKE) -C c_src/camera_capture OUT=$@

clean:
	$(MAKE) -C c_src/camera_capture clean
	rm -f $(PRIV_DIR)/camera_capture

.PHONY: all clean
