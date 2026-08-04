#!/usr/bin/env bash
set -euo pipefail

source_file="libflex/AllFLEXing/FLEXHookRegistry.m"

test -f "$source_file" || {
    echo "error: missing registry source: $source_file" >&2
    exit 1
}

require_text() {
    local label="$1"
    local needle="$2"
    grep -Fq -- "$needle" "$source_file" || {
        echo "error: missing $label: $needle" >&2
        exit 1
    }
}

forbid_text() {
    local label="$1"
    local needle="$2"
    if grep -Fq -- "$needle" "$source_file"; then
        echo "error: obsolete $label remains: $needle" >&2
        exit 1
    fi
}

require_text "typed context ABI marker" \
    "AllFLEXing typed Objective-C hook context ABI 1"
require_text "typed replacement factory" \
    "FLEXMakeObjectiveCReplacement(entry.abi, context)"
require_text "pre-install forwarding seed" \
    "context.original = method_getImplementation(method)"
require_text "provider-returned trampoline publication" \
    "context.original = original;"
require_text "retained entry ownership" \
    "@property (nonatomic, strong, readonly) FLEXHookEntry *entry;"

forbid_text "weak entry captured by an installed replacement" \
    "__weak FLEXHookEntry *weakEntry"
forbid_text "byref trampoline storage captured by a block" \
    "__block IMP original"
forbid_text "block lifetime scoped inside a switch case" \
    "case FLEXHookABIObjCBoolNoArguments: {"
forbid_text "block lifetime scoped inside a switch case" \
    "case FLEXHookABIObjCBoolObjectArgument: {"
forbid_text "block lifetime scoped inside a switch case" \
    "case FLEXHookABIObjCBoolIntegerArgument: {"

echo "AllFLEXing typed Objective-C hook context validation: OK"
