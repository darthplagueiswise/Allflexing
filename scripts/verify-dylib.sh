#!/usr/bin/env bash
set -euo pipefail

# Post-build verification of the shipped Mach-O.
#
# Objective: prove things about the ARTIFACT that source-level tests structurally
# cannot -- that it targets the right platform, links the right providers, embeds
# FLEX whole, still contains every feature after dead-stripping, and no longer
# contains code that was removed.
#
# Design rules learned the hard way:
#
#  1. Assert identifiers that ARE the architecture (Objective-C class symbols and
#     selectors), never identifiers that merely decorate it (UI copy, screen
#     titles, button labels). UI copy changes for cosmetic reasons and a string
#     being present proves nothing about behaviour, so pinning it produces
#     failures on healthy refactors and trains people to edit the gate instead of
#     trusting it.
#
#  2. Never hard-code a value the source is free to rename. For subsystem labels
#     the expected value is READ FROM THE SOURCE and then required in the binary.
#     That still catches the real failures -- dead-stripped code, a stale
#     artifact, a source file missing from the build manifest -- while a rename
#     can no longer break the gate silently.
#
#  3. "Forbidden" markers only work for text absent from the WHOLE artifact.
#     AllFLEXing embeds all of FLEX, including FLEX's own runtime browser, so
#     FLEXKeyPathSearchController / FLEXRuntimeKeyPathTokenizer legitimately ship
#     inside this dylib. The rule that AllFLEXing's own browser must not use the
#     key-path grammar is therefore enforced in the source contract tests
#     (test-flex-semantic-search.py, test-objc-browser-safety.py), not here.

dylib="${1:?usage: verify-dylib.sh path/to/AllFLEXing.dylib}"
test -f "$dylib" || { echo "error: not a file: $dylib" >&2; exit 1; }

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/libflex/AllFLEXing"

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

# Reads a contract value out of the source so the binary is checked against what
# the code actually declares, not against a literal frozen in this script.
source_value() {
    local label="$1"
    local file="$2"
    local pattern="$3"
    local value
    value="$(grep -hoE -- "$pattern" "$src/$file" 2>/dev/null | head -n 1 || true)"
    test -n "$value" || {
        echo "error: cannot read $label from $file (source contract missing)" >&2
        exit 1
    }
    printf '%s' "$value"
}

# ---------------------------------------------------------------- Mach-O shape

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
string_dump="$(strings -a "$dylib")"

# ------------------------------------------------------- FLEX embedded whole

defined_flex_classes="$(grep -c '^_OBJC_CLASS_\$_FLEX' <<<"$defined_symbols" || true)"
(( defined_flex_classes >= 150 )) || {
    echo "error: unified FLEX class inventory is incomplete ($defined_flex_classes)" >&2
    exit 1
}
echo "verified unified FLEX class inventory: $defined_flex_classes classes"

# The Objective-C browser is built by REUSING these FLEX types rather than
# reimplementing them. If any were dead-stripped the browser would not function,
# so their presence is part of the artifact contract.
for reused in \
    '_OBJC_CLASS_$_FLEXTableViewController' \
    '_OBJC_CLASS_$_FLEXObjectExplorerViewController' \
    '_OBJC_CLASS_$_FLEXMetadataSection' \
    '_OBJC_CLASS_$_FLEXMutableListSection' \
    '_OBJC_CLASS_$_FLEXRuntimeClient'; do
    require_text "reused FLEX type" "$reused" "$defined_symbols"
done

# ------------------------------------------------------------ hook providers

require_text "public flag API" "_FLEXFlag" "$symbols"
require_text "Objective-C provider" "_MSHookMessageEx" "$symbols"
require_text "inline C provider" "_MSHookFunction" "$symbols"
require_text "embedded fishhook" "_FLEXEmbeddedFishhookAvailable" "$defined_symbols"

# ------------------------------------------------- AllFLEXing architecture

for owned in \
    '_OBJC_CLASS_$_FLEXHookRegistry' \
    '_OBJC_CLASS_$_FLEXCHookEngine' \
    '_OBJC_CLASS_$_FLEXObjCHookResolver' \
    '_OBJC_CLASS_$_FLEXHookableObjCRuntimeViewController' \
    '_OBJC_CLASS_$_FLEXHookableObjCSearchController' \
    '_OBJC_CLASS_$_FLEXHookableObjectExplorerViewController' \
    '_OBJC_CLASS_$_FLEXRuntimeBrowserController'; do
    require_text "AllFLEXing type" "$owned" "$defined_symbols"
done

# Selectors are emitted into __objc_methname and are the real wiring between
# those types. Each one below is a load-bearing edge of the architecture:
# discovery -> eligibility -> registry -> apply, and search -> explorer.
require_text "eligibility gate" "canRepresentMethod:inClassNamed:" "$string_dump"
require_text "discovery to registry" "mergeDiscoveredEntries:surface:" "$string_dump"
require_text "per-target apply" "applyEntryIdentifier:completion:" "$string_dump"
require_text "search to explorer" "hookableSearchDidSelectClass:" "$string_dump"
require_text "explorer entry point" "exploringHookableClass:" "$string_dump"
require_text "FLEX section filtering" "setExcludedMetadata:" "$string_dump"

# ------------------------------------- subsystem labels, read from the source

objc_search_queue="$(source_value "Objective-C search queue" \
    FLEXHookableObjCSearchController.m 'com\.allflexing\.[A-Za-z0-9._-]+')"
require_text "Objective-C discovery subsystem" "$objc_search_queue" "$string_dump"

c_scanner_queue="$(source_value "C scanner queue" \
    FLEXRuntimeScanner.m 'com\.allflexing\.[A-Za-z0-9._-]+')"
require_text "C-only scanner subsystem" "$c_scanner_queue" "$string_dump"

# Persisted identifiers are contractual: changing one silently discards state
# the user already has on device.
workspace_tab_bar="$(source_value "workspace tab bar identifier" \
    FLEXHookWorkspaceController.m 'AllFLEXing\.RuntimeWorkspace\.[A-Za-z0-9]+')"
require_text "runtime workspace identity" "$workspace_tab_bar" "$string_dump"

require_text "Liquid Glass" "FLEXLiquidGlass" "$string_dump"
require_text "late-image monitor" "FLEXRuntimeImagesDidChangeNotification" "$string_dump"

# ------------------------------------------------------------ removed code

# Only text that must be absent from the ENTIRE artifact belongs here.
for forbidden in \
    'scanObjectiveCRuntimeIncludingSystemImages' \
    'runtimeBrowserSearchPlainTextQuery:completion:' \
    'runtimeBrowserShouldUsePlainTextSearchForQuery:' \
    'Nome, palavras ou sintaxe FLEX'; do
    if grep -Fq -- "$forbidden" <<<"$string_dump"; then
        echo "error: removed code is still present in the artifact: $forbidden" >&2
        exit 1
    fi
done

echo "AllFLEXing Mach-O verification: OK"
