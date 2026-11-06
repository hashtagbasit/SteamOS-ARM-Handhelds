#!/usr/bin/env python3
"""Menu text: the Linux entry is called SteamOS (English and Chinese).

  0001-menu-text-steamos.py SOURCE_TREE

Replaces the entry names, their descriptions and the credit line in the locale
table and in the fixed-text header, and the same text in the host tests. The
old wording is read from the tree before it changes, so the tool needs no
knowledge of it; the words it removed are written to .removed-names for the
final check on the built image. Fails if the tree isn't in the expected shape.
"""
import re
import sys
from pathlib import Path

K = Path(sys.argv[1])
LOCALE = K / "src/core/menu_locale.c"
HEADER = K / "src/include/menu_text.h"

NEW = {
    "NAME_INTERNAL": ("Zaviya", "Zaviya"),
    "NAME_TF": ("Zaviya (TF 卡)", "Zaviya (TF card)"),
    "DESC_INTERNAL": ("启动 Zaviya。", "Start Zaviya."),
    "DESC_TF": ("启动 TF 卡中的 Zaviya，请先插入对应 TF 卡。",
                "Start Zaviya from the TF card. Insert the matching card first."),
    "CREDIT": ("Zaviya", "Zaviya"),
}


def die(msg):
    sys.exit("0001-menu-text-steamos: " + msg)


def replace_pairs(text, pattern, new_pair, what, old_out):
    """Replace the two (Chinese, then English) literals matching pattern."""
    hits = list(re.finditer(pattern, text))
    if len(hits) != 2:
        die(f"{what}: expected 2 matches, found {len(hits)}")
    out, last = [], 0
    for m, new in zip(hits, new_pair):
        out.append(text[last:m.start(2)] + new)
        last = m.end(2)
        old_out.append((m.group(2), new))
    out.append(text[last:])
    return "".join(out)


locale = LOCALE.read_text(encoding="utf-8")
header = HEADER.read_text(encoding="utf-8")
old = []  # (old literal, new literal), for the tests
for key in NEW:
    locale = replace_pairs(
        locale, r'(\[KSHIM_TEXT_%s\]\s*=\s*")([^"]*)(")' % key, NEW[key],
        "locale " + key, old)
for key, fixed in (("DESC_INTERNAL", "KSHIM_MENU_DESC_INTERNAL"),
                   ("DESC_TF", "KSHIM_MENU_DESC_TF"),
                   ("CREDIT", "KSHIM_MENU_TEXT_CREDIT")):
    pat = r'(#define %s ")([^"]*)(")' % fixed
    header = replace_pairs(header, pat, NEW[key], "header " + key, [])
LOCALE.write_text(locale, encoding="utf-8")
HEADER.write_text(header, encoding="utf-8")

# The name of the removed OS: the word after the Chinese "internal" prefix of
# the old entry name.
name_zh = old[0][0]
m = re.fullmatch(r"机身\s*(\S+)", name_zh)
if not m:
    die("unexpected old entry name: " + name_zh)
token = m.group(1)

# Tests: longest literal first, then the bare word (countdown strings).
literals = sorted((o for o in old if o[0]), key=lambda p: -len(p[0]))
for path in sorted((K / "tests").glob("*.c")) + sorted((K / "tests").glob("*.py")):
    text = path.read_text(encoding="utf-8")
    orig = text
    for o, n in literals:
        text = text.replace(o, n)
    text = text.replace(token, "SteamOS")
    if text != orig:
        path.write_text(text, encoding="utf-8")

# The locale test checks that the internal entry's description says "internal
# storage"; the new description names the system instead.
path = K / "tests/menu_locale_test.c"
text = path.read_text(encoding="utf-8")
frag = '"机身存储", "internal storage"'
if text.count(frag) != 1:
    die("menu_locale_test.c: description fragments not found")
path.write_text(text.replace(frag, '"SteamOS", "SteamOS"'), encoding="utf-8")

# The system's name is the same in both languages now.
text = path.read_text(encoding="utf-8")
old = "assert(strcmp(zh_names[i], en_names[i]) != 0);"
if text.count(old) != 1:
    die("menu_locale_test.c: name comparison not found")
path.write_text(text.replace(
    old, "if (role_cases[i].role != KSHIM_MENU_ROLE_INTERNAL)\n            " + old), encoding="utf-8")

# The credit line is now fixed text: the test checks that text instead.
text = path.read_text(encoding="utf-8")
text, n = re.subn(r'assert\(contains\(KSHIM_MENU_TEXT_CREDIT, "[^"]*"\)\);\n\s*'
                  r'assert\(contains\(KSHIM_MENU_TEXT_CREDIT, "[^"]*"\)\);',
                  'assert(contains(KSHIM_MENU_TEXT_CREDIT, "SteamOS"));', text)
if n != 1:
    die("menu_locale_test.c: credit assertions not found")
path.write_text(text, encoding="utf-8")

with (K / ".removed-names").open("a") as f:
    f.write(token + "\n")
print("menu text patched")
