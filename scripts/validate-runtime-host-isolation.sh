#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$ROOT/libflex/AllFLEXing/FLEXRuntimeScanner.m"
SESSION="$ROOT/libflex/AllFLEXing/FLEXRuntimeImageSession.mm"
ISOLATION="$ROOT/libflex/AllFLEXing/FLEXRuntimeHostIsolation.m"
BRIDGE="$ROOT/libflex/AllFLEXing/FLEXRuntimeSnapshotRegistryBridge.m"

for file in "$SCANNER" "$SESSION" "$ISOLATION" "$BRIDGE"; do
    test -f "$file" || {
        echo "missing host-isolation source: $file" >&2
        exit 1
    }
done

require_source() {
    local file="$1"
    local pattern="$2"
    grep -Fq "$pattern" "$file" || {
        echo "missing host-isolation contract '$pattern' in $file" >&2
        exit 1
    }
}

require_source "$SCANNER" \
    "AllFLEXing no-global-catalog host-image runtime scanner ABI 1"
require_source "$ISOLATION" \
    "AllFLEXing current-process Mach-O host isolation ABI 1"
require_source "$BRIDGE" \
    "AllFLEXing host/image-scoped transient runtime bridge ABI 4"
require_source "$ISOLATION" 'locator[@"hostExecutableUUID"]'
require_source "$ISOLATION" 'locator[@"runtimeSessionImageUUID"]'
require_source "$BRIDGE" 'locator[@"hostBundleIdentifier"]'
require_source "$BRIDGE" 'locator[@"hostExecutableUUID"]'
require_source "$BRIDGE" 'FLEXBridgeObjectiveCClassMatchesImage'

if grep -Fq 'objc_copyClassList' "$SCANNER"; then
    echo "legacy process-wide Objective-C catalog returned to FLEXRuntimeScanner.m" >&2
    exit 1
fi

python3 - "$SCANNER" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
for selector in (
    "scanObjectiveCRuntimeIncludingSystemImages",
    "scanCImportsIncludingSystemImages",
):
    match = re.search(
        rf"\+ \(void\){selector}:.*?(?=\n\+ \(|\n@end)",
        source,
        flags=re.S,
    )
    if not match:
        raise SystemExit(f"missing legacy scanner API: {selector}")
    body = match.group(0)
    if "completion(@[])" not in body:
        raise SystemExit(f"{selector} no longer fails closed with an empty catalog")
    forbidden = (
        "objc_copyClassList",
        "class_copyMethodList",
        "S_LAZY_SYMBOL_POINTERS",
        "S_NON_LAZY_SYMBOL_POINTERS",
    )
    for token in forbidden:
        if token in body:
            raise SystemExit(
                f"{selector} contains process-wide catalog logic: {token}"
            )
PY

# The operational scanner must be generic. Host-specific class catalogs or
# identifiers are never valid source inputs for a reusable injected dylib.
if grep -RIEq \
    'FBConfigManager|com\.burbn\.instagram|RyukGram|Instagram[A-Z][A-Za-z0-9_]+' \
    "$ROOT/libflex/AllFLEXing" \
    --include='*.m' --include='*.mm' --include='*.x' --include='*.xm' \
    --include='*.c' --include='*.h'; then
    echo "host-specific Instagram/RyukGram catalog data found in runtime sources" >&2
    exit 1
fi

if [[ $# -ge 1 ]]; then
    DYLIB="$1"
    test -f "$DYLIB" || {
        echo "dylib not found for host-isolation verification: $DYLIB" >&2
        exit 1
    }
    STRINGS_FILE="$(mktemp)"
    trap 'rm -f "$STRINGS_FILE"' EXIT
    strings -a "$DYLIB" > "$STRINGS_FILE"

    for marker in \
        "AllFLEXing no-global-catalog host-image runtime scanner ABI 1" \
        "AllFLEXing current-process Mach-O host isolation ABI 1" \
        "AllFLEXing host/image-scoped transient runtime bridge ABI 4"; do
        grep -Fq "$marker" "$STRINGS_FILE" || {
            echo "built dylib is missing marker: $marker" >&2
            exit 1
        }
    done

    if grep -Eq 'FBConfigManager|com\.burbn\.instagram|RyukGram' "$STRINGS_FILE"; then
        echo "built dylib contains a forbidden host-specific catalog marker" >&2
        exit 1
    fi
fi

echo "AllFLEXing current-host runtime isolation: OK"
