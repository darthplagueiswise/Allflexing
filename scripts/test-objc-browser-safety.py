#!/usr/bin/env python3
"""Source contract for the crash-safe FLEX-reusing Objective-C hook browser.

The browser reuses FLEX's own renderer (FLEXMetadataSection) rather than a
bespoke one. Two independent layers keep that safe against the malformed
selector/type-encoding crash: the pinned FLEX rendering patch applied at build
time, and the resolver-driven exclusion of non-hookable methods from the
rendered sections.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOLVER = ROOT / "libflex/AllFLEXing/FLEXObjCHookResolver.m"
HEADER = ROOT / "libflex/AllFLEXing/FLEXHookableObjCRuntimeViewController.h"
CONTROLLER = ROOT / "libflex/AllFLEXing/FLEXHookableObjCRuntimeViewController.m"
MODULE = ROOT / "libflex/modules/HookRuntime/Module.mk"
TRANSFORMER = ROOT / "scripts/apply-flex-method-rendering-safety.py"
BUILD = ROOT / "build.sh"
EXPLORER = ROOT / "libflex/AllFLEXing/FLEXHookableObjectExplorerViewController.m"
SEARCH = ROOT / "libflex/AllFLEXing/FLEXHookableObjCSearchController.m"


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
    header = HEADER.read_text(encoding="utf-8")
    controller = CONTROLLER.read_text(encoding="utf-8")
    module = MODULE.read_text(encoding="utf-8")
    transformer = TRANSFORMER.read_text(encoding="utf-8")
    build = BUILD.read_text(encoding="utf-8")
    explorer = EXPLORER.read_text(encoding="utf-8")
    search = SEARCH.read_text(encoding="utf-8")

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
        "FLEXHookABIForFLEXMethod",
    ]:
        require(resolver, marker, "resolver safety contract")

    for marker in [
        "FLEXTableViewController",
        "concrete supported ABI",
    ]:
        require(header, marker, "browser presentation interface")

    for marker in [
        "FLEXHookableObjCSearchController",
        "hookableSearchDidSelectClass:",
        "FLEXHookableObjectExplorerViewController",
    ]:
        require(controller, marker, "browser wiring contract")

    # Only methods the resolver accepts may be rendered or toggled. This is the
    # second layer of crash defense on top of the pinned FLEX rendering patch.
    for marker in [
        "canRepresentMethod:method",
        "excludedMetadata",
        "FLEXHookABIName(display.abi)",
        "entryForMethod:method",
        "applyEntryIdentifier:identifier",
    ]:
        require(explorer, marker, "hook-aware explorer safety contract")

    # Discovery must filter by the resolver before anything reaches the UI.
    require(search, "canRepresentMethod:method", "search-time eligibility filter")

    # The pretty-printer must never run during discovery or filtering, where a
    # malformed selector would be decoded outside the guarded render path.
    forbid(search, "method.description", "FLEX pretty-printer during discovery or filtering")

    # Both new sources must be in the build manifest or the Makefile rejects the tree.
    for source in [
        "FLEXHookableObjCSearchController.m",
        "FLEXHookableObjectExplorerViewController.m",
    ]:
        require(module, source, "module manifest entry")

    for marker in [
        "AllFLEXing malformed selector/type-encoding rendering guard",
        "selectorComponents.count < explicitArguments",
        "@catch (__unused NSException *exception)",
    ]:
        require(transformer, marker, "pinned FLEX defensive rendering patch")

    require(build, "apply-flex-method-rendering-safety.py", "build transformer wiring")
    forbid(build, "apply-flex-runtime-extension-v2.py", "native runtime-browser transformer")

    print(
        "Objective-C structural filter, resolver-gated rendering over reused FLEX "
        "sections, stable per-ID actions, and FLEX fail-closed rendering: OK"
    )


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
