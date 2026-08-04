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
    grep -Fq -- "$needle" <<<"$haystack" || {
        echo "error: missing $label: $needle" >&2
        return 1
    }
    echo "verified $label: $needle"
}

file "$dylib"
architectures="$(lipo -archs "$dylib")"
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
    echo "error: Feather-rewritable CydiaSubstrate.framework dependency is missing" >&2
    exit 1
}
if grep -Eiq '/usr/lib/libFLEX\.dylib|(^|/)FLEXing\.dylib|libhooker|substitute|/var/jb|\.jbroot' <<<"$linked_libraries"; then
    echo "error: unsupported external FLEX/jailbreak dependency detected" >&2
    exit 1
fi
if grep -Eiq '/var/jb|\.jbroot' <<<"$(otool -l "$dylib")"; then
    echo "error: jailbreak/rootless rpath detected" >&2
    exit 1
fi

symbols="$(nm -gj "$dylib")"
defined_symbols="$(nm -gUj "$dylib")"
defined_flex_classes="$(grep -c '^_OBJC_CLASS_\$_FLEX' <<<"$defined_symbols" || true)"
(( defined_flex_classes >= 150 )) || {
    echo "error: unified FLEX class inventory is incomplete ($defined_flex_classes)" >&2
    exit 1
}

require_text "public flag API" "_FLEXFlag" "$symbols"
require_text "libFLEX compatibility API" "_FLXGetManager" "$symbols"
require_text "libFLEX compatibility API" "_FLXRevealSEL" "$symbols"
require_text "libFLEX compatibility API" "_FLXWindowClass" "$symbols"
require_text "UIKit 26 glass class" '_OBJC_CLASS_$_UIGlassEffect' "$symbols"
require_text "UIKit 26 glass container" '_OBJC_CLASS_$_UIGlassContainerEffect' "$symbols"
require_text "Objective-C provider import" "_MSHookMessageEx" "$symbols"
require_text "inline provider import" "_MSHookFunction" "$symbols"
require_text "image-scoped Objective-C enumeration import" "_objc_enumerateClasses" "$symbols"
require_text "Objective-C provider capability" "_FLEXMSHookMessageProviderAvailable" "$defined_symbols"
require_text "inline provider capability" "_FLEXMSHookFunctionProviderAvailable" "$defined_symbols"
require_text "embedded fishhook" "_FLEXEmbeddedFishhookAvailable" "$defined_symbols"
require_text "contextual runtime actions" '_OBJC_CLASS_$_FLEXRuntimeHookActions' "$defined_symbols"

string_dump="$(strings -a "$dylib")"
require_text "durable persistence" \
    "AllFLEXing persistence app-group defaults atomic-mirror ABI 3" "$string_dump"
require_text "confirmed-state Keychain persistence" \
    "AllFLEXing confirmed-state Keychain App Group mirror ABI 1" "$string_dump"
require_text "read-only persistence discovery" \
    "AllFLEXing read-only persistence discovery ABI 1" "$string_dump"
require_text "post-restore flag reload" \
    "AllFLEXing post-mirror flag cache reload ABI 1" "$string_dump"
require_text "UI-only post-scene bootstrap" \
    "AllFLEXing post-scene UI-only bootstrap ABI 2" "$string_dump"
require_text "user-invoked runtime activation" \
    "AllFLEXing user-invoked runtime activation ABI 1" "$string_dump"
require_text "upstream FLEX constructor suppression" \
    "AllFLEXing upstream FLEX automatic constructors disabled ABI 1" "$string_dump"
require_text "workspace activation log" \
    "runtime activation begins only after the workspace is opened" "$string_dump"
require_text "staged-only toggle policy" \
    "AllFLEXing staged toggles explicit-Apply-only ABI 1" "$string_dump"
require_text "staged-only user guidance" \
    "No patch, swizzle or hook is installed until Apply is pressed" "$string_dump"
require_text "runtime browser crash guards" \
    "AllFLEXing runtime browser crash guards ABI 1" "$string_dump"
require_text "selected-image runtime session" \
    "AllFLEXing complete selected-image runtime session ABI 1" "$string_dump"
require_text "current-process host isolation" \
    "AllFLEXing current-process Mach-O host isolation ABI 1" "$string_dump"
