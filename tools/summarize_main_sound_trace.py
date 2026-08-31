#!/usr/bin/env python3
"""Decode main-CPU TC0140SYT accesses captured by tests/tb_main.sv."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class MainAccess:
    cycle: int
    write: int
    port: int
    value: int
    observed_dout: int
    pc: int


@dataclass(frozen=True)
class MailboxByte:
    cycle: int
    index: int
    value: int
    pc: int


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--clock-hz", type=int, default=32_000_000)
    args = parser.parse_args()

    accesses: list[MainAccess] = []
    for line_number, raw_line in enumerate(args.trace.read_text().splitlines(), 1):
        fields = raw_line.split()
        if not fields:
            continue
        if len(fields) != 6:
            raise SystemExit(f"invalid trace line {line_number}: {raw_line}")
        cycle = int(fields[0])
        write = int(fields[1])
        port = int(fields[2])
        value = int(fields[3], 16)
        observed_dout = int(fields[4], 16)
        pc = int(fields[5], 16)
        if (
            write not in (0, 1)
            or port not in (0, 1)
            or value not in range(16)
            or observed_dout not in range(16)
        ):
            raise SystemExit(f"invalid trace line {line_number}: {raw_line}")
        if accesses and cycle <= accesses[-1].cycle:
            raise SystemExit(f"non-monotonic cycle on line {line_number}")
        accesses.append(MainAccess(cycle, write, port, value, observed_dout, pc))

    if not accesses:
        raise SystemExit("trace contains no main-side sound accesses")

    index = 0
    nibbles = [0, 0, 0, 0]
    mailbox_bytes: list[MailboxByte] = []
    reset_writes: list[MainAccess] = []
    ignored_data_writes = 0
    for access in accesses:
        if not access.write:
            if access.port == 1 and index in range(4):
                index += 1
            continue
        if access.port == 0:
            index = access.value
            continue
        if index in range(4):
            nibbles[index] = access.value
            if index in (1, 3):
                mailbox_bytes.append(
                    MailboxByte(
                        access.cycle,
                        index // 2,
                        nibbles[index - 1] | access.value << 4,
                        access.pc,
                    )
                )
            index += 1
        elif index == 4:
            reset_writes.append(access)
        else:
            ignored_data_writes += 1

    first_cycle = accesses[0].cycle
    print(
        f"accesses={len(accesses)} "
        f"writes={sum(access.write for access in accesses)} "
        f"reads={sum(not access.write for access in accesses)} "
        f"first_cycle={first_cycle} "
        f"last_cycle={accesses[-1].cycle} "
        f"span={(accesses[-1].cycle - first_cycle) / args.clock_hz:.6f}s "
        f"reset_writes={len(reset_writes)} "
        f"mailbox_bytes={len(mailbox_bytes)} "
        f"ignored_data_writes={ignored_data_writes}"
    )
    for write in reset_writes:
        print(
            f"reset t={(write.cycle - first_cycle) / args.clock_hz:.6f}s "
            f"value={write.value:x} pc={write.pc:06x}"
        )
    for byte in mailbox_bytes:
        print(
            f"mailbox t={(byte.cycle - first_cycle) / args.clock_hz:.6f}s "
            f"slot={byte.index} value={byte.value:02x} pc={byte.pc:06x}"
        )


if __name__ == "__main__":
    main()
