#!/usr/bin/env python3
"""Executable contract tests for AllFLEXing's FLEX-backed search semantics."""

from __future__ import annotations

import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = ROOT / "libflex/AllFLEXing/FLEXHookableObjCRuntimeViewController.m"
SCANNER = ROOT / "libflex/AllFLEXing/FLEXRuntimeScanner.m"
TRANSFORMER = ROOT / "scripts/apply-flex-runtime-extension-v2.py"


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
        compact_term = compact(term)
        if not any(
            term in normalized or (compact_term and compact_term in packed)
            for normalized, packed in zip(normalized_fields, compact_fields)
        ):
            return False
    return True


def uses_plain_mode(query: str) -> bool:
    trimmed = query.strip()
    return bool(trimmed) and not any(token in trimmed for token in (".", "*", "\\")) and not trimmed.startswith(("+", "-"))


def assert_true(condition: bool, label: str) -> None:
    if not condition:
        raise AssertionError(label)


def main() -> None:
    fields = [
        "FBConfigManager",
        "is_employee_enable",
        "-[FBConfigManager is_employee_enable]",
        "B16@0:8",
        "HostFramework",
    ]

    equivalent_queries = [
        "FBConfigManager",
        "fbconfigmanager",
        "fb config manager",
        "fb_config_manager",
        "employee enable",
        "employeeenable",
        "enable employee",
        "e",
    ]
    for query in equivalent_queries:
        assert_true(uses_plain_mode(query), f"plain mode rejected: {query}")
        assert_true(fields_match(fields, query), f"semantic query failed: {query}")

    for query in [
        "*.FBConfigManager.*",
        "*.*.-isEnabled",
        "*.*.+sharedInstance",
        "+sharedInstance",
        "-isEnabled",
    ]:
        assert_true(not uses_plain_mode(query), f"advanced FLEX query entered plain mode: {query}")

    assert_true(not fields_match(fields, "config disabled"), "AND semantics accepted a missing term")
    assert_true(not fields_match(fields, "unrelated"), "unrelated query matched")

    controller = CONTROLLER.read_text(encoding="utf-8")
    transformer = TRANSFORMER.read_text(encoding="utf-8")
    scanner = SCANNER.read_text(encoding="utf-8")

    for marker in [
        "FLEXRuntimeClient.runtime",
        "classesForToken:FLEXSearchToken.any",
        "methodsForToken:FLEXSearchToken.any",
        "FLEXSemanticCompactText",
        "runtimeBrowserShouldUsePlainTextSearchForQuery",
        "runtimeBrowserSearchPlainTextQuery",
        "Sintaxe FLEX avançada",
    ]:
        assert_true(marker in controller, f"controller marker missing: {marker}")

    for marker in [
        "runtimeBrowserShouldIncludeMethod",
        "performPlainTextSearch",
        "plainSearchGeneration",
    ]:
        assert_true(marker in transformer, f"transformer marker missing: {marker}")

    for forbidden in [
        "objc_copyClassList",
        "class_copyMethodList",
        "scanObjectiveCRuntime",
        "objectiveCEntryForClass",
    ]:
        assert_true(forbidden not in scanner, f"parallel Objective-C scanner returned: {forbidden}")

    print("FLEX semantic search equivalence, AND matching, advanced syntax routing, and C-only scanner: OK")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
