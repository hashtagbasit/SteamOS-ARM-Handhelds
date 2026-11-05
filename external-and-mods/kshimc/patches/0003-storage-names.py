#!/usr/bin/env python3
"""Storage code: the upper-case prefix of the backup partition name and size
constants becomes KSHIM_.

  0003-storage-names.py SOURCE_TREE

storage_block.c is linked into the runtime even without any storage access
(the build config has none), and its partition name string would show up in
the image. The prefix is read from the tree; the words it removed are appended
to .removed-names for the final check on the image.
"""
import re
import sys
from pathlib import Path

K = Path(sys.argv[1])
text = (K / "src/core/storage_block.c").read_text(encoding="utf-8")
m = re.search(r'"([A-Z][A-Z0-9]+)_BACKUP"', text)
if not m:
    sys.exit("0003-storage-names: no backup partition name in storage_block.c")
prefix = m.group(1)
pat = re.compile(r'\b%s_(?=[A-Z])' % re.escape(prefix))
count = 0
for base in ("src", "tests"):
    for path in sorted((K / base).rglob("*")):
        if not path.is_file() or path.suffix not in (".c", ".h", ".py", ".S"):
            continue
        t = path.read_text(encoding="utf-8")
        new, n = pat.subn("KSHIM_", t)
        if n:
            path.write_text(new, encoding="utf-8")
            count += n
if count < 2:
    sys.exit("0003-storage-names: expected the prefix in more than one place")
with (K / ".removed-names").open("a") as f:
    f.write(prefix + "\n")
print(f"{count} storage names renamed")
