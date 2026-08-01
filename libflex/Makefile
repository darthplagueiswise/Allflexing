TARGET := iphone:clang:26.2:16.3
ARCHS := arm64

export TARGET ARCHS

include $(THEOS)/makefiles/common.mk

FLEX_ROOT := FLEX
ALLFLEXING_ROOT := AllFLEXing

include modules/Core/Module.mk
include modules/HookRuntime/Module.mk
include modules/LiquidGlassUI/Module.mk

dtoim = $(foreach d,$(1),-I$(d))

FLEX_SOURCES  := $(shell find $(FLEX_ROOT)/Classes -type f -name '*.c' | sort)
FLEX_SOURCES += $(shell find $(FLEX_ROOT)/Classes -type f -name '*.m' | sort)
FLEX_SOURCES += $(shell find $(FLEX_ROOT)/Classes -type f -name '*.mm' | sort)
ALLFLEXING_SOURCES := $(sort \
	$(ALLFLEXING_CORE_SOURCES) \
	$(ALLFLEXING_HOOK_RUNTIME_SOURCES) \
	$(ALLFLEXING_LIQUID_GLASS_UI_SOURCES))
ALLFLEXING_DISCOVERED_SOURCES := $(shell find $(ALLFLEXING_ROOT) -type f \( -name '*.c' -o -name '*.m' -o -name '*.mm' \) | sort)

ifneq ($(sort $(ALLFLEXING_SOURCES)),$(sort $(ALLFLEXING_DISCOVERED_SOURCES)))
$(error AllFLEXing module manifests do not match the source tree)
endif

FLEX_FISHHOOK_SOURCE := $(FLEX_ROOT)/Classes/Utility/Runtime/flex_fishhook.c
ifeq ($(filter $(FLEX_FISHHOOK_SOURCE),$(FLEX_SOURCES)),)
$(error namespaced fishhook source is missing from the unified target)
endif

_IMPORTS  := $(shell /bin/ls -d $(FLEX_ROOT)/Classes/*/ 2>/dev/null)
_IMPORTS += $(shell /bin/ls -d $(FLEX_ROOT)/Classes/*/*/ 2>/dev/null)
_IMPORTS += $(shell /bin/ls -d $(FLEX_ROOT)/Classes/*/*/*/ 2>/dev/null)
_IMPORTS += $(shell /bin/ls -d $(FLEX_ROOT)/Classes/*/*/*/*/ 2>/dev/null)
IMPORTS := -I$(FLEX_ROOT)/Classes -I$(ALLFLEXING_ROOT) $(call dtoim,$(_IMPORTS))

TWEAK_NAME := AllFLEXing

$(TWEAK_NAME)_FILES := $(FLEX_SOURCES) $(ALLFLEXING_SOURCES)
$(TWEAK_NAME)_FRAMEWORKS := Foundation CoreGraphics UIKit ImageIO QuartzCore SceneKit Security WebKit AVFoundation UserNotifications
$(TWEAK_NAME)_LIBRARIES := sqlite3 z c++ substrate
$(TWEAK_NAME)_USE_MODULES := 0

# Keep the SDK/deployment contract fixed and provide the TARGET_OS definitions
# expected by the iPhoneOS 26.2 headers when Clang modules are disabled.
ALLFLEXING_TARGET_FLAGS := \
	-DTARGET_OS_MAC=1 \
	-DTARGET_OS_OSX=0 \
	-DTARGET_OS_IPHONE=1 \
	-DTARGET_OS_IOS=1 \
	-DTARGET_OS_EMBEDDED=1 \
	-DTARGET_OS_SIMULATOR=0 \
	-DTARGET_OS_MACCATALYST=0 \
	-DTARGET_OS_UIKITFORMAC=0 \
	-DTARGET_OS_TV=0 \
	-DTARGET_OS_WATCH=0 \
	-DTARGET_OS_VISION=0 \
	-DTARGET_OS_BRIDGE=0 \
	-DTARGET_OS_DRIVERKIT=0

ALLFLEXING_SDK_SEARCH_PATHS := \
	-F$(THEOS)/sdks/iPhoneOS26.2.sdk/System/Library/SubFrameworks

$(TWEAK_NAME)_CFLAGS += -fobjc-arc $(IMPORTS) $(ALLFLEXING_TARGET_FLAGS)
$(TWEAK_NAME)_CFLAGS += $(ALLFLEXING_SDK_SEARCH_PATHS)
$(TWEAK_NAME)_CFLAGS += -Wno-unsupported-availability-guard -Wno-deprecated-declarations
$(TWEAK_NAME)_CFLAGS += -Wno-nullability-completeness -Wno-unused-function
$(TWEAK_NAME)_CFLAGS += -Wno-unused-but-set-variable -Wno-gnu-folding-constant
$(TWEAK_NAME)_CCFLAGS += -std=gnu++11

# Feather places a Substrate-compatible CydiaSubstrate.framework backed by
# ElleKit in the certificate-signed app and rewrites the dependency to @rpath.
# The default MobileSubstrate Logos generator keeps the same working Theos
# linkage contract used by the rest of the runtime.
$(TWEAK_NAME)_LDFLAGS += -Wl,-install_name,@rpath/AllFLEXing.dylib

ifeq ($(FINALPACKAGE),1)
	$(TWEAK_NAME)_LDFLAGS += -Wl,-x
endif

include $(THEOS_MAKE_PATH)/tweak.mk

after-all::
	@if command -v ldid >/dev/null 2>&1; then \
		ldid -S "$(THEOS_OBJ_DIR)/AllFLEXing.dylib"; \
	else \
		echo "warning: ldid is not installed; leaving AllFLEXing.dylib unsigned"; \
	fi

before-stage::
	find . -name ".DS_Store" -delete

print-%: ; @echo $* = $($*)