require_text "nonretaining Objective-C class enumeration" \
    "AllFLEXing image-scoped nonretaining Objective-C class enumeration ABI 1" "$string_dump"
require_text "host/image-scoped transient bridge" \
    "AllFLEXing host/image-scoped transient runtime bridge ABI 4" "$string_dump"
require_text "complete-image substring search" \
    "AllFLEXing complete-image substring-index search ABI 1" "$string_dump"
require_text "field-scoped compact-token search" \
    "AllFLEXing field-scoped compact-token search ABI 1" "$string_dump"
require_text "operational Objective-C projection" \
    "AllFLEXing operational Objective-C hook-target projection ABI 1" "$string_dump"
require_text "operational Objective-C ABI evidence" \
    "objc-type-encoding-operational-profile" "$string_dump"
require_text "live Objective-C provider evidence" \
    "MSHookMessageEx-live-provider" "$string_dump"
require_text "image-address C hook engine" \
    "AllFLEXing image-UUID executable-address C hook engine ABI 1" "$string_dump"
require_text "ASLR-safe image offset rebase" \
    "AllFLEXing image-UUID header-plus-offset ASLR rebase ABI 1" "$string_dump"
require_text "ARM64 evidence resolver" \
    "AllFLEXing image-scoped ARM64 evidence ABI resolver ABI 2" "$string_dump"
require_text "complete snapshot index phase" \
    "Indexing complete image snapshot" "$string_dump"
require_text "image selection menu" "Runtime image" "$string_dump"
require_text "Mach-O import parsing" "mach-o-indirect-symbols" "$string_dump"
require_text "Mach-O executable symbols" "mach-o-symbol-table" "$string_dump"
require_text "function-start parsing" "LC_FUNCTION_STARTS" "$string_dump"
require_text "Objective-C metadata source" "objc-runtime-metadata" "$string_dump"
require_text "fishhook backend evidence" "fishhook-bind-slot" "$string_dump"
require_text "inline backend evidence" "MSHookFunction-executable-address" "$string_dump"
require_text "host executable UUID stamp" "hostExecutableUUID" "$string_dump"
require_text "runtime session image UUID stamp" "runtimeSessionImageUUID" "$string_dump"
require_text "runtime session image path stamp" "runtimeSessionImagePath" "$string_dump"
require_text "full symbol-name layout" \
    "AllFLEXing native grouped UIKit table ABI 2 full-symbol-names" "$string_dump"
require_text "native grouped rendering" \
    "AllFLEXing native UIKit rendering bootstrap ABI 1" "$string_dump"
require_text "adaptive workspace" "FLEXHookWorkspaceController" "$string_dump"
require_text "runtime image monitor" "FLEXRuntimeImagesDidChangeNotification" "$string_dump"
require_text "hook registry" "FLEXHookRegistry" "$string_dump"
require_text "C engine" "FLEXCHookEngine" "$string_dump"
require_text "installed state" "Armed" "$string_dump"
require_text "observed state" "Observed" "$string_dump"
require_text "FLEX menu entry" "AllFLEXing Runtime Workspace" "$string_dump"

for forbidden in \
    FLEXGlassAutostyle \
    FLEXCompactGroupBackgroundView \
    AllFLEXingCompactRuntimeCell \
    AllFLEXingCompactHookCenterCell \
    "AllFLEXing tokenized AND search ABI 2" \
    "AllFLEXing full-snapshot async indexed cancellable search ABI 4" \
    "AllFLEXing selected-image transient-snapshot prefix-index search ABI 7" \
    "AllFLEXing post-scene deferred runtime bootstrap ABI 1" \
    "AllFLEXing transient runtime snapshot bridge ABI 2 registry-only" \
    "AllFLEXing host/image-scoped transient runtime bridge ABI 3" \
    "manual-apply-all" \
    "the symbol name indicates a Boolean result" \
    "The name suggests a Boolean result" \
    "FBConfigManager" \
    "RyukGram" \
    "com.burbn.instagram"; do
    if grep -Fq "$forbidden" <<<"$string_dump"; then
        echo "error: obsolete or foreign runtime data is still linked: $forbidden" >&2
        exit 1
    fi
done

echo "AllFLEXing Mach-O verification: OK"
