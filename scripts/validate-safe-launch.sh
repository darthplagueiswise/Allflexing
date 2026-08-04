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
session = (root / "FLEXRuntimeImageSession.mm").read_text()
browser = (root / "FLEXRuntimeBrowserController.m").read_text()
hook_center = (root / "FLEXHookToggles.m").read_text()
detail = (root / "FLEXHookEntryDetailController.m").read_text()
actions = (root / "FLEXRuntimeHookActions.m").read_text()
workspace = (root / "FLEXHookWorkspaceController.m").read_text()
glass = (root / "FLEXLiquidGlass.m").read_text()
makefile = Path("libflex/Makefile").read_text()
runtime_module = Path("libflex/modules/HookRuntime/Module.mk").read_text()
ui_module = Path("libflex/modules/LiquidGlassUI/Module.mk").read_text()
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
        opening = source.find("{", match.start(), match.end())
        body = brace_body(source, opening)
        if body:
            bodies.append(body)
    return bodies


# The former method-replacement layers are gone. Their unique behavior must be
# physically owned by the concrete session, registry and controllers.
collapsed = {
    "FLEXRuntimeHostIsolation.m": session,
    "FLEXRuntimeSnapshotRegistryBridge.m": registry,
    "FLEXStableRuntimeController.m": browser,
    "FLEXDeferredApplyPolicy.m": hook_center + detail + actions,
    "FLEXCompactRuntimeControllers.m": browser + hook_center + detail,
    "FLEXPersistenceIntegration.m": store + flags,
    "FLEXStrictObjectiveCRuntimeScanner.m": (root / "FLEXRuntimeScanner.m").read_text(),
}
for filename, owner in collapsed.items():
    require(not (root / filename).exists(), f"collapsed layer returned: {filename}")
    require(filename not in runtime_module and filename not in ui_module,
            f"collapsed layer remains in a module manifest: {filename}")
    require(bool(owner), f"owner content missing after collapse: {filename}")

for token in (
    "FLEXRuntimeHostIsolation",
    "FLEXRuntimeSnapshotRegistryBridge",
    "FLEXStableRuntimeController",
    "FLEXDeferredApplyPolicy",
    "FLEXCompactRuntimeControllers",
):
    require(token not in runtime_module and token not in ui_module,
            f"obsolete layer token remains in manifests: {token}")

# Owner markers and contracts.
for source, marker in (
    (session, "AllFLEXing complete selected-image runtime session ABI 2"),
    (session, "AllFLEXing current-process Mach-O host isolation ABI 2"),
    (registry, "AllFLEXing host/image-scoped transient runtime bridge ABI 5"),
    (browser, "AllFLEXing single-owner type-safe runtime controller ABI 2"),
    (browser, "AllFLEXing complete-image substring-index search ABI 1"),
    (browser, "AllFLEXing operational Objective-C hook-target projection ABI 1"),
    (hook_center, "AllFLEXing staged toggles explicit-Apply-only ABI 2"),
    (hook_center, "AllFLEXing owner-native compact runtime controllers ABI 1"),
    (glass, "AllFLEXing native UIKit 26 Liquid Glass and scroll-edge ABI 2"),
    (workspace, "AllFLEXing UI-first Runtime Workspace presentation ABI 2"),
):
    require(marker in source, f"missing consolidated owner marker: {marker}")

# No owner may install itself by replacing methods at image load.
for path in (
    root / "FLEXRuntimeImageSession.mm",
    root / "FLEXHookRegistry.m",
    root / "FLEXRuntimeBrowserController.m",
    root / "FLEXHookToggles.m",
    root / "FLEXHookEntryDetailController.m",
    root / "FLEXHookWorkspaceController.m",
):
    text = path.read_text(errors="replace")
    require("+ (void)load" not in text, f"owner still installs from +load: {path}")
    for forbidden in (
        "method_exchangeImplementations",
        "method_setImplementation",
        "class_replaceMethod",
    ):
        require(forbidden not in text,
                f"owner still replaces methods ({forbidden}): {path}")

# Staged-only user controls. Only explicitly named Apply paths may physically
# install. Browser, Hook Center, detail switches and metadata switches cannot
# call applyEntryIdentifier from their change handlers.
for source, signature in (
    (browser, "- (void)toggleChanged:(UISwitch *)toggle"),
    (hook_center, "- (void)hookToggleChanged:(UISwitch *)toggle"),
    (detail, "- (void)enabledChanged:(UISwitch *)toggle"),
    (actions, "- (void)switchChanged:(UISwitch *)toggle"),
):
    body = function_body(source, signature)
    require(body, f"staged switch handler missing: {signature}")
    if body:
        require("applyEntryIdentifier" not in body and
                "applyPendingWithCompletion" not in body,
                f"switch physically applies instead of staging: {signature}")
        require("stageEnabled" in body,
                f"switch no longer stages desired state: {signature}")
require("Apply This Hook" in actions,
        "context menu has no explicit per-hook Apply action")
require("No patch, swizzle or hook is installed until Apply is pressed" in hook_center,
        "Hook Center no longer explains the explicit Apply contract")

# Workspace presentation happens directly on the host FLEX controller — the
# known-good path that also works inside UIDesignRequiresCompatibility hosts.
# The owned-UIWindow / scene-resolution / retry machinery was removed because
# constructing a UIWindow in that legacy compatibility mode hung the menu.
require("host presentViewController:workspace" in loader and
        "completion:" in loader,
        "loader does not present the Workspace directly on the host")
require("__weak UITableViewController *weakHost" not in loader,
        "loader still captures a stale weak host")
# Runtime activation must still be deferred until the sheet is visible (inside
# the presentation completion), never at launch.
require("AllFLEXingActivateRuntimeForWorkspace" in loader,
        "loader does not defer runtime activation to the presentation completion")

# Launch remains inert. Runtime and persistence initialization are allowed only
# inside the user-invoked Runtime Workspace activation function.
require("AllFLEXing post-scene UI-only bootstrap ABI 2" in loader,
        "missing UI-only launch marker")
require("AllFLEXing UI-first user-invoked runtime activation ABI 2" in loader,
        "missing user-invoked runtime marker")
require("-DFLEX_DISABLE_CTORS=1" in makefile,
        "upstream FLEX constructors are not disabled")
ctor = function_body(loader, "static void AllFLEXingBootstrap(void)")
require(ctor, "AllFLEXing constructor missing")
if ctor:
    # The constructor itself must not do runtime work inline; it may only
    # schedule the UI phase and delegate confirmed-hook re-arming to the
    # dedicated launch re-arm function (validated separately below).
    for token in (
        "FLEXPersistenceStore",
        "FLEXHookRegistry",
        "FLEXRuntimeScanner",
        "reapplyPersistedEntries",
        "activateRegisteredHooks",
    ):
        require(token not in ctor, f"constructor performs runtime work inline: {token}")
    require("AllFLEXingScheduleActivationPhase" in ctor,
            "constructor no longer schedules the active-scene UI phase")
    require("AllFLEXingReArmConfirmedHooksAtLaunch" in ctor,
            "constructor no longer re-arms confirmed hooks at launch")

# Launch re-arm restores ONLY previously-confirmed hooks and is gated on a cheap
# probe so a first run with nothing confirmed stays fully inert (no registry, no
# persistence store, no scanner built at launch).
launch_rearm = function_body(
    loader,
    "static void AllFLEXingReArmConfirmedHooksAtLaunch(void)",
)
require(launch_rearm, "launch re-arm function missing")
if launch_rearm:
    require("hasPersistedConfirmedEntries" in launch_rearm,
            "launch re-arm does not gate on the confirmed-entries probe")
    require("reapplyPersistedEntries" in launch_rearm,
            "launch re-arm does not replay confirmed hooks")
    # The probe must be checked before any store/registry is touched, so the
    # inert first-run path builds nothing.
    require(launch_rearm.find("hasPersistedConfirmedEntries")
                < launch_rearm.find("FLEXPersistenceStore.sharedStore"),
            "launch re-arm builds persistence before probing for confirmed entries")

