#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import re

root = Path("libflex/AllFLEXing")
loader = (root / "AllFLEXingLoader.m").read_text()
store = (root / "FLEXPersistenceStore.m").read_text()
integration = (root / "FLEXPersistenceIntegration.m").read_text()
flags = (root / "FLEXHookPersistence.m").read_text()

errors = []

def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)

require("+ (void)load" not in store,
        "FLEXPersistenceStore must remain lazy and must not implement +load")
require("AllFLEXing post-scene lazy persistence ABI 1" in store,
        "missing lazy-persistence ABI marker")
require("AllFLEXing deferred coalesced persistence integration ABI 1" in integration,
        "missing coalesced persistence ABI marker")
require("AllFLEXing post-scene deferred runtime bootstrap ABI 1" in loader,
        "missing safe-launch loader ABI marker")
require("AllFLEXing post-mirror flag cache reload ABI 1" in flags,
        "missing post-restore flag reload marker")
require("synchronizeNow" not in integration,
        "high-frequency persistence integration must coalesce writes")
require("[FLEXHookRegistry.sharedRegistry bootstrap]" not in loader,
        "loader must not call synchronous registry bootstrap")
require("launch-reapply" not in loader,
        "loader must not request launch replay")
require(loader.count("reapplyPersistedEntries") == 1,
        "loader must request exactly one post-scene persisted-state replay")

load_match = re.search(
    r"\+ \(void\)load\s*\{(?P<body>.*?)\n\}",
    integration,
    re.S,
)
require(load_match is not None, "persistence integration +load not found")
if load_match:
    require("sharedStore" not in load_match.group("body"),
            "persistence integration +load must not instantiate the store")

ctor_match = re.search(
    r"__attribute__\(\(constructor\)\).*?AllFLEXingBootstrap\(void\)\s*\{(?P<body>.*?)\n\}",
    loader,
    re.S,
)
require(ctor_match is not None, "AllFLEXing constructor not found")
if ctor_match:
    body = ctor_match.group("body")
    forbidden = (
        "FLEXPersistenceStore",
        "FLEXHookRegistry",
        "FLEXRuntimeScanner",
        "reapplyPersistedEntries",
        "activateRegisteredHooks",
        "AllFLEXingRegisterRuntimeFlags",
    )
    for token in forbidden:
        require(token not in body,
                f"constructor performs forbidden pre-scene work: {token}")
    require("AllFLEXingScheduleActivationPhase" in body,
            "constructor must only schedule the active-scene phase")

deferred_match = re.search(
    r"static void AllFLEXingStartDeferredRuntime\(void\)\s*\{(?P<body>.*?)\n\}",
    loader,
    re.S,
)
require(deferred_match is not None, "deferred runtime phase not found")
if deferred_match:
    body = deferred_match.group("body")
    ordered = [
        "FLEXPersistenceStore.sharedStore",
        "AllFLEXingRegisterRuntimeFlags",
        "reloadPersistedValues",
        "activateRegisteredHooks",
        "FLEXHookRegistry.sharedRegistry",
        "reapplyPersistedEntries",
    ]
    positions = [body.find(token) for token in ordered]
    require(all(position >= 0 for position in positions),
            "deferred runtime phase is missing a required stage")
    require(positions == sorted(positions),
            "deferred runtime stages are not ordered restore → reload → activate → replay")

if errors:
    for error in errors:
        print(f"error: {error}")
    raise SystemExit(1)

print("AllFLEXing safe-launch source validation: OK")
PY
