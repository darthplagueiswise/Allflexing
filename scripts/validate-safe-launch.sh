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
host_isolation = (root / "FLEXRuntimeHostIsolation.m").read_text()
bridge = (root / "FLEXRuntimeSnapshotRegistryBridge.m").read_text()
session = (root / "FLEXRuntimeImageSession.mm").read_text()
makefile = Path("libflex/Makefile").read_text()
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


require("+ (void)load" not in store,
        "FLEXPersistenceStore must remain lazy and must not implement +load")
require("AllFLEXing read-only persistence discovery ABI 1" in store,
        "missing read-only persistence discovery ABI marker")
require("AllFLEXing deferred coalesced persistence integration ABI 1" in integration,
        "missing coalesced persistence ABI marker")
require("AllFLEXing post-scene UI-only bootstrap ABI 2" in loader,
        "missing UI-only safe-launch marker")
require("AllFLEXing user-invoked runtime activation ABI 1" in loader,
        "missing user-invoked runtime activation marker")
require("AllFLEXing upstream FLEX automatic constructors disabled ABI 1" in loader,
        "missing upstream FLEX constructor policy marker")
require("-DFLEX_DISABLE_CTORS=1" in makefile,
        "upstream FLEX automatic constructors must be disabled at compile time")
require("AllFLEXing post-mirror flag cache reload ABI 1" in flags,
        "missing post-restore flag reload marker")
require("synchronizeNow" not in integration,
        "high-frequency persistence integration must coalesce writes")
require("[FLEXHookRegistry.sharedRegistry bootstrap]" not in all_sources,
        "no source may invoke the synchronous registry bootstrap")
require("launch-reapply" not in loader,
        "loader must not request legacy launch replay")
require(loader.count("reapplyPersistedEntries") == 1,
        "persisted-state replay must exist only in the user-invoked activation path")

# Runtime rows must be reconstructed from the current process and exact selected
# Mach-O image. A generated database, serialized catalog or reference-binary
# index is never a valid runtime source.
require("AllFLEXing current-process Mach-O host isolation ABI 1" in host_isolation,
        "missing current-host runtime isolation marker")
require("header->filetype == MH_EXECUTE" in host_isolation,
        "main executable must be identified from the live Mach-O header")
require("hostExecutableUUID" in host_isolation and
        "runtimeSessionImageUUID" in host_isolation and
        "runtimeSessionImagePath" in host_isolation,
        "runtime entries are not stamped with host and image identity")
require("class_getImageName" in host_isolation,
        "Objective-C rows are not verified against their live defining image")
require("AllFLEXing host/image-scoped transient runtime bridge ABI 3" in bridge,
        "missing host/image-scoped registry bridge marker")
require("AllFLEXing transient runtime snapshot bridge ABI 2 registry-only" not in bridge,
        "obsolete process-global snapshot bridge is still present")
for token in (
    "af_host_entryForIdentifier:",
    "af_host_entries",
    "af_host_reapplyPersistedEntries",
    "runtimeSnapshotPromoted",
):
    require(token in bridge, f"runtime registry isolation is missing: {token}")
require("objc_enumerateClasses" in session and "_dyld_image_count" in session,
        "runtime session must enumerate live process metadata")

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

# Parse complete Objective-C method/constructor bodies by balanced braces. The
# old non-greedy regex could run past +load into later methods and report a hook
# replay that was not actually inside +load.
for path in source_files:
    text = path.read_text(errors="replace")
    for body in bodies_matching(text, r"\+\s*\(void\)load\s*\{"):
        require("FLEXPersistenceStore.sharedStore" not in body,
                f"{path} instantiates persistence from +load")
        require("reapplyPersistedEntries" not in body,
                f"{path} replays hooks from +load")
        require("FLEXHookRegistry.sharedRegistry bootstrap" not in body,
                f"{path} bootstraps the registry from +load")

    for body in bodies_matching(
        text,
        r"__attribute__\s*\(\(constructor\)\).*?\([^;{}]*\)\s*\{",
    ):
        for token in (
            "FLEXPersistenceStore.sharedStore",
            "reapplyPersistedEntries",
            "FLEXHookRegistry.sharedRegistry bootstrap",
            "FLEXRuntimeScanner startMonitoringImages",
            "activateRegisteredHooks",
        ):
            require(token not in body,
                    f"{path} constructor performs forbidden startup work: {token}")

integration_load_bodies = bodies_matching(
    integration,
    r"\+\s*\(void\)load\s*\{",
)
require(bool(integration_load_bodies), "persistence integration +load not found")
for body in integration_load_bodies:
    require("sharedStore" not in body,
            "persistence integration +load must not instantiate the store")

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
            "constructor must only schedule the active-scene phase")

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
            "user-invoked runtime activation is missing a required stage")
    require(positions == sorted(positions),
            "runtime stages are not ordered restore → reload → activate → monitor → replay")

start_ui_body = function_body(loader, "static void AllFLEXingStartUI(void)")
require(start_ui_body, "UI bootstrap function not found")
if start_ui_body:
    require("AllFLEXingActivateRuntimeForWorkspace" in start_ui_body,
            "Runtime Workspace action must invoke lazy runtime activation")
    for token in (
        "FLEXPersistenceStore.sharedStore",
        "FLEXHookRegistry.sharedRegistry",
        "FLEXRuntimeScanner startMonitoringImages",
        "reapplyPersistedEntries",
        "activateRegisteredHooks",
    ):
        require(token not in start_ui_body,
                f"UI bootstrap performs forbidden runtime work: {token}")

store_init = function_body(store, "- (instancetype)init")
require(store_init, "persistence store initializer not found")
if store_init:
    for token in (
        "[self synchronizeSoon]",
        "performSynchronization",
        "freshSnapshot",
        "setDouble:",
        "setObject:",
        "removeObjectForKey:",
        "createDirectoryAtURL:",
        "writeToURL:",
        "write-probe",
    ):
        require(token not in store_init,
                f"persistence initializer is not read-only: {token}")

configure_group = function_body(store, "- (void)configureApplicationGroup")
require(configure_group, "application-group discovery function not found")
if configure_group:
    for token in ("createDirectoryAtURL:", "writeToURL:", "write-probe"):
        require(token not in configure_group,
                f"application-group discovery performs a write: {token}")

sandbox_url = function_body(store, "- (NSURL *)createSandboxMirrorURL")
require(sandbox_url, "sandbox mirror URL function not found")
if sandbox_url:
    require("createDirectoryAtURL:" not in sandbox_url,
            "sandbox mirror discovery must not create directories")

write_snapshot = function_body(
    store,
    "- (BOOL)writeSnapshot:(NSDictionary *)snapshot toURL:(NSURL *)URL error:(NSError **)error",
)
require(write_snapshot, "snapshot writer not found")
if write_snapshot:
    require("createDirectoryAtURL:" in write_snapshot,
            "directory creation must be deferred to the explicit snapshot writer")
    require("writeToURL:" in write_snapshot,
            "snapshot writer no longer writes atomically")

if errors:
    for error in errors:
        print(f"error: {error}")
    raise SystemExit(1)

print("AllFLEXing inert-launch and current-host runtime validation: OK")
PY
