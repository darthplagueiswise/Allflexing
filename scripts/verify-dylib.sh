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
grep -Eq 'minos[[:space:]]+15\.0' <<<"$build_version" || {
    echo "error: minimum OS is not iOS 15.0" >&2
    exit 1
}

linked_libraries="$(otool -L "$dylib")"
if grep -Eiq 'CydiaSubstrate|ElleKit|libhooker|substitute' <<<"$linked_libraries"; then
    echo "error: external hook framework dependency detected" >&2
    exit 1
fi

load_commands="$(otool -l "$dylib")"
if grep -Eiq '/var/jb|\.jbroot' <<<"$load_commands"; then
    echo "error: jailbreak/rootless rpath detected" >&2
    exit 1
fi

symbols="$(nm -gj "$dylib")"
grep -q '_FLEXFlag' <<<"$symbols"
grep -q '_OBJC_CLASS_\$_FLEXHookPersistence' <<<"$symbols"
grep -q '_OBJC_CLASS_\$_FLEXLiquidGlass' <<<"$symbols"
grep -q '_OBJC_CLASS_\$_FLEXSymbolRebind' <<<"$symbols"

string_dump="$(strings "$dylib")"
grep -q 'UIGlassEffect' <<<"$string_dump"
grep -q 'UIGlassContainerEffect' <<<"$string_dump"
grep -q 'Hook Toggles' <<<"$string_dump"

echo "AllFLEXing Mach-O verification: OK"
