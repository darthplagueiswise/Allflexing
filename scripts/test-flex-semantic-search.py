#!/usr/bin/env python3
"""Executable contract tests for the compact indexed Objective-C hook browser."""

from __future__ import annotations

import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / "libflex/AllFLEXing/FLEXHookableObjCRuntimeViewController.h"
CONTROLLER = ROOT / "libflex/AllFLEXing/FLEXHookableObjCRuntimeViewController.m"
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

        boundary = False
        if index > 0 and character.isupper():
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


def method_body(text: str, selector: str) -> str:
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
    c_patcher = C_PATCHER.read_text(encoding="utf-8")
    scanner = SCANNER.read_text(encoding="utf-8")
    build = BUILD.read_text(encoding="utf-8")

    for marker in [
        "FLEXRuntimeClient.runtime",
        "classesForToken:FLEXSearchToken.any",
        "methodsForToken:FLEXSearchToken.any",
        "entryForMethod:method",
        "entry.available && entry.hookable",
        "entry.abi != FLEXHookABIUnknown",
        "mergeDiscoveredEntries:discovered",
        "surface:FLEXHookSurfaceObjectiveC",
        "FLEXObjCBuildSearchFields",
        "normalizedSearchFields",
        "compactSearchFields",
        "com.allflexing.flex-objc-search-index",
        "delay = immediate ? 0.0 : 0.18",
        "FLEXObjCHookGroup",
        "group.className",
        "ABI resolved:",
        "Class, selector, ABI or image",
        "stageEnabled:requestedState",
        "applyPendingWithCompletion",
        "Apply and close app",
        "UINavigationItemLargeTitleDisplayModeNever",
        "estimatedRowHeight = 54.0",
    ]:
        require(controller, marker, "indexed grouped Objective-C browser contract")

    search_body = executable_code(
        method_body(controller, "updateSearchResultsForSearchController")
    )
    require(search_body, "scheduleFilterForQuery", "debounced search dispatch")
    forbid(search_body, "reloadData", "main-thread full-list filtering")
    forbid(search_body, "FLEXObjCRowMatchesTerms", "main-thread row scan")

    toggle_body = executable_code(method_body(controller, "toggleChanged"))
    require(toggle_body, "stageEnabled:requestedState", "staged row state")
    forbid(toggle_body, "applyEntryIdentifier", "immediate row apply")
    forbid(toggle_body, "applyPendingWithCompletion", "immediate batch apply")

    for marker in [
        "C Symbol Patcher",
        "Symbol, image or ABI",
        "C signatures are not inferable",
        "FLEXHookABIName(entry.abi)",
        "choose the exact ABI",
    ]:
        require(c_patcher, marker, "C ABI patcher contract")

    forbid(header, "FLEXObjcRuntimeViewController", "native FLEX browser inheritance")
    forbid(controller, "didSelectClass:", "class-drilldown presentation")
    forbid(controller, "FLEXHookableObjectExplorerViewController", "obsolete class explorer")
    forbid(controller, "runtimeBrowserSearchPlainTextQuery", "patched FLEX presentation bridge")
    forbid(controller, "Sintaxe FLEX avançada", "native key-path grammar UI")
    forbid(build, "apply-flex-runtime-extension-v2.py", "native runtime presentation transformer")

    for forbidden in [
        "objc_copyClassList",
        "class_copyMethodList",
        "scanObjectiveCRuntime",
        "objectiveCEntryForClass",
    ]:
        forbid(scanner, forbidden, "parallel Objective-C scanner")

    print(
        "FLEX-backed indexed Objective-C discovery, off-main debounced search, "
        "class/image grouping, staged Apply, and C Symbol Patcher ABI contract: OK"
    )


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
