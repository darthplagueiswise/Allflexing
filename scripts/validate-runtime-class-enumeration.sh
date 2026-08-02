#!/usr/bin/env bash
set -euo pipefail

source_file="libflex/AllFLEXing/FLEXRuntimeImageSession.mm"
test_file="tests/runtime_class_enumeration_root_class.m"

for path in "$source_file" "$test_file"; do
    test -f "$path" || {
        echo "error: required runtime enumeration file is missing: $path" >&2
        exit 1
    }
done

require_source_text() {
    local label="$1"
    local text="$2"
    grep -Fq -- "$text" "$source_file" || {
        echo "error: missing $label: $text" >&2
        exit 1
    }
    echo "verified $label: $text"
}

require_source_text "image-scoped Objective-C enumeration" "objc_enumerateClasses("
require_source_text "raw class C API access" "class_getName(targetClass)"
require_source_text "method-list C API access" "class_copyMethodList(owner"
require_source_text "nonretaining enumeration ABI marker" \
    "AllFLEXing image-scoped nonretaining Objective-C class enumeration ABI 1"

forbidden_patterns=(
    'NSMutableArray[[:space:]]*<[[:space:]]*Class'
    'NSArray[[:space:]]*<[[:space:]]*Class'
    'addObject:[[:space:]]*classes\['
    'addObject:[[:space:]]*targetClass'
    'objc_copyClassList[[:space:]]*\('
)

for pattern in "${forbidden_patterns[@]}"; do
    if grep -Eq -- "$pattern" "$source_file"; then
        echo "error: raw Class retention/global enumeration pattern returned: $pattern" >&2
        exit 1
    fi
done

echo "verified raw Class values are not stored in Foundation collections"

binary="${TMPDIR:-/tmp}/allflexing-runtime-class-enumeration-test"
rm -f "$binary"
xcrun clang \
    -fblocks \
    -Wall \
    -Wextra \
    -Werror \
    -mmacosx-version-min=13.0 \
    "$test_file" \
    -framework Foundation \
    -o "$binary"
"$binary"
rm -f "$binary"

echo "AllFLEXing Objective-C class enumeration validation: OK"