runtime_activation = function_body(
    loader,
    "static void AllFLEXingActivateRuntimeForWorkspace(dispatch_block_t completion)",
)
require(runtime_activation, "user-invoked runtime activation missing")
if runtime_activation:
    ordered = [
        "FLEXPersistenceStore.sharedStore",
        "AllFLEXingRegisterRuntimeFlags",
        "reloadPersistedValues",
        "activateRegisteredHooks",
        "FLEXHookRegistry.sharedRegistry",
        "[registry bootstrap]",
        "reapplyPersistedEntries",
    ]
    positions = [runtime_activation.find(token) for token in ordered]
    require(all(position >= 0 for position in positions),
            "runtime activation lost a required stage")
    require(positions == sorted(positions),
            "runtime activation order changed")

for path in source_files:
    text = path.read_text(errors="replace")
    for body in bodies_matching(text, r"\+\s*\(void\)load\s*\{"):
        require("FLEXPersistenceStore.sharedStore" not in body,
                f"{path} initializes persistence from +load")
        require("SecItem" not in body,
                f"{path} accesses Keychain from +load")
        require("reapplyPersistedEntries" not in body,
                f"{path} replays runtime state from +load")
    for body in bodies_matching(
        text,
        r"__attribute__\s*\(\(constructor\)\).*?\([^;{}]*\)\s*\{",
    ):
        require("SecItem" not in body,
                f"{path} accesses Keychain from a constructor")

# Keychain and generic-host identity contract remains intact.
for token in (
    "SecItemCopyMatching",
    "SecItemUpdate",
    "SecItemAdd",
    "kSecAttrAccessibleAfterFirstUnlock",
    "SecTaskCopyValueForEntitlement",
    "com.apple.security.application-groups",
):
    require(token in store, f"Keychain/App Group contract missing: {token}")
for forbidden in (
    "com.burbn.instagram",
    "RyukGram",
    "4H2JG7AR6U.",
    "TEAMID.",
):
    require(forbidden not in all_sources,
            f"fixed host/team identity returned: {forbidden}")

# Runtime rows come only from live current-host executable/framework images.
require("AllFLEXing bounded LINKEDIT scanner and compact function-start ABI 1" in session,
        "bounded Mach-O scanner marker is missing")
require("stringWithUTF8String:strings + stringIndex" not in session,
        "unbounded Mach-O string-table read returned")
require("sub_%llx" not in session,
        "anonymous LC_FUNCTION_STARTS entries are materialized again")

for token in (
    "FLEXRuntimePathBelongsToCurrentHost",
    "FLEXRuntimePathIsFrameworkExecutable",
    "objc_enumerateClasses",
    "hostExecutableUUID",
    "runtimeSessionImageUUID",
    "runtimeSessionImagePath",
):
    require(token in session or token in registry,
            f"live host/image isolation missing: {token}")

forbidden_catalog_suffixes = {
    ".db", ".sqlite", ".sqlite3", ".idx", ".mctable", ".meta", ".json",
}
embedded_catalogs = [
    path for path in root.rglob("*")
    if path.is_file() and path.suffix.lower() in forbidden_catalog_suffixes
]
require(not embedded_catalogs,
        "pre-rendered runtime catalogs are forbidden: " +
        ", ".join(str(path) for path in embedded_catalogs))

if errors:
    for error in errors:
        print(f"error: {error}")
    raise SystemExit(1)

print("AllFLEXing owner consolidation, inert launch, staged Apply and Workspace presentation: OK")
PY
