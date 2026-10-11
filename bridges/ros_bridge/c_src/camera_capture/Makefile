# camera_capture: one CSI camera via libcamera, JPEG (libjpeg-turbo) FRAME
# records on stdout. The top-level Makefile sets OUT.

OUT ?= camera_capture

CXX ?= $(CROSSCOMPILE)g++
PKG_CONFIG ?= pkg-config

CXXFLAGS += -std=c++17 -O2 -Wall -Wextra -Wpedantic -I../common
LDFLAGS  +=

# libcamera from the Buildroot sysroot (BR2_PACKAGE_RPI_LIBCAMERA_V4L2);
# no fallback when pkg-config cannot find it.
LIBCAMERA_CFLAGS := $(shell $(PKG_CONFIG) --cflags libcamera 2>/dev/null)
LIBCAMERA_LIBS   := $(shell $(PKG_CONFIG) --libs   libcamera 2>/dev/null)

# libjpeg-turbo's TurboJPEG API (BR2_PACKAGE_JPEG); -lturbojpeg when
# pkg-config cannot find it.
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
