TARGET ?= iphone:clang:26.2:15.0
ARCHS ?= arm64

export TARGET ARCHS

include $(THEOS)/makefiles/common.mk

# AllFLEXing is intentionally the only build target. FLEX, the loader, the
# runtime hook layer, persistence, and the UIKit 26 UI all link into one dylib.
SUBPROJECTS += libflex

include $(THEOS_MAKE_PATH)/aggregate.mk

before-stage::
	find . -name ".DS_Store" -delete

print-%: ; @echo $* = $($*)
