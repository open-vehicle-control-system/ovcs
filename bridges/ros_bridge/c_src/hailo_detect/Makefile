# hailo_detect: a YOLO HEF on the Hailo-8, boxes on stdout. The top-level
# Makefile sets OUT, HAILORT_INCLUDE_DIR and HAILORT_LINK_DIR.

OUT ?= hailo_detect

CXX ?= $(CROSSCOMPILE)g++

CXXFLAGS += -std=c++17 -O2 -Wall -Wextra -Wpedantic -I../common -I$(HAILORT_INCLUDE_DIR)

LDFLAGS += -L$(HAILORT_LINK_DIR) -lhailort

SRCS := main.cpp ../common/framing.cpp
OBJS := $(SRCS:.cpp=.o)

$(OUT): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJS) $(LDFLAGS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(OUT)

.PHONY: clean
