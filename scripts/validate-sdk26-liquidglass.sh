#!/usr/bin/env bash
set -euo pipefail

: "${THEOS:?THEOS must be set}"

sdk="$THEOS/sdks/iPhoneOS26.2.sdk"
headers="$sdk/System/Library/Frameworks/UIKit.framework/Headers"

test -d "$headers" || {
    echo "error: missing UIKit headers in $sdk" >&2
    exit 1
}

grep -R "UIGlassEffect" "$headers" >/dev/null
grep -R "UIGlassContainerEffect" "$headers" >/dev/null
grep -R "UIGlassEffectStyleRegular" "$headers" >/dev/null
grep -R "glassButtonConfiguration" "$headers" >/dev/null
grep -R "prominentGlassButtonConfiguration" "$headers" >/dev/null

grep -q "iphone:clang:26.2:16.3" Makefile
grep -q "iphone:clang:26.2:16.3" libflex/Makefile
grep -q '^ARCHS := arm64$' Makefile
grep -q '^ARCHS := arm64$' libflex/Makefile
test -f build.sh
grep -q 'make package FINALPACKAGE=1' build.sh
grep -q 'include modules/HookRuntime/Module.mk' libflex/Makefile
grep -q 'include modules/LiquidGlassUI/Module.mk' libflex/Makefile
grep -q 'FLEX_FISHHOOK_SOURCE' libflex/Makefile
grep -Fq '$(TWEAK_NAME)_USE_MODULES := 0' libflex/Makefile
grep -Eq '\$\(TWEAK_NAME\)_LIBRARIES[[:space:]]*:=[^#]*substrate' libflex/Makefile
test -f libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q "UIGlassEffect" libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q "UIGlassContainerEffect" libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q '#import <substrate.h>' libflex/AllFLEXing/FLEXHooking.m
grep -q 'MSHookMessageEx' libflex/AllFLEXing/FLEXHooking.m
grep -q 'MSHookFunction' libflex/AllFLEXing/FLEXHooking.m
grep -q 'FLEXHookRegistry' libflex/AllFLEXing/FLEXHookRegistry.m
grep -q 'FLEXRuntimeScanner' libflex/AllFLEXing/FLEXRuntimeScanner.m
grep -q 'FLEXRuntimeImagesDidChangeNotification' libflex/AllFLEXing/FLEXRuntimeScanner.m

if grep -q 'GENERATOR[[:space:]]*:=[[:space:]]*internal' libflex/Makefile; then
    echo "error: internal Logos generator cannot provide the required C hook backend" >&2
    exit 1
fi

echo "SDK 26.2, module manifests, Liquid Glass, registry, and Substrate-compatible build contract: OK"
