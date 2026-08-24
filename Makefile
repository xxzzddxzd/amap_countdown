SHELL := /var/jb/usr/bin/bash

PACKAGE_ID := com.dsh.amapcycleassist
PACKAGE_VERSION := 1.0.28
CLANG ?= clang-16
LDID ?= ldid
DPKG_DEB ?= dpkg-deb
TARGET := arm64-apple-ios15.0
BUILD_DIR := build
STAGE_DIR := $(BUILD_DIR)/stage
DYLIB := $(BUILD_DIR)/AMapCycleAssist.dylib
DEB := $(BUILD_DIR)/$(PACKAGE_ID)_$(PACKAGE_VERSION)_iphoneos-arm64.deb
INSTALL_NAME := /var/jb/Library/MobileSubstrate/DynamicLibraries/AMapCycleAssist.dylib

CFLAGS := -target $(TARGET) -fobjc-runtime=ios-15.0 -std=gnu11 -O2 -Wall -Wextra -Werror
LDFLAGS := -dynamiclib -Wl,-undefined,dynamic_lookup -Wl,-install_name,$(INSTALL_NAME) -lm

.PHONY: all clean package inspect

all: $(DYLIB)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(DYLIB): Tweak.m | $(BUILD_DIR)
	$(CLANG) $(CFLAGS) $(LDFLAGS) -o $@ $<
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
	$(DPKG_DEB) --root-owner-group --build $(STAGE_DIR) $(DEB)
	@echo "Built $(DEB)"

inspect: $(DYLIB)
	llvm-otool-16 -hv $(DYLIB)
	llvm-otool-16 -L $(DYLIB)
	llvm-nm-16 -u $(DYLIB) | sort

clean:
	rm -rf $(BUILD_DIR)
