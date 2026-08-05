#!/usr/bin/env python3
"""Executable contract tests for the FLEX-reusing Objective-C browser.

Architecture under test: the browser reuses FLEX's own table/search
infrastructure and cached runtime data layer, and replaces only FLEX's
key-path grammar (* + - and Bundle.Class.-method) with operator-free
natural-text semantic matching.
"""

from __future__ import annotations

import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / "libflex/AllFLEXing/FLEXHookableObjCRuntimeViewController.h"
CONTROLLER = ROOT / "libflex/AllFLEXing/FLEXHookableObjCRuntimeViewController.m"
SEARCH = ROOT / "libflex/AllFLEXing/FLEXHookableObjCSearchController.m"
EXPLORER = ROOT / "libflex/AllFLEXing/FLEXHookableObjectExplorerViewController.m"
C_PATCHER = ROOT / "libflex/AllFLEXing/FLEXRuntimeBrowserController.m"
SCANNER = ROOT / "libflex/AllFLEXing/FLEXRuntimeScanner.m"
BUILD = ROOT / "build.sh"


def normalize(value: str) -> str:
    output: list[str] = []
    for index, character in enumerate(value):
        category = unicodedata.category(character)
        is_letter = category.startswith("L")
        is_digit = category == "Nd"
        if not is_letter and not is_digit:
            if output and output[-1] != " ":
                output.append(" ")
            continue

        is_upper = character.isupper()
        boundary = False
        if index > 0 and is_upper:
            previous = value[index - 1]
            next_is_lower = index + 1 < len(value) and value[index + 1].islower()
            boundary = previous.islower() or previous.isdigit() or (
                previous.isupper() and next_is_lower
            )
        if boundary and output and output[-1] != " ":
            output.append(" ")
        output.append(character.lower())

    return " ".join("".join(output).split())


def compact(value: str) -> str:
    return normalize(value).replace(" ", "")


def query_terms(query: str) -> list[str]:
    return list(dict.fromkeys(normalize(query).split()))


def fields_match(fields: list[str], query: str) -> bool:
    normalized_fields = [normalize(field) for field in fields]
    compact_fields = [compact(field) for field in fields]
    for term in query_terms(query):
        packed_term = compact(term)
        if not any(
            term in normalized or (packed_term and packed_term in packed)
            for normalized, packed in zip(normalized_fields, compact_fields)
        ):
            return False
    return True


def require(text: str, marker: str, label: str) -> None:
    if marker not in text:
        raise AssertionError(f"missing {label}: {marker}")


def forbid(text: str, marker: str, label: str) -> None:
    if marker in text:
        raise AssertionError(f"forbidden {label}: {marker}")


def main() -> None:
    fields = [
        "FBConfigManager",
        "is_employee_enable",
        "-[FBConfigManager is_employee_enable]",
        "B16@0:8",
        "BOOL(id, SEL)",
        "HostFramework",
    ]

    for query in [
        "FBConfigManager",
        "fbconfigmanager",
        "fb config manager",
        "fb_config_manager",
        "employee enable",
        "employeeenable",
        "enable employee",
        "bool sel",
        "e",
    ]:
        if not fields_match(fields, query):
            raise AssertionError(f"semantic query failed: {query}")

    if fields_match(fields, "config disabled"):
        raise AssertionError("AND semantics accepted a missing term")
    if fields_match(fields, "unrelated"):
        raise AssertionError("unrelated query matched")

    header = HEADER.read_text(encoding="utf-8")
    controller = CONTROLLER.read_text(encoding="utf-8")
    search = SEARCH.read_text(encoding="utf-8")
    explorer = EXPLORER.read_text(encoding="utf-8")
    c_patcher = C_PATCHER.read_text(encoding="utf-8")
    scanner = SCANNER.read_text(encoding="utf-8")
    build = BUILD.read_text(encoding="utf-8")

    # The search controller replaces FLEX's key-path grammar but reuses FLEX's
    # cached runtime data layer and its background-filter-then-reload pattern.
    for marker in [
        "FLEXRuntimeClient.runtime",
        "classesForToken:FLEXSearchToken.any",
        "methodsForToken:FLEXSearchToken.any",
        "canRepresentMethod:method",
        "FLEXHookableNormalize",
        "FLEXHookableCompact",
        "FLEXHookableTerms",
        "searchGeneration",
        "dispatch_get_main_queue",
    ]:
        require(search, marker, "semantic search contract")

    # The browser itself reuses FLEX's search bar infrastructure.
    for marker in [
        "showsSearchBar",
        "FLEXHookableObjCSearchController",
        "hookableSearchDidSelectClass:",
    ]:
        require(controller, marker, "FLEX search-infrastructure reuse")

    # The explorer reuses FLEX's own sections and adds the hook layer on top.
    for marker in [
        "makeSections",
        "FLEXMetadataSection",
        "excludedMetadata",
        "FLEXMutableListSection",
        "entryForMethod:method",
        "surface:FLEXHookSurfaceObjectiveC",
        "applyEntryIdentifier:identifier",
        "FLEXHookABIName(display.abi)",
    ]:
        require(explorer, marker, "hook-aware explorer contract")

    for marker in [
        "C Symbol Patcher",
        "Symbol, image or ABI",
        "C signatures are not inferable",
        "FLEXHookABIName(entry.abi)",
        "choose the exact ABI",
    ]:
        require(c_patcher, marker, "C ABI patcher contract")

    # The key-path grammar must not come back: no FLEXKeyPathSearchController,
    # no tokenizer, no operator toolbar anywhere in the browser surface.
    for text, label in ((controller, "browser"), (search, "search controller")):
        forbid(text, "FLEXKeyPathSearchController", f"key-path grammar in {label}")
        forbid(text, "FLEXRuntimeKeyPathTokenizer", f"key-path tokenizer in {label}")
        forbid(text, "FLEXRuntimeBrowserToolbar", f"operator toolbar in {label}")
    forbid(build, "apply-flex-runtime-extension-v2.py", "native runtime presentation transformer")

    for forbidden in [
        "objc_copyClassList",
        "class_copyMethodList",
        "scanObjectiveCRuntime",
        "objectiveCEntryForClass",
    ]:
        forbid(scanner, forbidden, "parallel Objective-C scanner")

    print(
        "FLEX search/data-layer reuse, operator-free semantic AND matching, "
        "hook-aware explorer over FLEX sections, and explicit C Symbol Patcher "
        "ABI contract: OK"
    )


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
