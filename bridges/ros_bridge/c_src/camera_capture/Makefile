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

# libjpeg-turbo provides the TurboJPEG API (tjCompressFromYUVPlanes)
# we use to encode the YUV420 frames libcamera hands us into JPEG.
# pkg-config name is `libturbojpeg`; the Buildroot package is
# BR2_PACKAGE_JPEG (libjpeg-turbo).
TURBOJPEG_CFLAGS := $(shell $(PKG_CONFIG) --cflags libturbojpeg 2>/dev/null)
TURBOJPEG_LIBS   := $(shell $(PKG_CONFIG) --libs   libturbojpeg 2>/dev/null)
ifeq ($(strip $(TURBOJPEG_LIBS)),)
  TURBOJPEG_LIBS := -lturbojpeg
endif

CXXFLAGS += $(LIBCAMERA_CFLAGS) $(TURBOJPEG_CFLAGS)
LDFLAGS  += $(LIBCAMERA_LIBS) $(TURBOJPEG_LIBS)

SRCS := main.cpp ../common/framing.cpp
OBJS := $(SRCS:.cpp=.o)

$(OUT): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJS) $(LDFLAGS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(OUT)

.PHONY: clean
