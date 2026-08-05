#!/usr/bin/env python3
"""Source contract for the crash-safe grouped Objective-C hook browser."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOLVER = ROOT / "libflex/AllFLEXing/FLEXObjCHookResolver.m"
EXPLORER = ROOT / "libflex/AllFLEXing/FLEXHookableObjectExplorerViewController.m"
TRANSFORMER = ROOT / "scripts/apply-flex-method-rendering-safety.py"
BUILD = ROOT / "build.sh"


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


def main() -> None:
    resolver = RESOLVER.read_text(encoding="utf-8")
    explorer = EXPLORER.read_text(encoding="utf-8")
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
    ]:
        require(resolver, marker, "resolver safety contract")

    for marker in [
        "FLEXHookableGroupSection",
        "FLEXHookableEntryListController",
        "Instance properties",
        "Class properties",
        "Instance methods",
        "Class methods",
        "Search name, selector, ABI or encoding",
        "allflexing_goBack:",
        "setNavigationBarHidden:NO",
        "FLEXHookableEntryMatches",
    ]:
        require(explorer, marker, "grouped browser contract")

    forbid(explorer, "FLEXMetadataSection", "crash-prone FLEX metadata row renderer")
    forbid(explorer, "method.description", "pretty-printer during list filtering")

    for marker in [
        "AllFLEXing malformed selector/type-encoding rendering guard",
        "selectorComponents.count < explicitArguments",
        "@catch (__unused NSException *exception)",
    ]:
        require(transformer, marker, "pinned FLEX defensive rendering patch")

    require(build, "apply-flex-method-rendering-safety.py", "build transformer wiring")

    print(
        "Objective-C browser structural filter, grouped submenus, semantic list "
        "search, explicit back navigation, and FLEX fail-closed rendering: OK"
    )


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
