#!/usr/bin/env python3
"""Wrap native JT10 signed stereo PCM in a WAV container and summarize it."""

from __future__ import annotations

import argparse
import math
import sys
import wave
from array import array
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path, help="interleaved s16le stereo PCM")
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--sample-rate",
        type=int,
        default=55_556,
        help="integer WAV rate; native JT10 rate is 32 MHz / 576",
    )
    parser.add_argument("--require-audio", action="store_true")
    args = parser.parse_args()

    raw = args.input.read_bytes()
    if len(raw) % 4:
        raise SystemExit(f"PCM size {len(raw)} is not whole stereo s16 frames")
    if not raw:
        raise SystemExit("PCM capture is empty")
    if args.sample_rate <= 0:
        raise SystemExit("sample rate must be positive")

    samples = array("h")
    samples.frombytes(raw)
    if sys.byteorder != "little":
        samples.byteswap()

    left = samples[0::2]
    right = samples[1::2]
    frames = len(left)
    nonzero_left = sum(value != 0 for value in left)
    nonzero_right = sum(value != 0 for value in right)
    stereo_different = sum(lvalue != rvalue for lvalue, rvalue in zip(left, right))
    clipped = sum(
        value in (-32768, 32767)
        for value in samples
    )
    left_sum = sum(left)
    right_sum = sum(right)
    left_mean = left_sum / frames
    right_mean = right_sum / frames
    left_rms = math.sqrt(sum(value * value for value in left) / frames)
    right_rms = math.sqrt(sum(value * value for value in right) / frames)
    left_ac_rms = math.sqrt(
        sum((value - left_mean) ** 2 for value in left) / frames
    )
    right_ac_rms = math.sqrt(
        sum((value - right_mean) ** 2 for value in right) / frames
    )
    difference_rms = math.sqrt(
        sum((lvalue - rvalue) ** 2 for lvalue, rvalue in zip(left, right))
        / frames
    )

    if args.require_audio and not (left_ac_rms or right_ac_rms):
        raise SystemExit("PCM capture contains no changing audio")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(args.output), "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(args.sample_rate)
        wav.writeframes(raw)

    print(
        f"frames={frames} rate={args.sample_rate} "
        f"duration={frames / args.sample_rate:.6f}s "
        f"left_min={min(left)} left_max={max(left)} "
        f"left_mean={left_mean:.3f} left_rms={left_rms:.3f} "
        f"left_ac_rms={left_ac_rms:.3f} "
        f"left_nonzero={nonzero_left} "
        f"right_min={min(right)} right_max={max(right)} "
        f"right_mean={right_mean:.3f} right_rms={right_rms:.3f} "
        f"right_ac_rms={right_ac_rms:.3f} "
        f"right_nonzero={nonzero_right} "
        f"stereo_different={stereo_different} "
        f"difference_rms={difference_rms:.3f} clipped_samples={clipped}"
    )


if __name__ == "__main__":
    main()
