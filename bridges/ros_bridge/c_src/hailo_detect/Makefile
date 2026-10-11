# hailo_detect: a YOLO HEF on the Hailo-8, boxes on stdout. The top-level
# Makefile sets OUT.

OUT ?= hailo_detect

CXX ?= $(CROSSCOMPILE)g++

CXXFLAGS += -std=c++17 -O2 -Wall -Wextra -Wpedantic -I../common

# libhailort has no pkg-config file. --allow-shlib-undefined: its
# libprotobuf-lite dependency is on the device but not in the staging tree,
# so those symbols bind at runtime.
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
