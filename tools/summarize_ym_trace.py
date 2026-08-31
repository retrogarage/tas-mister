#!/usr/bin/env python3
"""Summarize exact YM2610 bus writes emitted by the RTL sound test."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RegisterWrite:
    cycle: int
    bank: int
    register: int
    value: int
    pc: int


def route_name(value: int) -> str:
    return ("mute", "right", "left", "both")[(value >> 6) & 3]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--clock-hz", type=int, default=32_000_000)
    parser.add_argument("--require-key-on", action="store_true")
    parser.add_argument("--require-audio-route", action="store_true")
    args = parser.parse_args()

    address = [0, 0]
    bus_writes = 0
    register_writes: list[RegisterWrite] = []
    for line_number, raw_line in enumerate(args.trace.read_text().splitlines(), 1):
        fields = raw_line.split()
        if not fields:
            continue
        if len(fields) != 4:
            raise SystemExit(f"invalid trace line {line_number}: {raw_line}")
        cycle = int(fields[0])
        port = int(fields[1])
        value = int(fields[2], 16)
        pc = int(fields[3], 16)
        if port not in range(4):
            raise SystemExit(f"invalid port on line {line_number}: {port}")
        bus_writes += 1
        bank = port >> 1
        if not (port & 1):
            address[bank] = value
        else:
            register_writes.append(
                RegisterWrite(cycle, bank, address[bank], value, pc)
            )

    if not register_writes:
        raise SystemExit("trace contains no YM2610 register-data writes")

    counts = Counter((write.bank, write.register) for write in register_writes)
    fm_key_writes = [
        write for write in register_writes
        if write.bank == 0 and write.register == 0x28
    ]
    fm_key_ons = [write for write in fm_key_writes if write.value & 0xF0]
    fm_key_offs = [
        write for write in fm_key_writes if not (write.value & 0xF0)
    ]
    adpcma_key_writes = [
        write for write in register_writes
        if write.bank == 1 and write.register == 0x00
    ]
    adpcma_key_ons = [
        write for write in adpcma_key_writes
        if not (write.value & 0x80) and write.value & 0x3F
    ]
    adpcma_key_offs = [
        write for write in adpcma_key_writes
        if write.value & 0x80 and write.value & 0x3F
    ]
    adpcmb_commands = [
        write for write in register_writes
        if write.bank == 0 and write.register == 0x10
    ]
    adpcmb_starts = [write for write in adpcmb_commands if write.value & 0x80]

    route_writes: list[tuple[str, RegisterWrite]] = []
    for write in register_writes:
        if write.register in range(0xB4, 0xB7):
            route_writes.append(("fm", write))
        elif write.bank == 1 and write.register in range(0x08, 0x0E):
            route_writes.append(("adpcma", write))
        elif write.bank == 0 and write.register == 0x11:
            route_writes.append(("adpcmb", write))
    routes = Counter(
        (kind, route_name(write.value)) for kind, write in route_writes
    )
    key_events = [
        *(('fm', write) for write in fm_key_ons),
        *(('adpcma', write) for write in adpcma_key_ons),
        *(('adpcmb', write) for write in adpcmb_starts),
    ]
    key_events.sort(key=lambda event: event[1].cycle)
    audible_route_writes = [
        (kind, write) for kind, write in route_writes
        if route_name(write.value) != "mute"
    ]

    if args.require_key_on and not key_events:
        raise SystemExit("trace contains no FM/ADPCM key-on")
    if args.require_audio_route and not audible_route_writes:
        raise SystemExit("trace contains no non-muted FM/ADPCM route write")

    first_cycle = register_writes[0].cycle
    last_cycle = register_writes[-1].cycle
    print(
        f"bus_writes={bus_writes} register_writes={len(register_writes)} "
        f"first_cycle={first_cycle} last_cycle={last_cycle} "
        f"span={(last_cycle - first_cycle) / args.clock_hz:.6f}s "
        f"unique_registers={len(counts)} "
        f"fm_key_on={len(fm_key_ons)} fm_key_off={len(fm_key_offs)} "
        f"adpcma_key_on={len(adpcma_key_ons)} "
        f"adpcma_key_off={len(adpcma_key_offs)} "
        f"adpcmb_start={len(adpcmb_starts)} "
        f"adpcmb_commands={len(adpcmb_commands)}"
    )
    print(
        "routes=" + (
            ",".join(
                f"{kind}:{route}:{count}"
                for (kind, route), count in sorted(routes.items())
            )
            if routes else "none"
        )
    )
    print(
        "top_registers=" + ",".join(
            f"b{bank}:{register:02x}:{count}"
            for (bank, register), count in counts.most_common(20)
        )
    )
    print(
        "key_events=" + (
            ",".join(
                f"{kind}@{(write.cycle - first_cycle) / args.clock_hz:.6f}s:"
                f"{write.value:02x}"
                for kind, write in key_events[:64]
            )
            if key_events else "none"
        )
    )


if __name__ == "__main__":
    main()
