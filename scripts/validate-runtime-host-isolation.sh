#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$ROOT/libflex/AllFLEXing/FLEXRuntimeScanner.m"
SESSION="$ROOT/libflex/AllFLEXing/FLEXRuntimeImageSession.mm"
REGISTRY="$ROOT/libflex/AllFLEXing/FLEXHookRegistry.m"

for file in "$SCANNER" "$SESSION" "$REGISTRY"; do
    test -f "$file" || {
        echo "missing consolidated host-isolation owner: $file" >&2
        exit 1
    }
done

for deleted in \
    FLEXRuntimeHostIsolation.m \
    FLEXRuntimeSnapshotRegistryBridge.m; do
    if test -e "$ROOT/libflex/AllFLEXing/$deleted"; then
        echo "collapsed host-isolation layer returned: $deleted" >&2
        exit 1
    fi
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
require_source "$SESSION" \
    "AllFLEXing complete selected-image runtime session ABI 2"
require_source "$SESSION" \
    "AllFLEXing current-process Mach-O host isolation ABI 2"
require_source "$REGISTRY" \
    "AllFLEXing host/image-scoped transient runtime bridge ABI 5"

for token in \
    'FLEXRuntimeMainExecutableHeader' \
    'header->filetype == MH_EXECUTE' \
    'FLEXRuntimePathIsFrameworkExecutable' \
    'caseInsensitiveCompare:@"dylib"' \
    'FLEXRuntimeCurrentDescriptor' \
    'FLEXRuntimeFinalizeSnapshot' \
    'locator[@"hostExecutableUUID"]' \
    'locator[@"runtimeSessionImageUUID"]' \
    'locator[@"runtimeSessionImagePath"]' \
    'objc_enumerateClasses'; do
    require_source "$SESSION" "$token"
done

for token in \
    'FLEXTransientRuntimeEntries' \
    'FLEXRegistryPrepareRuntimeEntry' \
    'FLEXRegistryEntryMatchesCurrentHost' \
    'FLEXRegistryObjectiveCClassMatchesImage' \
    'locator[@"hostBundleIdentifier"]' \
    'locator[@"hostExecutableUUID"]' \
    'locator[@"runtimeSnapshotPromoted"]'; do
    require_source "$REGISTRY" "$token"
done

# Whole-runtime scanner remains generic and scans only the main executable plus
# valid embedded framework executables. Loose injected dylibs are excluded.
for token in \
    'objc_copyClassList' \
    'class_copyMethodList' \
    'S_LAZY_SYMBOL_POINTERS' \
    'S_NON_LAZY_SYMBOL_POINTERS' \
    'FLEXPathBelongsToCurrentHost(imagePath)' \
    'FLEXPathIsFrameworkExecutable' \
    'caseInsensitiveCompare:@"dylib"' \
    '@"mach-o-indirect-symbols-current-host"'; do
    require_source "$SCANNER" "$token"
done

python3 - "$SCANNER" "$SESSION" "$REGISTRY" <<'PY'
from pathlib import Path
import re
import sys

scanner = Path(sys.argv[1]).read_text()
session = Path(sys.argv[2]).read_text()
registry = Path(sys.argv[3]).read_text()

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
        scanner,
        flags=re.S,
    )
    if not match:
        raise SystemExit(f"missing whole-runtime scanner API: {selector}")
    body = match.group(0)
    if "completion(@[])" in body:
        raise SystemExit(f"{selector} still returns an empty catalog")
    for token in required:
        if token not in body:
            raise SystemExit(f"{selector} missing live-host discovery: {token}")

path_filter = re.search(
    r"static BOOL FLEXPathBelongsToCurrentHost\(NSString \*path\).*?\n}",
    scanner,
    flags=re.S,
)
if not path_filter or "FLEXPathIsFrameworkExecutable" not in path_filter.group(0):
    raise SystemExit("whole-runtime scanner no longer restricts secondary images to framework executables")
if "bundlePath stringByAppendingString" in path_filter.group(0):
    raise SystemExit("broad any-file-inside-app filter returned")

if "NSMapTable strongToWeakObjectsMapTable" not in registry:
    raise SystemExit("transient runtime rows are no longer weakly owned")
if "runtimeSnapshotPromoted" not in registry:
    raise SystemExit("explicit transient promotion marker is missing")
if "FLEXRuntimeLoadedHostImages" not in session:
    raise SystemExit("session no longer owns loaded current-host image discovery")
PY

if grep -RIEq \
    'FBConfigManager|com\.burbn\.instagram|RyukGram|Instagram[A-Z][A-Za-z0-9_]+' \
    "$ROOT/libflex/AllFLEXing" \
    --include='*.m' --include='*.mm' --include='*.x' --include='*.xm' \
    --include='*.c' --include='*.h'; then
    echo "host-specific catalog data found in runtime sources" >&2
    exit 1
fi

if find "$ROOT/libflex/AllFLEXing" -type f \
    \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' -o \
       -name '*.idx' -o -name '*.json' -o -name '*.mctable' -o \
       -name '*.meta' \) | grep -q .; then
    echo "pre-rendered runtime catalog found in source tree" >&2
    exit 1
fi

if [[ $# -ge 1 ]]; then
    DYLIB="$1"
    test -f "$DYLIB" || {
        echo "dylib not found: $DYLIB" >&2
        exit 1
    }
    STRINGS_FILE="$(mktemp)"
    trap 'rm -f "$STRINGS_FILE"' EXIT
    strings -a "$DYLIB" > "$STRINGS_FILE"
    for marker in \
        "AllFLEXing current-host whole-runtime scanner ABI 2" \
        "AllFLEXing exact-B Objective-C runtime classification ABI 1" \
        "AllFLEXing complete selected-image runtime session ABI 2" \
        "AllFLEXing current-process Mach-O host isolation ABI 2" \
        "AllFLEXing host/image-scoped transient runtime bridge ABI 5"; do
        grep -Fq "$marker" "$STRINGS_FILE" || {
            echo "built dylib is missing marker: $marker" >&2
            exit 1
        }
    done
    if grep -Eq 'FBConfigManager|com\.burbn\.instagram|RyukGram' "$STRINGS_FILE"; then
        echo "built dylib contains forbidden host-specific data" >&2
        exit 1
    fi
fi

echo "AllFLEXing session/registry current-host isolation: OK"
