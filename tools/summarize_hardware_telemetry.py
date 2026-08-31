#!/usr/bin/env python3
"""Summarize Taito Air hardware telemetry sample logs.

Legacy logs contain one value per line in word 6 (video), word 2 (CPU), word 3
(DSP) order.  Compact logs contain one sample per line in word 2, word 3, word
6 order.  Either form may append word 7, which records line-builder deadline
misses and the first state in which a deadline was missed.  Cadence logs append
words 8-11 after word 7; these preserve the old fields while adding frame CPU
and DSP work plus cumulative DSP/68000 video-event counters.
Audio logs append words 12-15; these record the Z80, YM2610/sample-cache
activity, and the live signed stereo outputs without changing older layouts.
Arbitration logs append words 16-17; these record total/max C25 hold clocks,
68000 clocks blocked specifically by the video-safe gate, and local CPU-cache
hits that completed without consuming DDR while that gate was closed.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    args = parser.parse_args()

    rows: dict[int, list[int]] = {}
    for raw_line in args.log.read_text().splitlines():
        fields = raw_line.split()
        if len(fields) not in (2, 4, 5, 9, 13, 15):
            continue
        sample = int(fields[0])
        values = [int(value, 16) for value in fields[1:]]
        if len(fields) in (4, 5, 9, 13, 15):
            word2, word3, word6, *timing = values
            values = [word6, word2, word3, *timing]
        rows.setdefault(sample, []).extend(values)

    complete = {index: values for index, values in rows.items()
                if len(values) in (3, 4, 8, 12, 14)}
    if not complete:
        raise SystemExit("no complete telemetry samples")

    row_widths = {len(values) for values in complete.values()}
    if len(row_widths) != 1:
        raise SystemExit("mixed telemetry sample widths")
    row_width = row_widths.pop()
    has_timing = row_width >= 4
    has_cadence = row_width >= 8
    has_audio = row_width >= 12
    has_arbitration = row_width >= 14

    spans: list[int] = []
    overflow_samples = 0
    missed: list[int] = []
    fault_samples = 0
    fault_cycles: list[int] = []
    fault_addresses: list[int] = []
    illegal: list[int] = []
    polygon_missed: list[int] = []
    builder_missed: list[int] = []
    first_builder_missed: int | None = None
    first_builder_state: int | None = None
    first_builder_vcount: int | None = None
    builder_state_mask = 0
    first_overflow: int | None = None
    first_missed: int | None = None
    frame_counts: list[int] = []
    frame_cpu_cycles: list[int] = []
    frame_dsp_instructions: list[int] = []
    dsp_instruction_totals: list[int] = []
    event_counts: list[tuple[int, int, int, int, int]] = []
    z80_m1_totals: list[int] = []
    z80_addresses: list[int] = []
    sound_banks: list[int] = []
    sound_reset_samples = 0
    sound_halted_samples = 0
    ym_write_totals: list[int] = []
    sample_a_misses: list[int] = []
    sample_b_misses: list[int] = []
    sample_underruns: list[int] = []
    sample_request_samples = 0
    sample_addresses: list[int] = []
    audio_left: list[int] = []
    audio_right: list[int] = []
    polygon_hold_totals: list[int] = []
    polygon_hold_maxima: list[int] = []
    cpu_blocked_clocks: list[int] = []
    cpu_unsafe_cache_hits: list[int] = []

    for sample, values in sorted(complete.items()):
        word6, word2, word3 = values[:3]
        spans.append((word6 >> 49) & 0x1FFF)
        overflow_samples += (word6 >> 62) & 1
        if (word6 >> 62) & 1 and first_overflow is None:
            first_overflow = sample
        missed.append(word6 & 0xFFF)
        if word6 & 0xFFF and first_missed is None:
            first_missed = sample

        fault_cycles.append(word2 >> 32)
        fault_addresses.append((word2 >> 8) & 0xFFFFFF)
        fault_samples += (word2 >> 7) & 1

        illegal.append((word3 >> 16) & 0xFFFF)

        if has_timing:
            word7 = values[3]
            polygon_missed.append((word7 >> 13) & 0x1FFF)
            builder_missed.append(word7 & 0x1FFF)
            builder_state_mask |= (word7 >> 28) & 0x7FFFF
            if (word7 >> 61) & 1 and first_builder_missed is None:
                first_builder_missed = sample
                first_builder_state = (word7 >> 56) & 0x1F
                first_builder_vcount = (word7 >> 47) & 0x1FF

        if has_cadence:
            word8, word9, word10, word11 = values[4:8]
            if word11 >> 32 != 0x54415331:
                raise SystemExit(
                    f"sample {sample} has invalid cadence magic "
                    f"0x{word11 >> 32:08x}"
                )
            frame_counts.append(word8 >> 32)
            frame_cpu_cycles.append(word8 & 0xFFFFFFFF)
            frame_dsp_instructions.append(word9 >> 32)
            dsp_instruction_totals.append(word9 & 0xFFFFFFFF)
            event_counts.append((
                (word10 >> 48) & 0xFFFF,
                (word10 >> 32) & 0xFFFF,
                (word10 >> 16) & 0xFFFF,
                word10 & 0xFFFF,
                word11 & 0xFFFF,
            ))

        if has_audio:
            word12, word13, word14, word15 = values[8:12]
            if word15 >> 32 != 0x54415332:
                raise SystemExit(
                    f"sample {sample} has invalid audio magic "
                    f"0x{word15 >> 32:08x}"
                )
            z80_m1_totals.append(word12 >> 32)
            z80_addresses.append((word12 >> 16) & 0xFFFF)
            sound_banks.append((word12 >> 13) & 0x7)
            sound_reset_samples += 1 - ((word12 >> 12) & 1)
            sound_halted_samples += (word12 >> 11) & 1
            ym_write_totals.append(word13 >> 32)
            sample_a_misses.append((word13 >> 16) & 0xFFFF)
            sample_b_misses.append(word13 & 0xFFFF)
            sample_underruns.append(word14 >> 48)
            sample_request_samples += (word14 >> 24) & 1
            sample_addresses.append(word14 & 0xFFFFFF)
            left = (word15 >> 16) & 0xFFFF
            right = word15 & 0xFFFF
            audio_left.append(left - 0x10000 if left & 0x8000 else left)
            audio_right.append(right - 0x10000 if right & 0x8000 else right)

        if has_arbitration:
            word16, word17 = values[12:14]
            polygon_hold_totals.append(word16 >> 32)
            polygon_hold_maxima.append(word16 & 0xFFFFFFFF)
            cpu_blocked_clocks.append(word17 >> 32)
            cpu_unsafe_cache_hits.append(word17 & 0xFFFFFFFF)

    print(
        f"samples={len(complete)} first={min(complete)} last={max(complete)} "
        f"span_min={min(spans)} span_max={max(spans)} "
        f"overflow_samples={overflow_samples} "
        f"first_overflow={first_overflow} "
        f"missed_min={min(missed)} missed_max={max(missed)} "
        f"first_missed={first_missed} "
        f"fault_samples={fault_samples} "
        f"fault_cycles_max={max(fault_cycles)} "
        f"fault_addr_max=0x{max(fault_addresses):06x} "
        f"illegal_min={min(illegal)} illegal_max={max(illegal)}"
    )
    if has_timing:
        print(
            f"polygon_missed_min={min(polygon_missed)} "
            f"polygon_missed_max={max(polygon_missed)} "
            f"builder_missed_min={min(builder_missed)} "
            f"builder_missed_max={max(builder_missed)} "
            f"first_builder_missed={first_builder_missed} "
            f"first_builder_state={first_builder_state} "
            f"first_builder_vcount={first_builder_vcount} "
            f"builder_state_mask=0x{builder_state_mask:05x}"
        )
    if has_cadence:
        # At one retirement per 32 MHz system clock, a 54 Hz frame cannot
        # contain one million C25 instructions.  Early cadence candidates
        # directly subtracted the C25's reset-local counter and can therefore
        # contain a near-2^32 underflow at an attract-scene reset.  Keep old
        # logs useful while reporting (rather than silently accepting) it.
        plausible_frame_dsp = [
            count for count in frame_dsp_instructions if count < 1_000_000
        ]
        invalid_frame_dsp = (
            len(frame_dsp_instructions) - len(plausible_frame_dsp)
        )
        if not plausible_frame_dsp:
            raise SystemExit("no plausible frame DSP instruction samples")
        event_names = ("flag0", "flag1", "flag2", "dma_copy", "dma_erase")
        event_deltas = [
            (event_counts[-1][index] - event_counts[0][index]) & 0xFFFF
            for index in range(len(event_names))
        ]
        print(
            f"frame_first={frame_counts[0]} frame_last={frame_counts[-1]} "
            f"frame_cpu_min={min(frame_cpu_cycles)} "
            f"frame_cpu_max={max(frame_cpu_cycles)} "
            f"frame_dsp_min={min(plausible_frame_dsp)} "
            f"frame_dsp_max={max(plausible_frame_dsp)} "
            f"frame_dsp_invalid={invalid_frame_dsp} "
            f"dsp_total_first={dsp_instruction_totals[0]} "
            f"dsp_total_last={dsp_instruction_totals[-1]} "
            + " ".join(
                f"{name}_delta={delta}"
                for name, delta in zip(event_names, event_deltas, strict=True)
            )
        )
    if has_audio:
        print(
            f"z80_m1_first={z80_m1_totals[0]} "
            f"z80_m1_last={z80_m1_totals[-1]} "
            f"z80_m1_delta={(z80_m1_totals[-1] - z80_m1_totals[0]) & 0xFFFFFFFF} "
            f"z80_addr_first=0x{z80_addresses[0]:04x} "
            f"z80_addr_last=0x{z80_addresses[-1]:04x} "
            f"sound_bank_min={min(sound_banks)} "
            f"sound_bank_max={max(sound_banks)} "
            f"sound_reset_samples={sound_reset_samples} "
            f"sound_halted_samples={sound_halted_samples} "
            f"ym_writes_first={ym_write_totals[0]} "
            f"ym_writes_last={ym_write_totals[-1]} "
            f"ym_writes_delta={(ym_write_totals[-1] - ym_write_totals[0]) & 0xFFFFFFFF}"
        )
        print(
            f"sample_a_miss_first={sample_a_misses[0]} "
            f"sample_a_miss_last={sample_a_misses[-1]} "
            f"sample_a_miss_delta={(sample_a_misses[-1] - sample_a_misses[0]) & 0xFFFF} "
            f"sample_b_miss_first={sample_b_misses[0]} "
            f"sample_b_miss_last={sample_b_misses[-1]} "
            f"sample_b_miss_delta={(sample_b_misses[-1] - sample_b_misses[0]) & 0xFFFF} "
            f"sample_underrun_min={min(sample_underruns)} "
            f"sample_underrun_max={max(sample_underruns)} "
            f"sample_underrun_delta={(sample_underruns[-1] - sample_underruns[0]) & 0xFFFF} "
            f"sample_request_samples={sample_request_samples} "
            f"sample_addr_first=0x{sample_addresses[0]:06x} "
            f"sample_addr_last=0x{sample_addresses[-1]:06x}"
        )
        print(
            f"audio_left_min={min(audio_left)} audio_left_max={max(audio_left)} "
            f"audio_left_nonzero={sum(value != 0 for value in audio_left)} "
            f"audio_right_min={min(audio_right)} audio_right_max={max(audio_right)} "
            f"audio_right_nonzero={sum(value != 0 for value in audio_right)}"
        )
    if has_arbitration:
        print(
            f"polygon_hold_total_first={polygon_hold_totals[0]} "
            f"polygon_hold_total_last={polygon_hold_totals[-1]} "
            f"polygon_hold_max_clocks={max(polygon_hold_maxima)} "
            f"polygon_hold_max_us={max(polygon_hold_maxima) / 32.0:.3f} "
            f"cpu_blocked_first={cpu_blocked_clocks[0]} "
            f"cpu_blocked_last={cpu_blocked_clocks[-1]} "
            f"cpu_unsafe_cache_hits_first={cpu_unsafe_cache_hits[0]} "
            f"cpu_unsafe_cache_hits_last={cpu_unsafe_cache_hits[-1]}"
        )


if __name__ == "__main__":
    main()
