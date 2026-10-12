SHELL := $(if $(wildcard /var/jb/usr/bin/bash),/var/jb/usr/bin/bash,/bin/sh)

PACKAGE_ID := com.dsh.amapcycleassist
PACKAGE_VERSION := 1.1.0
CLANG ?= clang-16
LDID ?= ldid
DPKG_DEB ?= dpkg-deb
OTOOL ?= llvm-otool-16
NM ?= llvm-nm-16
HOST_CC ?= cc
HOST_CPPFLAGS ?=
HOST_CFLAGS ?= -std=gnu11 -O2 -g -Wall -Wextra -Werror
HOST_LIBS ?= -lsqlite3 -lm -pthread
TARGET := arm64-apple-ios15.0
BUILD_DIR := build
STAGE_DIR := $(BUILD_DIR)/stage
DYLIB := $(BUILD_DIR)/AMapCycleAssist.dylib
DEB := $(BUILD_DIR)/$(PACKAGE_ID)_$(PACKAGE_VERSION)_iphoneos-arm64.deb
INSTALL_NAME := /var/jb/Library/MobileSubstrate/DynamicLibraries/AMapCycleAssist.dylib

CFLAGS := -target $(TARGET) -fobjc-runtime=ios-15.0 -std=gnu11 -O2 -Wall -Wextra -Werror -DDSH_PLUGIN_VERSION=\"$(PACKAGE_VERSION)\"
LDFLAGS := -dynamiclib -Wl,-undefined,dynamic_lookup -Wl,-install_name,$(INSTALL_NAME) -lm -lsqlite3

.PHONY: all clean package inspect test

all: $(DYLIB)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(DYLIB): Tweak.m AdviceStrategy.c AdviceStrategy.h SignalHistory.c SignalHistory.h SignalRoute.c SignalRoute.h SignalCapture.c SignalCapture.h Makefile | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) $(LDFLAGS) -o $@ Tweak.m AdviceStrategy.c SignalHistory.c SignalRoute.c SignalCapture.c
	$(LDID) -S $@

package: $(DYLIB) AMapCycleAssist.plist control
	rm -rf $(STAGE_DIR)
	mkdir -p $(STAGE_DIR)/DEBIAN
	mkdir -p $(STAGE_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries
	cp control $(STAGE_DIR)/DEBIAN/control
	cp $(DYLIB) $(STAGE_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries/AMapCycleAssist.dylib
	cp AMapCycleAssist.plist $(STAGE_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries/AMapCycleAssist.plist
	chmod 0755 $(STAGE_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries/AMapCycleAssist.dylib
	chmod 0644 $(STAGE_DIR)/var/jb/Library/MobileSubstrate/DynamicLibraries/AMapCycleAssist.plist
	chmod 0644 $(STAGE_DIR)/DEBIAN/control
	find $(STAGE_DIR) -type d -exec chmod 0755 {} +
	$(DPKG_DEB) --root-owner-group --build $(STAGE_DIR) $(DEB)
	@echo "Built $(DEB)"

inspect: $(DYLIB)
	$(OTOOL) -hv $(DYLIB)
	$(OTOOL) -L $(DYLIB)
	$(NM) -u $(DYLIB) | sort

$(BUILD_DIR)/history_test: tests/history_test.c SignalHistory.c SignalHistory.h | $(BUILD_DIR)
	$(HOST_CC) $(HOST_CPPFLAGS) $(HOST_CFLAGS) -I. -o $@ tests/history_test.c SignalHistory.c $(HOST_LIBS)

$(BUILD_DIR)/route_test: tests/route_test.c SignalRoute.c SignalRoute.h SignalHistory.c SignalHistory.h | $(BUILD_DIR)
	$(HOST_CC) $(HOST_CPPFLAGS) $(HOST_CFLAGS) -I. -o $@ tests/route_test.c SignalRoute.c SignalHistory.c $(HOST_LIBS)

$(BUILD_DIR)/capture_test: tests/capture_test.c SignalCapture.c SignalCapture.h SignalRoute.h SignalHistory.h | $(BUILD_DIR)
	$(HOST_CC) $(HOST_CPPFLAGS) $(HOST_CFLAGS) -I. -o $@ tests/capture_test.c SignalCapture.c -lm

test: $(BUILD_DIR)/history_test $(BUILD_DIR)/route_test $(BUILD_DIR)/capture_test
	$(BUILD_DIR)/history_test
	$(BUILD_DIR)/route_test
	$(BUILD_DIR)/capture_test

clean:
	rm -rf $(BUILD_DIR)
