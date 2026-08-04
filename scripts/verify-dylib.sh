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
if grep -Eiq '/usr/lib/libFLEX\.dylib|(^|/)FLEXing\.dylib' <<<"$linked_libraries"; then
    echo "error: FLEX/libFLEX is still linked as a separate dylib" >&2
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
defined_symbols="$(nm -gUj "$dylib")"
echo "global symbols: $(wc -l <<<"$symbols" | tr -d ' ')"
defined_flex_classes="$(grep -c '^_OBJC_CLASS_\$_FLEX' <<<"$defined_symbols" || true)"
if (( defined_flex_classes < 150 )); then
    echo "error: unified FLEX class inventory is incomplete ($defined_flex_classes)" >&2
    exit 1
fi
echo "verified unified FLEX class inventory: $defined_flex_classes classes"
require_text "public flag API" "_FLEXFlag" "$symbols"
require_text "libFLEX compatibility API" "_FLXGetManager" "$symbols"
require_text "libFLEX compatibility API" "_FLXRevealSEL" "$symbols"
require_text "libFLEX compatibility API" "_FLXWindowClass" "$symbols"
require_text "UIKit 26 glass class reference" '_OBJC_CLASS_$_UIGlassEffect' "$symbols"
require_text "UIKit 26 container class reference" '_OBJC_CLASS_$_UIGlassContainerEffect' "$symbols"
require_text "UIKit 26 corner configuration" '_OBJC_CLASS_$_UICornerConfiguration' "$symbols"
require_text "Objective-C hook import" "_MSHookMessageEx" "$symbols"
require_text "inline C hook import" "_MSHookFunction" "$symbols"
require_text "independent Objective-C provider capability" "_FLEXMSHookMessageProviderAvailable" "$defined_symbols"
require_text "independent inline provider capability" "_FLEXMSHookFunctionProviderAvailable" "$defined_symbols"
require_text "embedded fishhook link contract" "_FLEXEmbeddedFishhookAvailable" "$defined_symbols"
require_text "embedded fishhook ABI marker" "_FLEXEmbeddedFishhookABIVersion" "$defined_symbols"
require_text "contextual runtime hook actions" '_OBJC_CLASS_$_FLEXRuntimeHookActions' "$defined_symbols"
require_text "FLEX metadata hook resolver" '_OBJC_CLASS_$_FLEXObjCHookResolver' "$defined_symbols"
require_text "filtered FLEX runtime controller" '_OBJC_CLASS_$_FLEXHookableObjCRuntimeViewController' "$defined_symbols"
require_text "filtered FLEX object explorer" '_OBJC_CLASS_$_FLEXHookableObjectExplorerViewController' "$defined_symbols"

string_dump="$(strings -a "$dylib")"
require_text "hook persistence class" "FLEXHookPersistence" "$string_dump"
require_text "symbol rebind class" "FLEXSymbolRebind" "$string_dump"
require_text "Liquid Glass class" "FLEXLiquidGlass" "$string_dump"
require_text "adaptive runtime workspace" "FLEXHookWorkspaceController" "$string_dump"
require_text "interactive workspace tab bar" "AllFLEXing.RuntimeWorkspace.TabBar" "$string_dump"
require_text "nested modal hit testing" "flex_pointIsInsidePresentedHierarchy:withEvent:" "$string_dump"
require_text "separate runtime settings" "FLEXHookSettingsController" "$string_dump"
require_text "responsive Hook Center header" "FLEXHookCenterHeaderView" "$string_dump"
require_text "explicit glass table surfaces" "FLEXGlassCellBackgroundView" "$string_dump"
require_text "explicit glass materialization" "materializeGlassView:interactive:tint:animated:" "$string_dump"
require_text "UIKit 26 floating search placement" "searchBarPlacementBarButtonItem" "$string_dump"
require_text "modern runtime control plane" "Runtime control plane" "$string_dump"
require_text "hook registry" "FLEXHookRegistry" "$string_dump"
require_text "ABI-aware C engine" "FLEXCHookEngine" "$string_dump"
require_text "C-only runtime scanner" "com.allflexing.c-runtime-scanner" "$string_dump"
require_text "FLEX-native Objective-C title" "Hookable Objective-C" "$string_dump"
require_text "plain semantic search placeholder" "Nome, palavras ou sintaxe FLEX" "$string_dump"
require_text "plain semantic search help" "Busca normal (recomendada)" "$string_dump"
require_text "advanced FLEX syntax help" "Sintaxe FLEX avançada" "$string_dump"
require_text "semantic compact query example" "fbconfigmanager" "$string_dump"
require_text "semantic multi-term example" "employee enable" "$string_dump"
require_text "contextual TRUE action" "Force TRUE" "$string_dump"
require_text "contextual FALSE action" "Force FALSE" "$string_dump"
require_text "explicit per-target apply action" "Apply This Hook" "$string_dump"
require_text "installed hook state" "Armed" "$string_dump"
require_text "runtime-observed hook state" "Observed" "$string_dump"
require_text "late-image monitor" "FLEXRuntimeImagesDidChangeNotification" "$string_dump"
require_text "FLEX menu entry" "AllFLEXing Runtime Workspace" "$string_dump"

for forbidden in \
    'Reapply This Hook' \
    'scanObjectiveCRuntimeIncludingSystemImages' \
    'objectiveCEntryForClass' \
    'com.allflexing.runtime-scanner' \
    'Instagram' \
    'RyukGram' \
    'com.burbn' \
    'FBSharedFramework'; do
    if grep -Fq -- "$forbidden" <<<"$string_dump"; then
        echo "error: forbidden legacy/host-specific runtime marker: $forbidden" >&2
        exit 1
    fi
done

if grep -Fq 'FLEXGlassAutostyle' <<<"$string_dump"; then
    echo "error: legacy global view-tree autostyle is still linked" >&2
    exit 1
fi

echo "AllFLEXing Mach-O verification: OK"
