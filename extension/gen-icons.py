#!/usr/bin/env python3
"""Writes the extension's PNG icons (a rounded blue square with a white branch glyph) using
only the standard library, so the repo needs no image toolchain."""
import struct
import zlib
from pathlib import Path

BLUE = (9, 105, 218)
WHITE = (255, 255, 255)


def png(size, pixels):
    raw = b"".join(b"\x00" + bytes(v for px in row for v in px) for row in pixels)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def render(size):
    radius = size * 0.22
    s = size / 16  # glyph drawn on a 16-unit grid
    trunk_x, fork_x = 5 * s, 11 * s
    top, bottom, split = 3 * s, 13 * s, 8 * s
    dot = max(1.0, 1.5 * s)
    stroke = max(1.0, 1.1 * s)

    def inside_rounded(x, y):
        cx = min(max(x, radius), size - radius)
        cy = min(max(y, radius), size - radius)
        return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2

    def glyph(x, y):
        if abs(x - trunk_x) <= stroke / 2 and top <= y <= bottom:
            return True
        if abs(y - split) <= stroke / 2 and trunk_x <= x <= fork_x:
            return True
        if abs(x - fork_x) <= stroke / 2 and top <= y <= split:
            return True
        for (px, py) in ((trunk_x, top), (trunk_x, bottom), (fork_x, top)):
            if (x - px) ** 2 + (y - py) ** 2 <= dot ** 2:
                return True
        return False

    rows = []
    for j in range(size):
        row = []
        for i in range(size):
            x, y = i + 0.5, j + 0.5
            if not inside_rounded(x, y):
                row.append((0, 0, 0, 0))
            elif glyph(x, y):
                row.append(WHITE + (255,))
            else:
                row.append(BLUE + (255,))
        rows.append(row)
    return rows


if __name__ == "__main__":
    out = Path(__file__).parent / "icons"
    out.mkdir(exist_ok=True)
    for size in (16, 48, 128):
        (out / f"{size}.png").write_bytes(png(size, render(size)))
        print(f"wrote {out / f'{size}.png'}")
