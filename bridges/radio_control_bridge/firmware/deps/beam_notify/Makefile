# Makefile for building port binaries
#
# Makefile targets:
#
# all/install   build and install beam_notify
# clean         clean build products and intermediates
#
# Variables to override:
#
# MIX_APP_PATH  path to the build directory
#
# CC            C compiler
# CROSSCOMPILE	crosscompiler prefix, if any
# CFLAGS	compiler flags for compiling all C files
# ERL_CFLAGS	additional compiler flags for files using Erlang header files
# ERL_EI_INCLUDE_DIR include path to ei.h (Required for crosscompile)
# ERL_EI_LIBDIR path to libei.a (Required for crosscompile)
# LDFLAGS	linker flags for linking all binaries
# ERL_LDFLAGS	additional linker flags for projects referencing Erlang libraries
#
ifeq ($(MIX_APP_PATH),)
calling_from_make:
	mix compile
endif

PREFIX = $(MIX_APP_PATH)/priv
BUILD  = $(MIX_APP_PATH)/obj

# Set Erlang-specific compile and linker flags
ERL_CFLAGS ?= -I"$(ERL_EI_INCLUDE_DIR)"
ERL_LDFLAGS = -L"$(ERL_EI_LIBDIR)" -lei_st

CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -pedantic

DEFAULT_TARGETS = $(PREFIX) $(PREFIX)/beam_notify

# Enable for debug messages
# CFLAGS += -DDEBUG

all: install

install: $(BUILD) $(PREFIX) $(DEFAULT_TARGETS)

$(BUILD)/%.o: c_src/%.c
	@echo " CC $(notdir $@)"
	$(CC) -c $(ERL_CFLAGS) $(CFLAGS) -o $@ $<

$(PREFIX)/beam_notify: $(BUILD)/beam_notify.o
	@echo " LD $(notdir $@)"
	$(CC) $^ $(ERL_LDFLAGS) $(LDFLAGS) -o $@

$(PREFIX) $(BUILD):
	mkdir -p $@

mix_clean:
	$(RM) $(PREFIX)/beam_notify \
	    $(BUILD)/*.o
clean:
	mix clean

format:
	astyle \
	    --style=kr \
	    --indent=spaces=4 \
	    --align-pointer=name \
	    --align-reference=name \
	    --convert-tabs \
	    --attach-namespaces \
	    --max-code-length=100 \
	    --max-instatement-indent=120 \
	    --pad-header \
	    --pad-oper \
	    c_src/*.c

.PHONY: all clean mix_clean calling_from_make install format

.SILENT:
