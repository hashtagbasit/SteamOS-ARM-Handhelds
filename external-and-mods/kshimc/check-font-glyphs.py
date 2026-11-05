#!/usr/bin/env python3
"""Every character of the menu text must have a glyph in the embedded font.

  check-font-glyphs.py SOURCE_TREE REQUIRED_TEXT_FILE [--write]

The menu font is a subset (tools/gen_ui_font.py --coverage menu) holding the
characters of src/core/menu_locale.c and src/include/menu_text.h. This reads
both files of the (patched) tree, takes their characters and checks the
font's cmap. REQUIRED_TEXT_FILE is the list of those characters (the input of
gen_ui_font.py --required-text); it must match the tree, --write updates it.
Needs fonttools and lz4. Exit 1 if a glyph is missing or the list is stale.
"""
import io
import struct
import sys
import zlib
from pathlib import Path

import lz4.block
from fontTools.ttLib import TTFont

K = Path(sys.argv[1])
REQ = Path(sys.argv[2])
font_path = K / "src/ui/fonts/lxgw_wenkai_menu.ksf"

chars = set()
for rel in ("src/core/menu_locale.c", "src/include/menu_text.h"):
    chars |= {c for c in (K / rel).read_text(encoding="utf-8") if not c.isspace()}
text = "".join(sorted(chars, key=ord)) + "\n"
stale = not REQ.exists() or REQ.read_text(encoding="utf-8") != text
if stale and "--write" in sys.argv:
    REQ.write_text(text, encoding="utf-8")
    print(f"{REQ.name}: rewritten ({len(chars)} characters)")
    stale = False

blob = font_path.read_bytes()
if blob[:4] != b"KSF1":
    sys.exit("check-font-glyphs: not a KSF1 font blob")
raw_size, packed_size, crc = struct.unpack_from("<III", blob, 4)
raw = lz4.block.decompress(blob[16:16 + packed_size], uncompressed_size=raw_size)
if zlib.crc32(raw) & 0xFFFFFFFF != crc:
    sys.exit("check-font-glyphs: font CRC mismatch")
cmap = TTFont(io.BytesIO(raw)).getBestCmap()
missing = sorted(ord(c) for c in chars if ord(c) not in cmap)
if missing:
    print("glyphs missing: " + " ".join("%s (U+%04X)" % (chr(c), c) for c in missing))
    sys.exit(1)
if stale:
    print(f"{REQ.name} doesn't match the menu text (run with --write)")
    sys.exit(1)
print(f"font ok: {len(chars)} menu characters, {len(cmap)} glyphs in the font")
