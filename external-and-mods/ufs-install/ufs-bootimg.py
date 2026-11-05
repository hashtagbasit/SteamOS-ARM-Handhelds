#!/usr/bin/env python3
"""Read, check and retarget the ABL KERNEL (Android boot image, header v0).

  ufs-bootimg.py info    KERNEL
  ufs-bootimg.py check   KERNEL        initramfs can mount root=PARTLABEL=
  ufs-bootimg.py retarget KERNEL OUT --root PARTLABEL=STORAGE

retarget rewrites the image with the same kernel, ramdisk and header fields
and a new cmdline (only root=, rootfstype= and errors= change), and
recomputes the header id the way mkbootimg does
(external-and-mods/kernel-sm8650/mkbootimg-v0.py), so the image is exactly
what a fresh build with that cmdline would produce.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import lzma
import struct
import zlib
import sys
from pathlib import Path

MAGIC = b"ANDROID!"
HDR = struct.Struct("<8s10I16s512s32s1024s")


class BootImg:
    def __init__(self, data: bytes):
        if data[:8] != MAGIC:
            raise SystemExit("not an Android boot image (no ANDROID! magic)")
        f = HDR.unpack_from(data)
        (self.magic, self.kernel_size, self.kernel_addr, self.ramdisk_size,
         self.ramdisk_addr, self.second_size, self.second_addr, self.tags_addr,
         self.page_size, self.header_version, self.os_version, self.name,
         cmd, self.id, extra) = f
        if self.header_version != 0:
            raise SystemExit(f"header v{self.header_version}, expected v0")
        if self.page_size not in (2048, 4096):
            raise SystemExit(f"odd page size {self.page_size}")
        self.cmdline = cmd.rstrip(b"\0").decode("ascii", "replace")
        self.extra = extra
        p = self.page_size
        off = p
        self.kernel = data[off:off + self.kernel_size]
        off += -(-self.kernel_size // p) * p
        self.ramdisk = data[off:off + self.ramdisk_size]
        off += -(-self.ramdisk_size // p) * p
        self.second = data[off:off + self.second_size]
        if len(self.kernel) != self.kernel_size or len(self.ramdisk) != self.ramdisk_size:
            raise SystemExit("truncated boot image")

    def expected_id(self) -> bytes:
        sha = hashlib.sha1()
        for blob in (self.kernel, self.ramdisk, self.second):
            sha.update(blob)
            sha.update(struct.pack("<I", len(blob)))
        return sha.digest().ljust(32, b"\0")

    def build(self, cmdline: str) -> bytes:
        cmd = cmdline.encode("ascii")
        if len(cmd) >= 512:
            raise SystemExit(f"cmdline too long ({len(cmd)} >= 512)")
        hdr = HDR.pack(MAGIC, self.kernel_size, self.kernel_addr,
                       self.ramdisk_size, self.ramdisk_addr, self.second_size,
                       self.second_addr, self.tags_addr, self.page_size, 0,
                       self.os_version, self.name, cmd, self.expected_id(),
                       self.extra)
        p = self.page_size

        def pad(b: bytes) -> bytes:
            return b + b"\0" * (-len(b) % p)
        return pad(hdr) + pad(self.kernel) + pad(self.ramdisk) + pad(self.second)


def ramdisk_bytes(rd: bytes) -> bytes:
    if rd[:2] == b"\x1f\x8b":
        return gzip.decompress(rd)
    if rd[:6] == b"\xfd7zXZ\x00":
        return lzma.decompress(rd)
    if rd[:4] == b"\x28\xb5\x2f\xfd":
        try:
            import zstandard  # type: ignore
            return zstandard.ZstdDecompressor().decompressobj().decompress(rd)
        except ImportError:
            import subprocess
            return subprocess.run(["zstd", "-dc"], input=rd, capture_output=True,
                                  check=True).stdout
    return rd                                   # plain cpio (or the "dummy" ramdisk)


def initramfs_bytes(img: BootImg) -> bytes:
    """The initramfs: the bootimg ramdisk, or with a dummy ramdisk (SM8550,
    like the base kernel) the uncompressed cpio built into the gzipped kernel Image."""
    raw = ramdisk_bytes(img.ramdisk)
    if raw[:6] == b"070701" or img.kernel[:2] != b"\x1f\x8b":
        return raw
    return zlib.decompressobj(31).decompress(img.kernel)


def partlabel_capable(img: BootImg) -> bool:
    raw = initramfs_bytes(img)
    return b"070701" in raw and b"PARTLABEL=" in raw


def retarget(cmdline: str, root: str) -> str:
    keep = [t for t in cmdline.split()
            if not t.startswith(("root=", "rootfstype=", "errors="))]
    return " ".join(keep + [f"root={root}", "rootfstype=ext4", "errors=remount-ro"])


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for n in ("info", "check"):
        sub.add_parser(n).add_argument("kernel")
    r = sub.add_parser("retarget")
    r.add_argument("kernel")
    r.add_argument("out")
    r.add_argument("--root", required=True)
    a = ap.parse_args()

    img = BootImg(Path(a.kernel).read_bytes())
    if a.cmd == "info":
        print(f"CMDLINE={img.cmdline}")
        print(f"PAGE_SIZE={img.page_size}")
        print(f"KERNEL_SIZE={img.kernel_size}")
        print(f"RAMDISK_SIZE={img.ramdisk_size}")
        print(f"ID_OK={'yes' if img.id == img.expected_id() else 'no'}")
        print(f"PARTLABEL_ROOT={'yes' if partlabel_capable(img) else 'no'}")
    elif a.cmd == "check":
        if not partlabel_capable(img):
            sys.exit("KERNEL has no initramfs that understands root=PARTLABEL= "
                     "(the SD image is too old for an internal install)")
        print("ok")
    else:
        new = retarget(img.cmdline, a.root)
        out = img.build(new)
        again = BootImg(out)
        assert again.kernel == img.kernel and again.ramdisk == img.ramdisk
        assert again.cmdline == new and again.id == again.expected_id()
        Path(a.out).write_bytes(out)
        print(f"CMDLINE={new}")


if __name__ == "__main__":
    main()
