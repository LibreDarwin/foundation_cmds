# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
# Clean-room reimplementation of Apple's foundation_cmds: pl, plutil and
# defaults.
#
# Build layout: every artifact lives under build/; final tools go to
# build/release/ or build/debug/ per CONFIG.
#
# Portable to both GNU make and BSD make (bmake): no pattern rules, no
# ifeq/ifdef/.if conditionals and no $(if)/$(shell) functions.  Per-config
# flags come from make/<CONFIG>.mk so both make variants behave identically.

CONFIG ?= release
SDK    ?= /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
CC     := /Users/sunneva/xnuports-root/devel/xcode-tools/build/release/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang

-include make/$(CONFIG).mk

BUILD_DIR := build/$(CONFIG)
OBJDIR    := $(BUILD_DIR)/obj

MFLAGS := $(OPT) -fobjc-exceptions -isysroot "$(SDK)" -Wall -Wextra \
	  -Wno-deprecated-declarations
LFLAGS := -framework Foundation -framework CoreFoundation -lobjc

PL      := $(BUILD_DIR)/pl
PL_OBJS := $(OBJDIR)/pl.o

PLUTIL      := $(BUILD_DIR)/plutil
PLUTIL_OBJS := $(OBJDIR)/plutil.o

DEFAULTS      := $(BUILD_DIR)/defaults
DEFAULTS_OBJS := $(OBJDIR)/defaults.o

all: $(PL) $(PLUTIL) $(DEFAULTS)

$(PL): $(PL_OBJS)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(MFLAGS) -o $@ $(PL_OBJS) $(LFLAGS)

$(OBJDIR)/pl.o: src/pl/pl.m
	@mkdir -p $(OBJDIR)
	$(CC) $(MFLAGS) -c -o $@ src/pl/pl.m

$(PLUTIL): $(PLUTIL_OBJS)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(MFLAGS) -o $@ $(PLUTIL_OBJS) $(LFLAGS)

$(OBJDIR)/plutil.o: src/plutil/plutil.m
	@mkdir -p $(OBJDIR)
	$(CC) $(MFLAGS) -c -o $@ src/plutil/plutil.m

$(DEFAULTS): $(DEFAULTS_OBJS)
	@mkdir -p $(BUILD_DIR)
	$(CC) $(MFLAGS) -o $@ $(DEFAULTS_OBJS) $(LFLAGS)

$(OBJDIR)/defaults.o: src/defaults/defaults.m
	@mkdir -p $(OBJDIR)
	$(CC) $(MFLAGS) -c -o $@ src/defaults/defaults.m

test: all
	@for t in pl plutil defaults; do \
		python3 tools/conformance/run_tests.py $$t --build-dir $(BUILD_DIR) || exit 1; \
	done

install: all
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/share/man/man1
	install -m 0755 $(PL) $(DESTDIR)$(PREFIX)/bin/pl
	install -m 0755 $(PLUTIL) $(DESTDIR)$(PREFIX)/bin/plutil
	install -m 0755 $(DEFAULTS) $(DESTDIR)$(PREFIX)/bin/defaults
	install -m 0444 man/pl.1 $(DESTDIR)$(PREFIX)/share/man/man1/pl.1
	install -m 0444 man/plutil.1 $(DESTDIR)$(PREFIX)/share/man/man1/plutil.1
	install -m 0444 man/defaults.1 $(DESTDIR)$(PREFIX)/share/man/man1/defaults.1

clean:
	rm -rf build

.PHONY: all test install clean