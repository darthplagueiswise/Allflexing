#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import re

root = Path("libflex/AllFLEXing")
loader = (root / "AllFLEXingLoader.m").read_text()
store = (root / "FLEXPersistenceStore.m").read_text()
flags = (root / "FLEXHookPersistence.m").read_text()
registry = (root / "FLEXHookRegistry.m").read_text()
host_isolation = (root / "FLEXRuntimeHostIsolation.m").read_text()
bridge = (root / "FLEXRuntimeSnapshotRegistryBridge.m").read_text()
session = (root / "FLEXRuntimeImageSession.mm").read_text()
makefile = Path("libflex/Makefile").read_text()
module = Path("libflex/modules/HookRuntime/Module.mk").read_text()
source_files = sorted(
    path for path in root.rglob("*")
    if path.suffix in {".m", ".mm", ".xm", ".x"}
)
all_sources = "\n".join(path.read_text(errors="replace") for path in source_files)
errors = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def brace_body(source: str, opening_brace: int) -> str:
    if opening_brace < 0 or opening_brace >= len(source) or source[opening_brace] != "{":
        return ""
    depth = 0
    for index in range(opening_brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[opening_brace + 1:index]
    return ""


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""
    return brace_body(source, source.find("{", start))


def bodies_matching(source: str, pattern: str) -> list[str]:
    bodies = []
    for match in re.finditer(pattern, source, re.S):
        opening_brace = source.find("{", match.start(), match.end())
        body = brace_body(source, opening_brace)
        if body:
            bodies.append(body)
    return bodies


def sends_objc_message(body: str, selector: str) -> bool:
    pattern = r"\[[^\[\]]+\s+" + re.escape(selector) + r"\s*(?::|\])"
    return re.search(pattern, body, re.S) is not None


# Consolidated persistence contract.
require(not (root / "FLEXPersistenceIntegration.m").exists(),
        "legacy persistence swizzle layer must remain deleted")
require(not (root / "FLEXStrictObjectiveCRuntimeScanner.m").exists(),
        "duplicated strict Objective-C scanner must remain deleted")
require("FLEXPersistenceIntegration.m" not in module,
        "deleted persistence integration remains in HookRuntime manifest")
require("FLEXStrictObjectiveCRuntimeScanner.m" not in module,
        "deleted strict scanner remains in HookRuntime manifest")
require("+ (void)load" not in store,
        "FLEXPersistenceStore must remain lazy and must not implement +load")
require("AllFLEXing read-only persistence discovery ABI 1" in store,
        "missing lazy/read-only discovery ABI marker")
require("AllFLEXing confirmed-state Keychain App Group mirror ABI 1" in store,
        "missing confirmed-state Keychain persistence marker")
for token in (
    "SecItemCopyMatching",
    "SecItemUpdate",
    "SecItemAdd",
    "kSecAttrAccessibleAfterFirstUnlock",
    "SecTaskCopyValueForEntitlement",
    "com.apple.security.application-groups",
    "keychainAccessGroup = identifier",
    "writeKeychainData:data accessGroup:nil",
):
    require(token in store, f"Keychain/App Group contract is missing: {token}")
require("FLEXPersistenceStore.sharedStore synchronizeSoon" in flags,
        "flag owner no longer commits settings through the persistence store")
require("return FLEXPersistenceStore.sharedStore.storageDescription" in flags,
        "flag owner no longer exposes the consolidated storage backend")
require("apply-finish" in store and "runtime-toggle-applied" in store,
        "registry confirmed-state reasons are not persisted")

# The dylib must stay generic. Access groups and host identity are discovered
# from the effective signature/process, never compiled for one IPA or team.
for forbidden in (
    "com.burbn.instagram",
    "RyukGram",
    "4H2JG7AR6U.",
    "TEAMID.",
):
    require(forbidden not in store,
            f"persistence contains a fixed host/team identity: {forbidden}")
require("_keychainAccount = _hostScope" in store,
        "Keychain account must be scoped dynamically to the current host")

# Launch remains UI-only; persistence is created only after explicit Workspace
# activation. Keychain calls are synchronous APIs and therefore stay on the
# serial persistence queue, never inside +load/constructors or scene creation.
require("AllFLEXing post-scene UI-only bootstrap ABI 2" in loader,
        "missing UI-only safe-launch marker")
require("AllFLEXing user-invoked runtime activation ABI 1" in loader,
        "missing user-invoked runtime activation marker")
require("AllFLEXing upstream FLEX automatic constructors disabled ABI 1" in loader,
        "missing upstream FLEX constructor policy marker")
require("-DFLEX_DISABLE_CTORS=1" in makefile,
        "upstream FLEX automatic constructors must be disabled")
require("[FLEXHookRegistry.sharedRegistry bootstrap]" not in all_sources,
        "no source may invoke the synchronous registry bootstrap")
require("launch-reapply" not in loader,
        "loader must not request legacy launch replay")
require(loader.count("reapplyPersistedEntries") == 1,
        "persisted replay must exist only in user-invoked runtime activation")

for path in source_files:
    text = path.read_text(errors="replace")
    for body in bodies_matching(text, r"\+\s*\(void\)load\s*\{"):
        require("FLEXPersistenceStore.sharedStore" not in body,
                f"{path} instantiates persistence from +load")
        require("SecItem" not in body,
                f"{path} accesses Keychain from +load")
        require(not sends_objc_message(body, "reapplyPersistedEntries"),
                f"{path} replays hooks from +load")
        require("FLEXHookRegistry.sharedRegistry bootstrap" not in body,
                f"{path} bootstraps registry from +load")

    for body in bodies_matching(
        text,
        r"__attribute__\s*\(\(constructor\)\).*?\([^;{}]*\)\s*\{",
    ):
        for token in (
            "FLEXPersistenceStore.sharedStore",
            "SecItem",
            "reapplyPersistedEntries",
            "FLEXHookRegistry.sharedRegistry bootstrap",
            "FLEXRuntimeScanner startMonitoringImages",
            "activateRegisteredHooks",
        ):
            require(token not in body,
                    f"{path} constructor performs forbidden startup work: {token}")

ctor_body = function_body(loader, "static void AllFLEXingBootstrap(void)")
require(ctor_body, "AllFLEXing constructor not found")
if ctor_body:
    for token in (
        "FLEXPersistenceStore",
        "FLEXHookRegistry",
        "FLEXRuntimeScanner",
        "reapplyPersistedEntries",
        "activateRegisteredHooks",
        "AllFLEXingRegisterRuntimeFlags",
    ):
        require(token not in ctor_body,
                f"constructor performs forbidden pre-scene work: {token}")
    require("AllFLEXingScheduleActivationPhase" in ctor_body,
            "constructor must only schedule active-scene UI attachment")

activation_body = function_body(loader, "static void AllFLEXingRunActivationPhase(void)")
require(activation_body, "post-scene activation phase not found")
if activation_body:
    require("AllFLEXingStartUI" in activation_body,
            "post-scene activation must attach only the UI")
    for token in (
        "FLEXPersistenceStore",
        "FLEXHookRegistry",
        "FLEXRuntimeScanner",
        "reapplyPersistedEntries",
        "activateRegisteredHooks",
    ):
        require(token not in activation_body,
                f"post-scene activation performs forbidden runtime work: {token}")

runtime_body = function_body(
    loader,
    "static void AllFLEXingActivateRuntimeForWorkspace(dispatch_block_t completion)",
)
require(runtime_body, "user-invoked runtime activation function not found")
if runtime_body:
    ordered = [
        "FLEXPersistenceStore.sharedStore",
        "AllFLEXingRegisterRuntimeFlags",
        "reloadPersistedValues",
        "activateRegisteredHooks",
        "FLEXHookRegistry.sharedRegistry",
        "FLEXRuntimeScanner startMonitoringImages",
        "reapplyPersistedEntries",
    ]
    positions = [runtime_body.find(token) for token in ordered]
    require(all(position >= 0 for position in positions),
            "Workspace activation is missing a required runtime stage")
    require(positions == sorted(positions),
            "runtime stages are not ordered restore → reload → activate → monitor → replay")

# Host/image isolation remains live-data based, never a serialized catalog.
require("AllFLEXing current-process Mach-O host isolation ABI 1" in host_isolation,
        "missing selected-image host isolation marker")
require("hostExecutableUUID" in host_isolation and
        "runtimeSessionImageUUID" in host_isolation and
        "runtimeSessionImagePath" in host_isolation,
        "runtime entries are not stamped with live host/image provenance")
require("AllFLEXing host/image-scoped transient runtime bridge ABI 4" in bridge,
        "missing host/image-provenance registry bridge")
require("objc_enumerateClasses" in session and "_dyld_image_count" in session,
        "selected-image session must enumerate live process metadata")

forbidden_catalog_suffixes = {
    ".db", ".sqlite", ".sqlite3", ".idx", ".mctable", ".meta", ".json",
}
embedded_catalogs = [
    path for path in root.rglob("*")
    if path.is_file() and path.suffix.lower() in forbidden_catalog_suffixes
]
require(not embedded_catalogs,
        "pre-rendered runtime catalog files are forbidden: " +
        ", ".join(str(path) for path in embedded_catalogs))

if errors:
    for error in errors:
        print(f"error: {error}")
    raise SystemExit(1)

print("AllFLEXing inert launch, Keychain persistence and host isolation: OK")
PY
