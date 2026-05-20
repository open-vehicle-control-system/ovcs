# camera_capture: opens one CSI camera via libcamera at the
# requested resolution/fps, encodes JPEG via the Pi 5 ISP path,
# and writes FRAME records on stdout. See main.cpp.
#
# OUT is set by the top-level Makefile (PRIV_DIR/camera_capture).

OUT ?= camera_capture

CXX ?= $(CROSSCOMPILE)g++
PKG_CONFIG ?= pkg-config

CXXFLAGS += -std=c++17 -O2 -Wall -Wextra -Wpedantic -I../common
LDFLAGS  +=

# libcamera is available in the upstream nerves_system_rpi5 image
# (BR2_PACKAGE_RPI_LIBCAMERA_V4L2). The pkg-config name is
# `libcamera`. If pkg-config isn't available at build time we fall
# back to a documented flag set; either way the user must have the
# libcamera package in the Buildroot sysroot.
LIBCAMERA_CFLAGS := $(shell $(PKG_CONFIG) --cflags libcamera 2>/dev/null)
LIBCAMERA_LIBS   := $(shell $(PKG_CONFIG) --libs   libcamera 2>/dev/null)

CXXFLAGS += $(LIBCAMERA_CFLAGS)
LDFLAGS  += $(LIBCAMERA_LIBS)

SRCS := main.cpp ../common/framing.cpp
OBJS := $(SRCS:.cpp=.o)

$(OUT): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJS) $(LDFLAGS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(OUT)

.PHONY: clean
