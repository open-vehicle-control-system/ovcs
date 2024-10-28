# Based on c_src.mk from erlang.mk by Loic Hoguin <essen@ninenines.eu>

CURDIR := $(shell pwd)
BASEDIR := $(abspath $(CURDIR)/..)

ifneq ($(MIX_APP_PATH),)
PREFIX = $(MIX_APP_PATH)/priv
BUILD  = $(MIX_APP_PATH)/obj
else
PREFIX = $(BASEDIR)/priv
BUILD  = $(CURDIR)/obj
endif

PROJECT = crc

# Configuration.

C_SRC_DIR ?= $(CURDIR)
C_SRC_ENV ?= $(C_SRC_DIR)/env.mk
C_SRC_NIF ?= $(PREFIX)/$(PROJECT)_nif

# "erl" command.

ERL = erl +A0 -noinput -boot start_clean

# Platform detection.

ifeq ($(PLATFORM),)
UNAME_S := $(shell uname -s)
ARCH := $(shell uname -m)

ifeq ($(UNAME_S),Linux)
PLATFORM = linux
else ifeq ($(UNAME_S),Darwin)
PLATFORM = darwin
else ifeq ($(UNAME_S),SunOS)
PLATFORM = solaris
else ifeq ($(UNAME_S),GNU)
PLATFORM = gnu
else ifeq ($(UNAME_S),FreeBSD)
PLATFORM = freebsd
else ifeq ($(UNAME_S),NetBSD)
PLATFORM = netbsd
else ifeq ($(UNAME_S),OpenBSD)
PLATFORM = openbsd
else ifeq ($(UNAME_S),DragonFly)
PLATFORM = dragonfly
else ifeq ($(shell uname -o),Msys)
PLATFORM = msys2
else
$(error Unable to detect platform. Please open a ticket with the output of uname -a.)
endif

export PLATFORM
endif

# System type and C compiler/flags.

ifeq ($(PLATFORM),msys2)
	C_SRC_EXECUTABLE_EXTENSION ?= .exe
	C_SRC_SHARED_EXTENSION ?= .dll
else
	C_SRC_EXECUTABLE_EXTENSION ?=
	C_SRC_SHARED_EXTENSION ?= .so
endif

C_SRC_NIF_FILE = $(C_SRC_NIF)$(C_SRC_SHARED_EXTENSION)

ifeq ($(PLATFORM),msys2)
# We hardcode the compiler used on MSYS2. The default CC=cc does
# not produce working code. The "gcc" MSYS2 package also doesn't.
	CC = /mingw64/bin/gcc
	CFLAGS ?= -O3 -std=c11 -finline-functions -fstack-protector -Wall -Wmissing-prototypes
	CXXFLAGS ?= -O3 -std=c++11 -finline-functions -fstack-protector -Wall
else ifeq ($(PLATFORM),darwin)
	CC ?= cc
	CFLAGS += -O3 -std=c11 -arch $(ARCH) -fstack-protector -Wall -Wmissing-prototypes
	CXXFLAGS += -O3 -std=c++11 -arch $(ARCH) -fstack-protector -Wall
	LDFLAGS += -arch $(ARCH) -flat_namespace -undefined suppress
else ifeq ($(PLATFORM),freebsd)
	CC ?= cc
	CFLAGS += -O3 -std=c11 -finline-functions -fstack-protector -Wall -Wmissing-prototypes
	CXXFLAGS += -O3 -std=c++11 -finline-functions -fstack-protector -Wall
else ifeq ($(PLATFORM),linux)
	CC ?= gcc
	CFLAGS += -O3 -std=c11 -finline-functions -fstack-protector -Wall -Wmissing-prototypes -D_POSIX_C_SOURCE=200809L
	CXXFLAGS += -O3 -std=c++11 -finline-functions -fstack-protector -Wall
else ifeq ($(PLATFORM),solaris)
	CC ?= cc
	CFLAGS += -O3 -std=c11 -finline-functions -fstack-protector -Wall -Wmissing-prototypes -fPIC
	CXXFLAGS += -O3 -std=c++11 -finline-functions -fstack-protector -Wall -fPIC
	LDLIBS += -latomic
endif

