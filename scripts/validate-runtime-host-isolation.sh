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
    "AllFLEXing current-host whole-runtime scanner ABI 2"
require_source "$SCANNER" \
    "AllFLEXing exact-B Objective-C runtime classification ABI 1"
require_source "$ISOLATION" \
    "AllFLEXing current-process Mach-O host isolation ABI 1"
require_source "$BRIDGE" \
    "AllFLEXing host/image-scoped transient runtime bridge ABI 4"
require_source "$ISOLATION" 'locator[@"hostExecutableUUID"]'
require_source "$ISOLATION" 'locator[@"runtimeSessionImageUUID"]'
require_source "$BRIDGE" 'locator[@"hostBundleIdentifier"]'
require_source "$BRIDGE" 'locator[@"hostExecutableUUID"]'
require_source "$BRIDGE" 'FLEXBridgeObjectiveCClassMatchesImage'

# Whole-runtime discovery intentionally covers the current host's executable
# and embedded framework executables. Loose injected dylibs, extensions,
# plug-ins and files merely located under the .app are not application targets.
for token in \
    'objc_copyClassList' \
    'class_copyMethodList' \
    'S_LAZY_SYMBOL_POINTERS' \
    'S_NON_LAZY_SYMBOL_POINTERS' \
    'FLEXPathBelongsToCurrentHost(imagePath)' \
    'FLEXPathIsFrameworkExecutable' \
    'stringByAppendingPathComponent:@"Frameworks"' \
    'caseInsensitiveCompare:@"dylib"' \
    'FLEXUUIDForHeader(header)' \
    '@"mach-o-indirect-symbols-current-host"' \
    '@"abiEvidence": @"objc-type-encoding-exact-B"'; do
    require_source "$SCANNER" "$token"
done

python3 - "$SCANNER" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()
for selector, required in (
    (
        "scanObjectiveCRuntimeIncludingSystemImages",
        ("objc_copyClassList", "class_copyMethodList", "FLEXPathBelongsToCurrentHost"),
    ),
    (
        "scanCImportsIncludingSystemImages",
        ("_dyld_image_count", "S_LAZY_SYMBOL_POINTERS", "FLEXPathBelongsToCurrentHost"),
    ),
):
    match = re.search(
        rf"\+ \(void\){selector}:.*?(?=\n\+ \(|\n@end)",
        source,
        flags=re.S,
    )
    if not match:
        raise SystemExit(f"missing whole-runtime scanner API: {selector}")
    body = match.group(0)
    if "completion(@[])" in body:
        raise SystemExit(f"{selector} still returns a disabled empty catalog")
    for token in required:
        if token not in body:
            raise SystemExit(f"{selector} is missing current-host discovery token: {token}")

for token in ('@"image"', '@"imageUUID"', '@"source"'):
    if token not in source:
        raise SystemExit(f"runtime scanner does not stamp locator field: {token}")

path_filter = re.search(
    r"static BOOL FLEXPathBelongsToCurrentHost\(NSString \*path\).*?\n}",
    source,
    flags=re.S,
)
if not path_filter:
    raise SystemExit("current-host path filter was not found")
body = path_filter.group(0)
if "FLEXPathIsFrameworkExecutable" not in body:
    raise SystemExit("path filter no longer restricts non-main images to framework executables")
if "hasPrefix:prefix" in body or "bundlePath stringByAppendingString" in body:
    raise SystemExit("broad any-file-inside-app filter returned")

framework_filter = re.search(
    r"static BOOL FLEXPathIsFrameworkExecutable\(NSString \*path\).*?\n}",
    source,
    flags=re.S,
)
if not framework_filter:
    raise SystemExit("framework executable validator was not found")
framework_body = framework_filter.group(0)
for token in ("Frameworks", "framework", "dylib", "lastPathComponent"):
    if token not in framework_body:
        raise SystemExit(f"framework validator is missing: {token}")
PY

# Generic source only: no copied symbols/catalogs from a reference application.
if grep -RIEq \
    'FBConfigManager|com\.burbn\.instagram|RyukGram|Instagram[A-Z][A-Za-z0-9_]+' \
    "$ROOT/libflex/AllFLEXing" \
    --include='*.m' --include='*.mm' --include='*.x' --include='*.xm' \
    --include='*.c' --include='*.h'; then
    echo "host-specific Instagram/RyukGram catalog data found in runtime sources" >&2
    exit 1
fi

if find "$ROOT/libflex/AllFLEXing" -type f \
    \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' -o \
       -name '*.idx' -o -name '*.json' -o -name '*.mctable' -o \
       -name '*.meta' \) | grep -q .; then
    echo "pre-rendered runtime catalog found in AllFLEXing source tree" >&2
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
        "AllFLEXing current-host whole-runtime scanner ABI 2" \
        "AllFLEXing exact-B Objective-C runtime classification ABI 1" \
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

echo "AllFLEXing current-host executable/framework isolation: OK"
