#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path

root = Path("libflex/AllFLEXing")
loader = (root / "AllFLEXingLoader.m").read_text()
workspace = (root / "FLEXHookWorkspaceController.m").read_text()
browser = (root / "FLEXRuntimeBrowserController.m").read_text()
session = (root / "FLEXRuntimeImageSession.mm").read_text()
errors = []


def require(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""
    opening = source.find("{", start)
    if opening < 0:
        return ""
    depth = 0
    for index in range(opening, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    return ""


# Tapping the FLEX entry must present UIKit before Keychain, registry, scanner,
# providers or persisted hook replay can block/crash the activation path.
action = loader.find('registerGlobalEntryWithName:@"AllFLEXing Runtime Workspace"')
present = loader.find("presentDeterministicallyFromViewController:origin", action)
activate = loader.find("AllFLEXingActivateRuntimeForWorkspace(nil)", action)
require(action >= 0, "Runtime Workspace menu entry is missing")
require(present > action, "Workspace presentation is missing from menu action")
require(activate > present, "runtime activation starts before Workspace presentation")
require("AllFLEXing UI-first user-invoked runtime activation ABI 2" in loader,
        "UI-first loader ABI marker is missing")
require("AllFLEXing UI-first Runtime Workspace presentation ABI 2" in workspace,
        "UI-first Workspace ABI marker is missing")
for token in (
    "gFLEXWorkspaceOwnedWindow",
    "presentInOwnedWindowFrom:",
    "FLEXWorkspaceForegroundScene",
    "FLEXWorkspaceTearDownOwnedWindow",
):
    require(token in workspace, f"owned-window fallback is incomplete: {token}")

# The Browser must first become visible and only then start a selected-image
# scan. Wiring a Refresh button to @selector(reloadScan) is allowed in
# viewDidLoad; actually sending [self reloadScan] there is not.
view_did_load = method_body(browser, "- (void)viewDidLoad")
view_did_appear = method_body(browser, "- (void)viewDidAppear:(BOOL)animated")
require(view_did_load, "Runtime Browser viewDidLoad is missing")
require(view_did_appear, "Runtime Browser viewDidAppear is missing")
require("[self reloadScan]" not in view_did_load,
        "Runtime Browser still starts its scan from viewDidLoad")
require("[self reloadScan]" in view_did_appear,
        "Runtime Browser no longer starts its lazy first scan")
require("initialScanStarted" in browser,
        "Runtime Browser has no first-scan idempotence guard")

# Snapshot rows must be reduced to operational targets before they enter the
# transient registry or search posting lists.
projection = browser.find("FLEXRuntimeOperationalProjection(self.kind, snapshot.entries)")
upsert = browser.find("[registry upsertDiscoveredEntry:entry]", projection)
build_index = browser.find("[self buildSearchIndexForEntries:entries.copy]", upsert)
require(projection >= 0 and upsert > projection and build_index > upsert,
        "snapshot projection/registry/index ordering regressed")

# All offsets into Mach-O tables are rejected unless they fit __LINKEDIT.
require("AllFLEXing bounded LINKEDIT scanner and compact function-start ABI 1" in session,
        "bounded scanner ABI marker is missing")
for token in (
    "FLEXRuntimeFileRangeWithinLinkedit",
    "FLEXRuntimeStringFromTable",
    "strnlen(table + index, maximum)",
    "commandsEnd = cursor + header->sizeofcmds",
    "symbolOverflow",
    "indirectOverflow",
    "Indexing compact function starts",
):
    require(token in session, f"bounded Mach-O scanner is missing: {token}")
require("stringWithUTF8String:strings + stringIndex" not in session,
        "unbounded Mach-O string-table read returned")
require('entry.title = [NSString stringWithFormat:@"sub_%llx"' not in session,
        "anonymous LC_FUNCTION_STARTS rows are materialized again")
require("NSMutableArray<NSNumber *> *starts" not in session,
        "all function starts are retained in a Foundation array again")

if errors:
    for error in errors:
        print(f"error: {error}")
    raise SystemExit(1)

print("AllFLEXing UI-first Workspace and bounded Runtime Browser: OK")
PY
