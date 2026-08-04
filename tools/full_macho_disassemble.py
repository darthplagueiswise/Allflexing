#!/usr/bin/env python3
"""Produce a deterministic, symbol-aware ARM64 disassembly of a Mach-O dylib.

This is intentionally a static audit tool: it never loads or executes the
target. Every byte in each executable code section is emitted as an ARM64
instruction or an explicit .word fallback, and direct branch targets are
annotated from the Mach-O symbol table.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import pathlib
import sys
from typing import Iterable

import capstone
import lief


CODE_SECTIONS = {"__text", "__stubs", "__stub_helper", "__objc_stubs"}


def first_binary(parsed):
    try:
        return next(iter(parsed))
    except TypeError:
        return parsed


def symbols_by_address(binary) -> tuple[dict[int, list[str]], list[dict[str, object]]]:
    address_map: dict[int, list[str]] = collections.defaultdict(list)
    records: list[dict[str, object]] = []
    for symbol in binary.symbols:
        name = symbol.name or ""
        address = int(symbol.value)
        record = {
            "name": name,
            "address": address,
            "type": str(symbol.type),
            "origin": str(symbol.origin),
            "category": str(symbol.category),
        }
        records.append(record)
        if address and name:
            address_map[address].append(name)
    for names in address_map.values():
        names.sort()
    records.sort(key=lambda item: (int(item["address"]), str(item["name"])))
    return dict(address_map), records


def direct_target(instruction) -> int | None:
    if instruction.mnemonic not in {
        "b", "bl", "cbz", "cbnz", "tbz", "tbnz",
    } and not instruction.mnemonic.startswith("b."):
        return None
    if not instruction.operands:
        return None
    operand = instruction.operands[-1]
    if operand.type != capstone.arm64.ARM64_OP_IMM:
        return None
    return int(operand.imm)


def nearest_name(address: int, labels: dict[int, list[str]]) -> str | None:
    names = labels.get(address)
    return names[0] if names else None


def section_content(section) -> bytes:
    return bytes(section.content)


def disassemble_section(section, labels, output, xrefs) -> dict[str, int | str]:
    start = int(section.virtual_address)
    content = section_content(section)
    end = start + len(content)
    output.write(
        f"\n\n===== {section.segment_name},{section.name} "
        f"0x{start:016x}-0x{end:016x} ({len(content)} bytes) =====\n"
    )

    decoder = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_LITTLE_ENDIAN)
    decoder.detail = True
    decoder.skipdata = False

    decoded = {instruction.address: instruction for instruction in decoder.disasm(content, start)}
    instruction_count = 0
    fallback_count = 0
    cursor = start
    while cursor < end:
        if cursor in labels:
            for name in labels[cursor]:
                output.write(f"\n{cursor:016x} <{name}>:\n")

        instruction = decoded.get(cursor)
        if instruction is None:
            relative = cursor - start
            raw = content[relative : relative + 4]
            padded = raw + b"\x00" * (4 - len(raw))
            value = int.from_bytes(padded, "little")
            output.write(
                f"  {cursor:016x}: {raw.hex(' '):<11}  .word      0x{value:08x}\n"
            )
            cursor += len(raw)
            fallback_count += 1
            continue

        raw_hex = instruction.bytes.hex(" ")
        annotation = ""
        target = direct_target(instruction)
        if target is not None:
            xrefs[target].append(instruction.address)
            target_name = nearest_name(target, labels)
            annotation = f" ; -> 0x{target:x}"
            if target_name:
                annotation += f" <{target_name}>"
        output.write(
            f"  {instruction.address:016x}: {raw_hex:<11}  "
            f"{instruction.mnemonic:<10} {instruction.op_str}{annotation}\n"
        )
        cursor += instruction.size
        instruction_count += 1

    return {
        "segment": section.segment_name,
        "section": section.name,
        "address": start,
        "size": len(content),
        "instructions": instruction_count,
        "fallback_words": fallback_count,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--index", type=pathlib.Path)
    args = parser.parse_args()

    target = args.input.read_bytes()
    parsed = lief.MachO.parse(str(args.input))
    if parsed is None:
        raise SystemExit("LIEF could not parse the Mach-O")
    binary = first_binary(parsed)
    labels, symbol_records = symbols_by_address(binary)
    sections = [section for section in binary.sections if section.name in CODE_SECTIONS]
    sections.sort(key=lambda section: int(section.virtual_address))
    if not sections:
        raise SystemExit("No executable sections were found")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    xrefs: dict[int, list[int]] = collections.defaultdict(list)
    summaries = []
    with args.output.open("w", encoding="utf-8", newline="\n") as output:
        output.write("AllFLEXing reference — complete static ARM64 disassembly\n")
        output.write(f"input: {args.input.name}\n")
        output.write(f"sha256: {hashlib.sha256(target).hexdigest()}\n")
        output.write(f"file_size: {len(target)}\n")
        output.write(f"symbols: {len(symbol_records)}\n")
        output.write(f"code_sections: {len(sections)}\n")
        for section in sections:
            summaries.append(disassemble_section(section, labels, output, xrefs))

        output.write("\n\n===== DIRECT BRANCH XREF INDEX =====\n")
        for target_address in sorted(xrefs):
            target_name = nearest_name(target_address, labels)
            name = f" <{target_name}>" if target_name else ""
            callers = ", ".join(f"0x{caller:x}" for caller in sorted(set(xrefs[target_address])))
            output.write(f"0x{target_address:016x}{name}: {callers}\n")

    index_path = args.index or args.output.with_suffix(args.output.suffix + ".json")
    index = {
        "input": args.input.name,
        "sha256": hashlib.sha256(target).hexdigest(),
        "file_size": len(target),
        "symbol_count": len(symbol_records),
        "symbols": symbol_records,
        "sections": summaries,
        "direct_xrefs": {
            f"0x{address:x}": [f"0x{caller:x}" for caller in sorted(set(callers))]
            for address, callers in sorted(xrefs.items())
        },
    }
    index_path.write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
