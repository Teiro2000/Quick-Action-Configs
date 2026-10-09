"""Builds papermap_city_d.dds: an all-white Fallout 76 map with the possible
Infestation spawn spots as magenta dots.

35 spawn spots - the only places Infestations can spawn since the 1.7.25 game update,
from the Mappalachia map (green hexagons) for game version 1.7.25.39. All 35 were
already in the earlier 52-spot list (34 from the "Infestation Map Green" mod, diffed
against the game's original papermap_city_d.dds, plus 18 from Blobby's red-circle map),
so their exact positions are kept from there.

    python make_map.py
"""
import struct
from pathlib import Path

import numpy as np

SIZE = 4096
RADIUS = 24                 # original markers are ~42 px across; a bit bigger to stand out
BACKGROUND = (255, 255, 255)
MARKER = (255, 0, 255)      # magenta: nothing else on the map uses it, and it stays coloured under the grey smoke

# Marker centres (x, y) in the 4096x4096 texture
MARKERS = [
    (1175, 805), (2454, 897), (1686, 1001), (1022, 1049), (2184, 1116), (2654, 1129),
    (2772, 1381), (1837, 1406), (2038, 1429), (3291, 1610), (2123, 1645), (2442, 1650),
    (1894, 1711), (2954, 1857), (2385, 1868), (2384, 1939), (3183, 2031), (2150, 2203),
    (1123, 2262), (1642, 2322), (1554, 2362), (1235, 2386), (1961, 2415), (3332, 2480),
    (1496, 2481), (918, 2649), (3104, 2687), (2515, 2692), (1630, 2837), (1120, 2908),
    (730, 2921), (2895, 2955), (2803, 2974), (979, 2992), (1174, 3085),
]

OUT = Path(__file__).parent / "textures" / "interface" / "pip-boy" / "papermap_city_d.dds"


def rgb565(c):
    r, g, b = c
    return (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)


def build_mask():
    """True where a marker is (hard-edged discs, so the texture has exactly two colours)."""
    yy, xx = np.mgrid[0:SIZE, 0:SIZE]
    mask = np.zeros((SIZE, SIZE), bool)
    for x, y in MARKERS:
        y0, y1, x0, x1 = y - RADIUS, y + RADIUS + 1, x - RADIUS, x + RADIUS + 1
        mask[y0:y1, x0:x1] |= (xx[y0:y1, x0:x1] - x) ** 2 + (yy[y0:y1, x0:x1] - y) ** 2 <= RADIUS ** 2
    return mask


def encode_bc1(mask):
    """DXT1/BC1 for a two-colour image: color0 = background, color1 = marker,
    2-bit index 0 or 1 per pixel. Exact, no compression artefacts."""
    c0, c1 = rgb565(BACKGROUND), rgb565(MARKER)
    assert c0 > c1  # 4-colour mode, so index 1 is exactly color1
    blocks = mask.reshape(SIZE // 4, 4, SIZE // 4, 4).transpose(0, 2, 1, 3).reshape(-1, 16)
    shifts = (np.arange(16) * 2).astype(np.uint32)
    indices = (blocks.astype(np.uint32) << shifts).sum(1).astype(np.uint32)
    out = np.zeros(len(blocks), dtype=[("c0", "<u2"), ("c1", "<u2"), ("idx", "<u4")])
    out["c0"], out["c1"], out["idx"] = c0, c1, indices
    return out.tobytes()


def dds_header(data_len):
    flags = 0x1 | 0x2 | 0x4 | 0x1000 | 0x80000          # caps|height|width|pixelformat|linearsize
    pf = struct.pack("<II4s5I", 32, 0x4, b"DXT1", 0, 0, 0, 0, 0)
    return (b"DDS " + struct.pack("<7I44x", 124, flags, SIZE, SIZE, data_len, 0, 1)
            + pf + struct.pack("<5I", 0x1000, 0, 0, 0, 0))


def main():
    data = encode_bc1(build_mask())
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(dds_header(len(data)) + data)
    print(f"wrote {OUT} ({len(MARKERS)} markers, {OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
