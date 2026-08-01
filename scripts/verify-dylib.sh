#!/usr/bin/env bash
set -euo pipefail

dylib="${1:?usage: verify-dylib.sh path/to/AllFLEXing.dylib}"
test -f "$dylib" || {
    echo "error: not a file: $dylib" >&2
    exit 1
}

for tool in file lipo otool vtool nm strings; do
    command -v "$tool" >/dev/null || {
        echo "error: required Apple tool not found: $tool" >&2
        exit 1
    }
done

require_text() {
    local label="$1"
    local needle="$2"
    local haystack="$3"

    if ! grep -Fq -- "$needle" <<<"$haystack"; then
        echo "error: missing $label: $needle" >&2
        return 1
    fi
    echo "verified $label: $needle"
}

file "$dylib"
architectures="$(lipo -archs "$dylib")"
echo "architectures: $architectures"
grep -qw arm64 <<<"$architectures" || {
    echo "error: arm64 slice is required" >&2
    exit 1
}

install_name="$(otool -D "$dylib" | tail -n 1)"
test "$install_name" = "@rpath/AllFLEXing.dylib" || {
    echo "error: unexpected install name: $install_name" >&2
    exit 1
}

build_version="$(vtool -show-build "$dylib")"
echo "$build_version"
grep -Eq 'sdk[[:space:]]+26\.2' <<<"$build_version" || {
    echo "error: dylib was not linked with SDK 26.2" >&2
    exit 1
}
grep -Eq 'minos[[:space:]]+16\.3' <<<"$build_version" || {
    echo "error: minimum OS is not iOS 16.3" >&2
    exit 1
}

linked_libraries="$(otool -L "$dylib")"
if ! grep -Eiq 'CydiaSubstrate\.framework/CydiaSubstrate' <<<"$linked_libraries"; then
    echo "error: Feather-rewritable CydiaSubstrate.framework dependency is missing" >&2
    exit 1
fi
if grep -Eiq 'libhooker|substitute|/var/jb|\.jbroot' <<<"$linked_libraries"; then
    echo "error: unsupported jailbreak hook dependency detected" >&2
    exit 1
fi

load_commands="$(otool -l "$dylib")"
if grep -Eiq '/var/jb|\.jbroot' <<<"$load_commands"; then
    echo "error: jailbreak/rootless rpath detected" >&2
    exit 1
fi

symbols="$(nm -gj "$dylib")"
echo "global symbols: $(wc -l <<<"$symbols" | tr -d ' ')"
require_text "public flag API" "_FLEXFlag" "$symbols"
require_text "libFLEX compatibility API" "_FLXGetManager" "$symbols"
require_text "libFLEX compatibility API" "_FLXRevealSEL" "$symbols"
require_text "libFLEX compatibility API" "_FLXWindowClass" "$symbols"
require_text "UIKit 26 glass class reference" \
    '_OBJC_CLASS_$_UIGlassEffect' "$symbols"
require_text "UIKit 26 container class reference" \
    '_OBJC_CLASS_$_UIGlassContainerEffect' "$symbols"
require_text "Objective-C hook import" "_MSHookMessageEx" "$symbols"
require_text "inline C hook import" "_MSHookFunction" "$symbols"

string_dump="$(strings -a "$dylib")"
require_text "hook persistence class" "FLEXHookPersistence" "$string_dump"
require_text "symbol rebind class" "FLEXSymbolRebind" "$string_dump"
require_text "Liquid Glass class" "FLEXLiquidGlass" "$string_dump"
require_text "Liquid Glass cluster" "FLEXGlassClusterHostView" "$string_dump"
require_text "hook registry" "FLEXHookRegistry" "$string_dump"
require_text "ABI-aware C engine" "FLEXCHookEngine" "$string_dump"
require_text "runtime scanner" "FLEXRuntimeScanner" "$string_dump"
require_text "FLEX menu entry" "Hook Center" "$string_dump"

echo "AllFLEXing Mach-O verification: OK"
