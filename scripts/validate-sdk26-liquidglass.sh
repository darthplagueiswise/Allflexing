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

grep -q "iphone:clang:26.2:15.0" Makefile
grep -q "iphone:clang:26.2:15.0" libflex/Makefile
test -f libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q "UIGlassEffect" libflex/AllFLEXing/FLEXLiquidGlass.m
grep -q "UIGlassContainerEffect" libflex/AllFLEXing/FLEXLiquidGlass.m

if grep -RIn --include='*.m' --include='*.mm' --include='*.c' \
    -E '#include[[:space:]]*[<\"](substrate|CydiaSubstrate|libhooker|ellekit)' \
    libflex/AllFLEXing; then
    echo "error: standalone runtime must not include an external hook framework" >&2
    exit 1
fi

echo "SDK 26.2 Liquid Glass headers and standalone runtime: OK"
