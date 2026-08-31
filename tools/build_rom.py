#!/usr/bin/env python3
"""Build the linear MiSTer ROM image for Taito Top Landing (World)."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


EXPECTED_SHA1 = {
    "b09_37.13": "b960208e63cede116925e064279a6cf107aef81c",
    "b62-13.1": "198d4f828132316c624da998e49b1873b9886bf0",
    "b62-14.2": "4660570fa6263c28cfae7ccdf154763cc6144896",
    "b62-15.3": "f35afdd7cfd4c09907fb062beb5ae46c2286a381",
    "b62-16.4": "f6fc9322dea8d82bfec3be3fdc8616dc6adf666e",
    "b62-17.5": "91c8cc4e99534b2d533895a342abb22766a20090",
    "b62-18.31": "43f07fe19dec351e851defdf9c7810fb9df04736",
    "b62-20.6": "7593a327f4ea0cc9e28fd3269278871f62fb0598",
    "b62-21.35": "0593718d15b30b10f7686959932e2c934de2a529",
    "b62-28.22": "2c07a0e71d11bca67427331217c507d849500ec1",
    "b62-29.27": "6df3e9782946cf6f4a21ee3d335548c53cd21e3a",
    "b62-30.28": "6bc777bdf1a56952dbfbe2f595279a43e2fa98fd",
    "b62-31.29": "5b014d7d6fa1daf400ac1a437f551281debfdba6",
    "b62-32.30": "d8e0c37b5227d8583d523164ffc6828b4508d5a3",
    "b62-33.39": "7292e3fa69cad6494f2e8e7efa9c3f989bdf958d",
    "b62-34.40": "862c23c095f96f9e0cae00d70947782d5f4e45e6",
    "b62-35.47": "5305c84abcbcc23281744454803b849853b26632",
    "b62-36.48": "eb0dc5d0a6f875e3b8335fb30d4c2ad3880c31b9",
    "b62-42.34": "3a336987aad7bf4df658f924de4bbe6f0fff6d59",
    "b62_22.12": "8518d8e722d4f2516f75224d9a21ab20d8ee6c78",
    "b62_23.41": "0840668dda48f4c9a85410361bfba3ae9580a71f",
    "b62_24.13": "ab8d8f5f6597bfcde4e9ccf9e0181b8b6e769ada",
    "b62_25.42": "ada679198739cd6a419d3fa4311bb92dc385099c",
    "b62_40.14": "6932c62d8051b1811c30139dbd0375115305c731",
    "b62_41.43": "72e4441ad468f37cff69c36699867119ad28274c",
}

OFFSETS = {
    "main": 0x000000,
    "audio": 0x0C0000,
    "dsp": 0x0D0000,
    "gfx": 0x100000,
    "adpcma": 0x200000,
    "adpcmb": 0x2A0000,
    "mecha": 0x2C0000,
    "user1": 0x2C8000,
    "end": 0x2CA000,
}


def checked_read(directory: Path, name: str) -> bytes:
    path = directory / name
    data = path.read_bytes()
    actual = hashlib.sha1(data).hexdigest()
    expected = EXPECTED_SHA1[name]
    if actual != expected:
        raise SystemExit(f"SHA1 mismatch for {path}: {actual}, expected {expected}")
    return data


def interleave(even: bytes, odd: bytes) -> bytes:
    if len(even) != len(odd):
        raise SystemExit("Interleaved ROM halves have different sizes")
    result = bytearray(len(even) * 2)
    result[0::2] = even
    result[1::2] = odd
    return bytes(result)


def build(source: Path) -> bytes:
    image = bytearray([0xFF]) * OFFSETS["end"]

    main_pairs = (
        ("b62_41.43", "b62_40.14"),
        ("b62_25.42", "b62_24.13"),
        ("b62_23.41", "b62_22.12"),
    )
    main = b"".join(
        interleave(checked_read(source, even), checked_read(source, odd))
        for even, odd in main_pairs
    )
    image[OFFSETS["main"] : OFFSETS["main"] + len(main)] = main

    audio = checked_read(source, "b62-42.34")
    image[OFFSETS["audio"] : OFFSETS["audio"] + len(audio)] = audio

    dsp_even = checked_read(source, "b62-21.35")
    dsp_odd = checked_read(source, "b62-20.6")
    # The fitted C25 program space is 4K words.  Both physical 8 KiB ROMs in
    # the World set contain 0xff in their upper 4 KiB, so the meaningful pair
    # is exactly 0x2000 interleaved bytes.  Fail closed if another dump/set
    # ever violates that board-image assumption instead of silently truncating
    # executable program data when the streamed sidecar is written below.
    if any(value != 0xFF for value in dsp_even[0x1000:]) or any(
        value != 0xFF for value in dsp_odd[0x1000:]
    ):
        raise SystemExit("DSP ROM upper halves are not blank; 4K-word program RAM is insufficient")
    dsp = interleave(dsp_even[:0x1000], dsp_odd[:0x1000])
    image[OFFSETS["dsp"] : OFFSETS["dsp"] + len(dsp)] = dsp

    # Eight ROMs are connected as byte lanes of the TC0080VCO graphics bus.
    gfx_lanes = (
        "b62-32.30",
        "b62-31.29",
        "b62-30.28",
        "b62-35.47",
        "b62-34.40",
        "b62-29.27",
        "b62-36.48",
        "b62-33.39",
    )
    gfx = bytearray(0x100000)
    for lane, name in enumerate(gfx_lanes):
        gfx[lane::8] = checked_read(source, name)
    image[OFFSETS["gfx"] : OFFSETS["gfx"] + len(gfx)] = gfx

    adpcma = b"".join(
        checked_read(source, name)
        for name in ("b62-17.5", "b62-16.4", "b62-15.3", "b62-14.2", "b62-13.1")
    )
    image[OFFSETS["adpcma"] : OFFSETS["adpcma"] + len(adpcma)] = adpcma

    adpcmb = checked_read(source, "b62-18.31")
    image[OFFSETS["adpcmb"] : OFFSETS["adpcmb"] + len(adpcmb)] = adpcmb

    mecha = checked_read(source, "b09_37.13")
    image[OFFSETS["mecha"] : OFFSETS["mecha"] + len(mecha)] = mecha

    user1 = checked_read(source, "b62-28.22")
    image[OFFSETS["user1"] : OFFSETS["user1"] + len(user1)] = user1
    return bytes(image)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, nargs="?", default=Path("roms/topland"))
    parser.add_argument("output", type=Path, nargs="?", default=Path("roms/topland.rom"))
    args = parser.parse_args()
    image = build(args.source)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image)
    dsp_output = args.output.with_name(f"{args.output.stem}_dsp.bin")
    dsp_image = image[OFFSETS["dsp"] : OFFSETS["dsp"] + 0x2000]
    dsp_output.write_bytes(dsp_image)
    print(
        f"wrote {args.output} ({len(image):#x} bytes, "
        f"sha1 {hashlib.sha1(image).hexdigest()})"
    )
    print(
        f"wrote {dsp_output} ({len(dsp_image):#x} bytes, "
        f"md5 {hashlib.md5(dsp_image).hexdigest()})"
    )


if __name__ == "__main__":
    main()
