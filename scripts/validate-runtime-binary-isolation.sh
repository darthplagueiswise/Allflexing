#!/usr/bin/env bash

set -euo pipefail

dylib="${1:-}"
[ -n "$dylib" ] && [ -f "$dylib" ] || {
    echo "usage: $0 <AllFLEXing.dylib>" >&2
    exit 2
}

strings_dump="$(strings -a "$dylib")"

for marker in \
    "AllFLEXing host-scoped Keychain App Group persistence ABI 1" \
    "AllFLEXing no cross-host runtime catalog persistence ABI 1" \
    "AllFLEXing current-host image identity ABI 1"; do
    if ! grep -Fq "$marker" <<<"$strings_dump"; then
        echo "missing runtime-isolation marker: $marker" >&2
        exit 1
    fi
done

for forbidden in \
    "Instagram" \
    "RyukGram" \
    "com.burbn" \
    "FBSharedFramework"; do
    if grep -Fqi "$forbidden" <<<"$strings_dump"; then
        echo "fixed foreign-host identifier leaked into final dylib: $forbidden" >&2
        exit 1
    fi
done

echo "runtime binary host isolation validated"
