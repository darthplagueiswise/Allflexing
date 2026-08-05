#!/usr/bin/env python3
"""Source contract for the crash-safe compact Objective-C hook browser."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOLVER = ROOT / "libflex/AllFLEXing/FLEXObjCHookResolver.m"
HEADER = ROOT / "libflex/AllFLEXing/FLEXHookableObjCRuntimeViewController.h"
CONTROLLER = ROOT / "libflex/AllFLEXing/FLEXHookableObjCRuntimeViewController.m"
MODULE = ROOT / "libflex/modules/HookRuntime/Module.mk"
TRANSFORMER = ROOT / "scripts/apply-flex-method-rendering-safety.py"
BUILD = ROOT / "build.sh"
OBSOLETE_EXPLORER_M = ROOT / "libflex/AllFLEXing/FLEXHookableObjectExplorerViewController.m"
OBSOLETE_EXPLORER_H = ROOT / "libflex/AllFLEXing/FLEXHookableObjectExplorerViewController.h"


def require(text: str, marker: str, label: str) -> None:
    if marker not in text:
        raise AssertionError(f"missing {label}: {marker}")


def forbid(text: str, marker: str, label: str) -> None:
    if marker in text:
        raise AssertionError(f"forbidden {label}: {marker}")


def selector_is_structurally_safe(selector: str, runtime_argument_count: int) -> bool:
    if runtime_argument_count < 2:
        return False
    return selector.count(":") == runtime_argument_count - 2


def body_for_void_method(text: str, selector: str) -> str:
    match = re.search(
        rf"- \(void\){re.escape(selector)}:\([^)]*\)[^{{]*\{{(.*?)\n\}}",
        text,
        re.S,
    )
    if not match:
        raise AssertionError(f"method body not found: {selector}:")
    return match.group(1)


def executable_code(text: str) -> str:
    """Remove comments before checking whether a forbidden call is executable."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def main() -> None:
    resolver = RESOLVER.read_text(encoding="utf-8")
    header = HEADER.read_text(encoding="utf-8")
    controller = CONTROLLER.read_text(encoding="utf-8")
    module = MODULE.read_text(encoding="utf-8")
    transformer = TRANSFORMER.read_text(encoding="utf-8")
    build = BUILD.read_text(encoding="utf-8")

    assert selector_is_structurally_safe("isEnabled", 2)
    assert selector_is_structurally_safe("enabledForUser:", 3)
    assert selector_is_structurally_safe("enabledForUser:context:", 4)
    assert not selector_is_structurally_safe("synthetic", 3)
    assert not selector_is_structurally_safe("one:", 4)

    for marker in [
        "FLEXHookMethodMetadataIsStructurallySafe",
        "FLEXHookSelectorArgumentCount",
        "method.signature.numberOfArguments < argumentCount",
        "FLEXHookSelectorArgumentCount(method.selectorString) != explicitArguments",
        "method_getArgumentType(runtimeMethod, index",
        "method_getImplementation(runtimeMethod) != NULL",
        "FLEXHookMethodResolvesInClass",
        "method_getImplementation(resolved)",
        "strcmp(sourceEncoding, resolvedEncoding) == 0",
        "FLEXHookABIForFLEXMethod",
        "entry.available = executableNow",
        "entry.hookable = executableNow",
    ]:
        require(resolver, marker, "resolver safety and executable-target contract")

    for marker in [
        "UITableViewController",
        "lists only methods with",
        "concrete supported ABI",
    ]:
        require(header, marker, "custom presentation interface")

    for marker in [
        "Objective-C Functions",
        "FLEXObjCEntryEncoding",
        "FLEXHookABIName(entry.abi)",
        "entryForMethod:method",
        "entry.available && entry.hookable",
        "FLEXObjCHookGroup",
        "viewForHeaderInSection",
        "ABI resolved:",
        "UINavigationItemLargeTitleDisplayModeNever",
        "estimatedRowHeight = 54.0",
        "com.allflexing.flex-objc-search-index",
        "delay = immediate ? 0.0 : 0.18",
        "stageEnabled:requestedState",
        "applyPendingWithCompletion",
        "hasPersistedConfirmedEntries",
        "synchronizeNow",
    ]:
        require(controller, marker, "compact grouped browser contract")

    search_body = executable_code(
        body_for_void_method(controller, "updateSearchResultsForSearchController")
    )
    require(search_body, "scheduleFilterForQuery", "off-main indexed filter scheduling")
    forbid(search_body, "reloadData", "synchronous per-keystroke table rebuild")

    toggle_body = executable_code(body_for_void_method(controller, "toggleChanged"))
    require(toggle_body, "stageEnabled:requestedState", "staged toggle")
    forbid(toggle_body, "applyEntryIdentifier", "immediate toggle install")
    forbid(toggle_body, "applyPendingWithCompletion", "immediate toggle batch install")

    forbid(controller, "method.description", "FLEX pretty-printer during discovery or filtering")
    forbid(controller, "FLEXMetadataSection", "crash-prone metadata renderer")
    forbid(controller, "FLEXObjcRuntimeViewController", "native browser presentation inheritance")
    forbid(module, "FLEXHookableObjectExplorerViewController.m", "obsolete explorer source")

    if OBSOLETE_EXPLORER_M.exists() or OBSOLETE_EXPLORER_H.exists():
        raise AssertionError("obsolete class-explorer presentation files still exist")

    for marker in [
        "AllFLEXing malformed selector/type-encoding rendering guard",
        "selectorComponents.count < explicitArguments",
        "@catch (__unused NSException *exception)",
    ]:
        require(transformer, marker, "pinned FLEX defensive rendering patch")

    require(build, "apply-flex-method-rendering-safety.py", "build transformer wiring")
    forbid(build, "apply-flex-runtime-extension-v2.py", "native runtime-browser transformer")

    print(
        "Objective-C structural and dispatch-lane validation, compact grouped UI, "
        "off-main search, staged Apply, and persisted launch re-arm contract: OK"
    )


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