ifneq ($(PLATFORM),msys2)
	CFLAGS += -fPIC
	CXXFLAGS += -fPIC
endif

ifneq ($(CROSSCOMPILER),)
	CC = $(CROSSCOMPILER)gcc
endif

CFLAGS += -I"$(ERTS_INCLUDE_DIR)"
CXXFLAGS += -I"$(ERTS_INCLUDE_DIR)"

# Verbosity.

V ?= 0

verbose_0 = @
verbose_2 = set -x;
verbose = $(verbose_$(V))

c_verbose_0 = @echo " C     " $(?F);
c_verbose = $(c_verbose_$(V))

cpp_verbose_0 = @echo " CPP   " $(?F);
cpp_verbose = $(cpp_verbose_$(V))

dep_verbose_0 = @echo " DEP   " $(1);
dep_verbose_2 = set -x;
dep_verbose = $(dep_verbose_$(V))

gen_verbose_0 = @echo " GEN   " $@;
gen_verbose_2 = set -x;
gen_verbose = $(gen_verbose_$(V))

link_verbose_0 = @echo " LD    " $(@F);
link_verbose = $(link_verbose_$(V))

# Targets.

core_find = $(if $(wildcard $1),$(shell find $(1:%/=%) -type f -name $(subst *,\*,$2)))

ifeq ($(PLATFORM),msys2)
core_native_path = $(subst \,\\\\,$(shell cygpath -w $1))
else
core_native_path = $1
endif

ifeq ($(NIF_SOURCES),)
NIF_SOURCES := $(sort $(foreach pat,*.c *.C *.cc *.cpp,$(call core_find,$(C_SRC_DIR)/nif/,$(pat))))
endif
NIF_OBJECTS_BASE = $(addsuffix .o, $(basename $(NIF_SOURCES)))
NIF_OBJECTS = $(NIF_OBJECTS_BASE:$(C_SRC_DIR)/nif/%=$(BUILD)/%)

COMPILE_C = $(c_verbose) $(CC) $(CFLAGS) $(CPPFLAGS) -c
COMPILE_CPP = $(cpp_verbose) $(CXX) $(CXXFLAGS) $(CPPFLAGS) -c

all:: app

app:: $(C_SRC_ENV) $(C_SRC_NIF_FILE)

test-build:: $(C_SRC_ENV) $(C_SRC_NIF_FILE)

$(C_SRC_NIF_FILE): $(PREFIX) $(BUILD) $(NIF_OBJECTS)
	$(link_verbose) $(CC) $(NIF_OBJECTS) \
		$(LDFLAGS) -shared $(LDLIBS) \
		-o $(C_SRC_NIF_FILE)

$(BUILD)/%.o: $(C_SRC_DIR)/nif/%.c
	$(COMPILE_C) $(OUTPUT_OPTION) $<

$(BUILD)/%.o: $(C_SRC_DIR)/nif/%.cc
	$(COMPILE_CPP) $(OUTPUT_OPTION) $<

$(BUILD)/%.o: $(C_SRC_DIR)/nif/%.C
	$(COMPILE_CPP) $(OUTPUT_OPTION) $<

$(BUILD)/%.o: $(C_SRC_DIR)/nif/%.cpp
	$(COMPILE_CPP) $(OUTPUT_OPTION) $<

$(PREFIX) $(BUILD):
	$(verbose) mkdir -p $@

clean:: clean-c_src

clean-c_src:
	$(gen_verbose) rm -f $(C_SRC_NIF_FILE) $(NIF_OBJECTS) $(C_SRC_ENV)

$(C_SRC_ENV):
	$(verbose) $(ERL) -eval "file:write_file(\"$(call core_native_path,$(C_SRC_ENV))\", \
		io_lib:format( \
			\"ERTS_INCLUDE_DIR ?= ~s/erts-~s/include/~n\", \
			[code:root_dir(), erlang:system_info(version)])), \
		halt()."

distclean:: distclean-env

distclean-env:
	$(gen_verbose) rm -f $(C_SRC_ENV)

clang-format-all:
	$(gen_verbose) clang-format -i nif/*.c nif/*.h nif/*.c.h

-include $(C_SRC_ENV)
