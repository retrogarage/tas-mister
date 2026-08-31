#!/usr/bin/env python3
"""Emit a stable Markdown summary from Quartus fitter and timing reports."""

from __future__ import annotations

import argparse
import re
from collections import defaultdict
from pathlib import Path


ENTITY_NAMES = {
    "sys_top",
    "alsa",
    "ascal",
    "emu",
    "tas_cadence_telemetry",
    "tas_dsp_program",
    "tas_main",
    "fx68k",
    "tas_dsp",
    "tas_sound",
    "tas_video",
    "tas_polygon",
}


def integer(text: str) -> int:
    match = re.search(r"-?[0-9][0-9,]*", text)
    if not match:
        raise ValueError(f"missing integer value: {text!r}")
    return int(match.group(0).replace(",", ""))


def decimal(text: str) -> float:
    match = re.search(r"-?[0-9][0-9,]*(?:\.[0-9]+)?", text)
    if not match:
        raise ValueError(f"missing decimal value: {text!r}")
    return float(match.group(0).replace(",", ""))


def fields(line: str) -> list[str]:
    return [part.strip() for part in line.split(";")]


def table_value(lines: list[str], label: str) -> str:
    for line in lines:
        row = fields(line)
        if len(row) > 2 and row[1] == label:
            return row[2]
    raise ValueError(f"missing fitter value: {label}")


def classify_ram(name: str) -> str:
    if "tas_dsp_program:dsp_program" in name:
        return "C25 program"
    if "ascal_linf_ram:" in name:
        return "Scaler extension rows"
    if "fx68k:cpu" in name and ("uRam" in name or "nRam" in name):
        return "fx68k control ROM"
    if "g_single_mlab" in name and (
        "tas_ram:internal_data_ram" in name or "tas_ram:power_ram" in name
    ):
        return "Distributed board RAM"
    if "gradient_cache" in name:
        return "Gradient cache"
    if "sprite_line_masks" in name:
        return "Sprite line masks"
    if "sprite_desc_" in name:
        return "Sprite descriptors"
    if "sprite_chain_" in name:
        return "Sprite chain cache"
    if "tas_polygon_line_buffer:polygon_buffer" in name:
        return "Polygon line buffers"
    if "next_ext_high" in name:
        return "Polygon next_ext_high"
    if "tas_line_buffer:line_buffer" in name:
        return "Video 16-bank line buffers"
    if any(token in name for token in ("span_head_", "span_tail_", "span_valid_")):
        return "Polygon async span tables"
    return "Other"


def parse_entities(lines: list[str]) -> list[dict[str, object]]:
    result = []
    in_table = False
    for line in lines:
        if line.startswith(";") and "Fitter Resource Utilization by Entity" in line:
            in_table = True
            continue
        if in_table and line.startswith(";") and "Fitter RAM Summary" in line:
            break
        if not in_table or not line.startswith(";"):
            continue
        row = fields(line)
        if len(row) < 18 or row[16] not in ENTITY_NAMES:
            continue
        result.append(
            {
                "entity": row[16],
                "hierarchy": row[15],
                "alms": decimal(row[2]),
                "memory_alms": decimal(row[6]),
                "registers": integer(row[8]),
                "memory_bits": integer(row[10]),
                "m10ks": integer(row[11]),
                "dsps": integer(row[12]),
            }
        )
    if not result:
        raise ValueError("empty fitter resource-utilization-by-entity table")
    return result


def parse_rams(lines: list[str]) -> dict[str, dict[str, int]]:
    result: dict[str, dict[str, int]] = defaultdict(
        lambda: {"bits": 0, "m10ks": 0, "mlabs": 0, "rows": 0}
    )
    in_table = False
    for line in lines:
        if line.startswith(";") and "Fitter RAM Summary" in line:
            in_table = True
            continue
        if in_table and line.startswith("Note: Fitter may spread"):
            break
        if not in_table or not line.startswith(";"):
            continue
        row = fields(line)
        if len(row) < 22 or row[1] in ("", "Name"):
            continue
        if not row[13].isdigit():
            continue
        group = classify_ram(row[1])
        result[group]["bits"] += integer(row[13])
        result[group]["m10ks"] += integer(row[19])
        result[group]["mlabs"] += integer(row[20])
        result[group]["rows"] += 1
    if not result:
        raise ValueError("empty fitter RAM summary table")
    return result


