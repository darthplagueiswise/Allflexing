#!/usr/bin/env bash
set -euo pipefail

dylib="${1:?usage: verify-dylib.sh path/to/AllFLEXing.dylib}"
test -f "$dylib" || { echo "error: not a file: $dylib" >&2; exit 1; }

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
    grep -Fq -- "$needle" <<<"$haystack" || {
        echo "error: missing $label: $needle" >&2
        exit 1
    }
    echo "verified $label: $needle"
}

file "$dylib"
architectures="$(lipo -archs "$dylib")"
echo "architectures: $architectures"
grep -qw arm64 <<<"$architectures" || { echo "error: arm64 required" >&2; exit 1; }

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
grep -Eiq 'CydiaSubstrate\.framework/CydiaSubstrate' <<<"$linked_libraries" || {
    echo "error: Substrate-compatible framework dependency is missing" >&2
    exit 1
}

symbols="$(nm -gj "$dylib")"
defined_symbols="$(nm -gUj "$dylib")"
defined_flex_classes="$(grep -c '^_OBJC_CLASS_\$_FLEX' <<<"$defined_symbols" || true)"
(( defined_flex_classes >= 150 )) || {
    echo "error: unified FLEX class inventory is incomplete ($defined_flex_classes)" >&2
    exit 1
}
echo "verified unified FLEX class inventory: $defined_flex_classes classes"

require_text "public flag API" "_FLEXFlag" "$symbols"
require_text "Objective-C provider" "_MSHookMessageEx" "$symbols"
require_text "inline C provider" "_MSHookFunction" "$symbols"
require_text "embedded fishhook" "_FLEXEmbeddedFishhookAvailable" "$defined_symbols"
require_text "Objective-C resolver" '_OBJC_CLASS_$_FLEXObjCHookResolver' "$defined_symbols"
require_text "eligible Objective-C controller" '_OBJC_CLASS_$_FLEXHookableObjCRuntimeViewController' "$defined_symbols"
require_text "C patcher controller" '_OBJC_CLASS_$_FLEXRuntimeBrowserController' "$defined_symbols"

string_dump="$(strings -a "$dylib")"
require_text "Liquid Glass" "FLEXLiquidGlass" "$string_dump"
require_text "runtime workspace" "AllFLEXing.RuntimeWorkspace.TabBar" "$string_dump"
require_text "hook registry" "FLEXHookRegistry" "$string_dump"
require_text "ABI-aware C engine" "FLEXCHookEngine" "$string_dump"
require_text "C-only scanner" "com.allflexing.c-runtime-scanner" "$string_dump"
require_text "FLEX-backed Objective-C discovery" "com.allflexing.flex-objc-eligible-discovery" "$string_dump"
require_text "Objective-C function title" "Objective-C Functions" "$string_dump"
require_text "resolved Objective-C ABI contract" "Objective-C ABIs are derived" "$string_dump"
require_text "Objective-C ABI profile" "BOOL(id, SEL)" "$string_dump"
require_text "Objective-C search" "Class, selector, ABI or image" "$string_dump"
require_text "C Symbol Patcher title" "C Symbol Patcher" "$string_dump"
require_text "C Symbol Patcher search" "Symbol, image or ABI" "$string_dump"
require_text "explicit per-target apply" "Apply This Hook" "$string_dump"
require_text "armed state" "Armed" "$string_dump"
require_text "observed state" "Observed" "$string_dump"
require_text "late-image monitor" "FLEXRuntimeImagesDidChangeNotification" "$string_dump"

for forbidden in \
    'scanObjectiveCRuntimeIncludingSystemImages' \
    'runtimeBrowserSearchPlainTextQuery:completion:' \
    'runtimeBrowserShouldUsePlainTextSearchForQuery:' \
    'FLEXHookableObjectExplorerViewController' \
    'Nome, palavras ou sintaxe FLEX'; do
    if grep -Fq -- "$forbidden" <<<"$string_dump"; then
        echo "error: forbidden legacy Objective-C browser marker: $forbidden" >&2
        exit 1
    fi
done

echo "AllFLEXing Mach-O verification: OK"
