#!/usr/bin/env python3
"""Device-tree properties: the entry-role properties in /chosen use the same
"kshim," prefix as the others the shim reads.

  0002-chosen-properties.py SOURCE_TREE

The shim reads <prefix>,boot-stage and <prefix>,root-medium from the Linux
entry's /chosen to decide which entry is the installed system. The prefix is
renamed to "kshim," in the shim and in its tests; the packer side
(tablet-bootmenu-install) writes the same names. The old prefix is read from
the tree and written to .removed-names for the final check on the image.
"""
import re
import sys
from pathlib import Path

K = Path(sys.argv[1])
main = (K / "src/core/main.c").read_text(encoding="utf-8")
m = re.search(r'"([a-z0-9]+),boot-stage"', main)
if not m:
    sys.exit("0002-chosen-properties: no boot-stage property in main.c")
prefix = m.group(1)
if prefix == "kshim":
    sys.exit("0002-chosen-properties: already renamed")
pat = re.compile(r'\b%s,(boot-stage|root-medium)\b' % re.escape(prefix))
count = 0
for base in ("src", "tests"):
    for path in sorted((K / base).rglob("*")):
        if not path.is_file() or path.suffix not in (".c", ".h", ".py", ".S"):
            continue
        text = path.read_text(encoding="utf-8")
        new, n = pat.subn(r"kshim,\1", text)
        if n:
            path.write_text(new, encoding="utf-8")
            count += n
if count < 2:
    sys.exit("0002-chosen-properties: expected the properties in main.c")
with (K / ".removed-names").open("a") as f:
    f.write(prefix + "\n")
print(f"{count} property names renamed")
