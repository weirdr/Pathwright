#!/usr/bin/env python3
"""Unpack an RXPGuides encoded import using the BattleTag it was exported for.

    python3 addon/tools/rxp_unpack.py BUNDLE --out "Unpacked guides"
    python3 addon/tools/rxp_unpack.py BUNDLE --tag 'Name#1234' --out OUTPUT

Implements the tagged import format in RXPGuides/GuideLoader.lua. Requires
only Python 3. The original UTF-8 guide bytes are preserved, including CRLF.
"""
import argparse
import base64
from pathlib import Path
import re
import tempfile
import zlib


def account_state(tag):
    key = bytearray(tag.encode("utf-8").lower()[-16:].rjust(16, b"\0"))
    for i in range(16):
        key[-i % 16] = key[15-i] ^ key[13-i] ^ key[12-i] ^ key[10-i]
    state = list(range(256))
    j = 0
    for i in range(256):
        j = (j + state[i] + key[i % 16]) % 256
        state[i], state[j] = state[j], state[i]
    return state


def decode_block(payload, checksum, state):
    # The addon's base64 reader also accepts an unpadded final quartet.
    padding = b"=" * (-len(payload) % 4) if b"=" not in payload else b""
    data = bytearray(base64.b64decode(payload + padding, validate=True))
    state = state.copy()
    i = j = 0
    for pos, byte in enumerate(data):
        i = (i + 1) % 256
        j = (j + state[i]) % 256
        state[i], state[j] = state[j], state[i]
        data[pos] = byte ^ state[(state[i] + state[j]) % 256]
    if len(data) < 8 or int.from_bytes(data[-4:], "big") != checksum:
        raise ValueError("Wrong BattleTag or damaged import (checksum mismatch)")
    decoder = zlib.decompressobj()
    plain = decoder.decompress(data)
    if not decoder.eof or decoder.unused_data or zlib.adler32(plain) != checksum:
        raise ValueError("Incomplete or damaged compressed block")
    return [record for record in plain.split(b"\0") if record]


def records(bundle, tag):
    parts = bundle.removeprefix(b"\xef\xbb\xbf").strip().split(b"|")
    if len(parts) < 3 or not parts[0].isdigit() or not parts[-1].isdigit():
        raise ValueError("Expected an RXPGuides count|checksum:payload%|version import")
    state = account_state(tag)
    guides = []
    block = re.compile(rb"(-?\d+):([A-Za-z0-9+/=]+)%")
    for section in parts[1:-1]:
        if not section:
            raise ValueError("Empty encoded section")
        pos = 0
        while pos < len(section):
            match = block.match(section, pos)
            if not match:
                raise ValueError("Malformed or unsupported encoded block")
            guides.extend(decode_block(match[2], int(match[1]) % (1 << 32), state))
            pos = match.end()
    if not guides or len(guides) != int(parts[0]):
        raise ValueError(f"Expected {int(parts[0])} guides, decoded {len(guides)}")
    return guides


def filename(value):
    clean = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "-", value).strip(" .")
    return clean.encode("utf-8")[:190].decode("utf-8", errors="ignore") or "Untitled"


def unpack(source, output, tag):
    if output.exists():
        raise ValueError(f"Choose a new output directory ({output} already exists)")
    guides = records(source.read_bytes(), tag)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        stage = Path(temp) / "guides"
        for index, plain in enumerate(guides, 1):
            header = re.split(r"(?m)^\s*step\b", plain.decode("utf-8-sig"), maxsplit=1)[0]
            fields = dict(re.findall(r"(?m)^\s*#(name|group|subgroup)[ \t]+([^\r\n]+)", header))
            folder = stage / filename(fields.get("group", "Ungrouped"))
            if fields.get("subgroup"):
                folder /= filename(fields["subgroup"])
            folder.mkdir(parents=True, exist_ok=True)
            (folder / f"{index:03} - {filename(fields.get('name', 'Untitled'))}.txt").write_bytes(plain)
        stage.rename(output)
    return len(guides)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--out", type=Path, required=True, help="new output directory")
    parser.add_argument("--tag", help="BattleTag (defaults to the !Name#1234 in the filename)")
    args = parser.parse_args()
    match = re.search(r"!([^!#]+#\d+)", args.bundle.name)
    tag = args.tag or (match and match[1])
    if not tag:
        parser.error("Supply the export's BattleTag with --tag")
    try:
        count = unpack(args.bundle, args.out, tag)
    except (ValueError, OSError, zlib.error) as error:
        parser.exit(1, f"{error}\n")
    print(f"Unpacked {count} guides to {args.out}")
