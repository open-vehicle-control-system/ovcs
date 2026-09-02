# gles_probe — a throwaway measurement tool, deliberately NOT wired into
# elixir_make or the firmware. It answers "what can the Pi 5 GPU
# actually do with compute shaders?" with numbers from the board.
#
# Cross-compile against the Nerves sysroot, then copy to /data on the
# device (the only writable path) and run it over ssh:
#
#   make SYSROOT=~/.nerves/artifacts/ovcs_bridges_system_rpi5-portable-2.0.8/staging \
#        CROSSCOMPILE=~/.nerves/artifacts/nerves_toolchain_aarch64_nerves_linux_gnu-linux_x86_64-13.2.0/bin/aarch64-nerves-linux-gnu-
#
#   scp gles_probe ovcs-mini-bridge-ros-perception.local:/data/
#   ssh ovcs-mini-bridge-ros-perception.local \
#     'System.cmd("/data/gles_probe", []) |> elem(0) |> IO.puts()'
#
# Args: width height disparities window_radius (defaults 640 480 96 2).

OUT ?= gles_probe

# NOT `CXX ?=` — make has a built-in default for CXX, which counts as
# "already set", so `?=` silently leaves you compiling for the host.
ifneq ($(strip $(CROSSCOMPILE)),)
  CXX := $(CROSSCOMPILE)g++
endif

CXXFLAGS += -std=c++17 -O2 -Wall -Wextra
LDFLAGS  += -lEGL -lGLESv2

# The Buildroot staging tree carries EGL/, GLES3/ and the matching
# stubs. Without it the host headers get picked up and the link fails
# against the wrong ABI.
ifneq ($(strip $(SYSROOT)),)
  CXXFLAGS += --sysroot=$(SYSROOT)
  LDFLAGS  += --sysroot=$(SYSROOT)
endif

$(OUT): main.cpp
	$(CXX) $(CXXFLAGS) -o $@ main.cpp $(LDFLAGS)

clean:
	rm -f $(OUT)

.PHONY: clean
