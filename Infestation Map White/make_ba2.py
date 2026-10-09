"""Packs textures/interface/pip-boy/papermap_city_d.dds into a Fallout 76 texture
archive (DX10 BA2), laid out like the Infestation Map Green mod's BA2.

    python make_ba2.py      (run make_map.py first)
"""
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).parent
ARCHIVE_PATH = "textures/interface/pip-boy/papermap_city_d.dds"
DDS = HERE / ARCHIVE_PATH
OUT = HERE / "Infestation Map White.ba2"

# Path hashes for textures/interface/pip-boy/papermap_city_d.dds, copied from the
# game's own archive entry for this file (same values the green mod uses)
NAME_HASH = 0x7FCAC2B2
DIR_HASH = 0x13FEDF9C
DXGI_BC1_UNORM = 71


def main():
    dds = DDS.read_bytes()
    assert dds[:4] == b"DDS " and dds[84:88] == b"DXT1", "expected a DXT1 .dds"
    height, width = struct.unpack("<II", dds[12:20])
    mips = max(1, struct.unpack("<I", dds[28:32])[0])
    pixels = dds[128:]
    packed = zlib.compress(pixels, 9)

    header_size = 24
    record_size = 24 + 24          # file record + one chunk record
    data_offset = header_size + record_size
    name_table_offset = data_offset + len(packed)

    header = struct.pack("<4sI4sIQ", b"BTDX", 1, b"DX10", 1, name_table_offset)
    record = struct.pack("<I4sIBBHHHBBH", NAME_HASH, b"dds\0", DIR_HASH, 0, 1, 24,
                         height, width, mips, DXGI_BC1_UNORM, 0x800)
    chunk = struct.pack("<QIIHHI", data_offset, len(packed), len(pixels), 0, mips - 1, 0xBAADF00D)
    name = ARCHIVE_PATH.encode()
    name_table = struct.pack("<H", len(name)) + name

    OUT.write_bytes(header + record + chunk + packed + name_table)
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
