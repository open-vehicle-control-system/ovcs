# gles_probe: a GPU compute benchmark, not part of the firmware. Build with
# `make SYSROOT=<nerves system>/staging CROSSCOMPILE=<toolchain>/bin/aarch64-nerves-linux-gnu-`,
# copy it to /data on <device> and run it there. Args: width height disparities window_radius.

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
