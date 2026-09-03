# hailo_detect: runs a YOLO HEF on the Hailo-8 and returns boxes in
# the caller's pixel coordinates. See main.cpp.
#
# OUT is set by the top-level Makefile (PRIV_DIR/hailo_detect).

OUT ?= hailo_detect

CXX ?= $(CROSSCOMPILE)g++

CXXFLAGS += -std=c++17 -O2 -Wall -Wextra -Wpedantic -I../common

# libhailort ships in the ovcs_bridges_system_rpi5 sysroot
# (headers under usr/include/hailo). There is no pkg-config file for
# it, so the flags are spelled out.
#
# --allow-shlib-undefined: libhailort pulls in libprotobuf-lite.so.32,
# which is present on the device but absent from the Buildroot
# staging tree. Without this the link fails on protobuf symbols we
# neither call nor need to resolve here — they bind at runtime, where
# the library does exist.
LDFLAGS += -lhailort -Wl,--allow-shlib-undefined

SRCS := main.cpp ../common/framing.cpp
OBJS := $(SRCS:.cpp=.o)

$(OUT): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJS) $(LDFLAGS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(OUT)

.PHONY: clean