def parse_timing(lines: list[str]) -> dict[str, float]:
    result = {}
    pattern = re.compile(
        r"Worst-case (setup|hold|recovery|removal|minimum pulse width) slack is "
        r"(-?[0-9]+(?:\.[0-9]+)?)"
    )
    for line in lines:
        match = pattern.search(line)
        if match:
            kind = match.group(1)
            value = float(match.group(2))
            result[kind] = min(result.get(kind, value), value)
    missing = {
        "setup", "hold", "recovery", "removal", "minimum pulse width"
    } - result.keys()
    if missing:
        raise ValueError(
            "missing timing summaries: " + ", ".join(sorted(missing))
        )
    return result


def parse_worst_paths(path: Path | None) -> list[tuple[str, str, str]]:
    if path is None:
        return []
    lines = path.read_text(errors="replace").splitlines()
    result = []
    in_summary = False
    for line in lines:
        if "; Summary of Paths" in line:
            in_summary = True
            continue
        if in_summary and line.startswith("Path #1:"):
            break
        if not in_summary or not line.startswith(";"):
            continue
        row = fields(line)
        if len(row) >= 5 and re.fullmatch(r"-?[0-9]+(?:\.[0-9]+)?", row[1]):
            result.append((row[1], row[2], row[3]))
    if not result:
        raise ValueError(f"empty setup-path summary: {path}")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fit", required=True, type=Path)
    parser.add_argument("--sta", required=True, type=Path)
    parser.add_argument("--paths", type=Path)
    parser.add_argument("--label", default="Quartus build")
    args = parser.parse_args()

    fit_lines = args.fit.read_text(errors="replace").splitlines()
    sta_lines = args.sta.read_text(errors="replace").splitlines()
    entities = parse_entities(fit_lines)
    rams = parse_rams(fit_lines)
    timing = parse_timing(sta_lines)

    alms = table_value(fit_lines, "Logic utilization (ALMs needed / total ALMs on device)")
    placed = table_value(fit_lines, "[A] ALMs used in final placement [=a+b+c+d]")
    mem_alms = table_value(
        fit_lines, "[d] ALMs used for memory (up to half of total ALMs)"
    )
    regs = table_value(fit_lines, "Dedicated logic registers")
    io_regs = table_value(fit_lines, "I/O registers")
    m10ks = table_value(fit_lines, "M10K blocks")
    mlab_bits = table_value(fit_lines, "Total MLAB memory bits")
    block_bits = table_value(fit_lines, "Total block memory bits")
    dsps = table_value(fit_lines, "Total DSP Blocks")

    print(f"# {args.label}")
    print()
    print(f"- Fitter report: `{args.fit}`")
    print(f"- Timing report: `{args.sta}`")
    if args.paths:
        print(f"- Detailed setup paths: `{args.paths}`")
    print()
    print("## Overall")
    print()
    print("| Metric | Result |")
    print("| --- | ---: |")
    for name, value in (
        ("ALMs needed", alms),
        ("ALMs placed", placed),
        ("ALMs used for memory", mem_alms),
        ("Logic registers", regs),
        ("I/O registers", io_regs),
        ("M10Ks", m10ks),
        ("MLAB logical bits", mlab_bits),
        ("Block-memory bits", block_bits),
        ("DSP blocks", dsps),
    ):
        print(f"| {name} | {value} |")
    for name in ("setup", "hold", "recovery", "removal", "minimum pulse width"):
        if name in timing:
            print(f"| Worst {name} slack | {timing[name]:+.3f} ns |")

    print()
    print("## Selected hierarchy")
    print()
    print("| Entity | ALMs | Memory ALMs | Registers | M10Ks | DSPs | Hierarchy |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | --- |")
    for item in entities:
        print(
            f"| {item['entity']} | {item['alms']:.1f} | "
            f"{item['memory_alms']:.1f} | {item['registers']} | "
            f"{item['m10ks']} | {item['dsps']} | `{item['hierarchy']}` |"
        )

    print()
    print("## Inferred RAM groups")
    print()
    print("RAM-table MLAB counts can exceed required Memory LABs when Quartus spreads a RAM for timing.")
    print()
    print("| Group | Logical bits | M10Ks | RAM-table MLABs | Rows |")
    print("| --- | ---: | ---: | ---: | ---: |")
    for name, item in sorted(rams.items(), key=lambda pair: (-pair[1]["mlabs"], pair[0])):
        print(
            f"| {name} | {item['bits']} | {item['m10ks']} | "
            f"{item['mlabs']} | {item['rows']} |"
        )

    paths = parse_worst_paths(args.paths)
    if paths:
        print()
        print("## Worst setup paths")
        print()
        print("| Slack (ns) | From | To |")
        print("| ---: | --- | --- |")
        for slack, source, destination in paths:
            print(f"| {slack} | `{source}` | `{destination}` |")


if __name__ == "__main__":
    main()
