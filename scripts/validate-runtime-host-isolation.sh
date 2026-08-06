#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/libflex/AllFLEXing"
registry="$src/FLEXHookRegistry.m"
scanner="$src/FLEXRuntimeScanner.m"
loader="$src/AllFLEXingLoader.m"
identity="$src/FLEXRuntimeHostIdentity.m"
store="$src/FLEXPersistenceStore.m"

for forbidden in 'com.burbn.instagram' 'RyukGram' 'Instagram.app' 'FBSharedFramework'; do
    if grep -RIl --include='*.m' --include='*.mm' --include='*.h' --include='*.c' \
        "$forbidden" "$src" | grep -q .; then
        echo "forbidden host-specific catalogue marker: $forbidden" >&2
        exit 1
    fi
done

if find "$src" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.idx' \
    -o -name '*.mctable' -o -name '*.meta' -o -name '*.json' \) | grep -q .; then
    echo 'embedded runtime catalogue/data file found' >&2
    exit 1
fi

grep -q 'com.allflexing.registry.v2.' "$registry"
grep -q 'hostBundleIdentifier' "$registry"
grep -q 'hostExecutableUUID' "$registry"
grep -q 'if (!entry.desiredEnabled' "$registry"
grep -q 'FLEXLocatorMatchesCurrentHost' "$registry"
grep -q 'removeObjectForKey:kFLEXHookRegistryLegacyStorageKey' "$registry"

grep -q 'FLEXRuntimeImageIsAllowedHostImage' "$scanner"
grep -q 'Plain injected dylibs' "$identity"
grep -q 'pathExtension caseInsensitiveCompare:@"framework"' "$identity"

grep -q 'hasPersistedConfirmedEntries' "$loader"
grep -q 'AllFLEXingReArmConfirmedHooksAtLaunch' "$loader"
grep -q 'no Apply-confirmed hooks for this host' "$loader"

grep -q 'no cross-host runtime catalog persistence ABI 1' "$store"
grep -q 'kFLEXLegacyRegistryKey' "$store"
grep -q 'snapshot\[@"host"\].*self.hostScope' "$store"

echo 'runtime host isolation and Apply-confirmed persistence validated'
