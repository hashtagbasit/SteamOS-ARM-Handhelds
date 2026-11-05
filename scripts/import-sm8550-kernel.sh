#!/usr/bin/env bash
# Import a prebuilt SM8550 kernel (KERNEL + modules + firmware) from
# a released image into a kernel output dir that make-steamos-sm8650.sh /
# apply-overlays.sh take like one of ours:
#   <out>/<krel>/boot/KERNEL(.md5)  modules/<krel>  firmware/  config-<krel>
# Usage (as root, in the build VM):
#   scripts/import-sm8550-kernel.sh <SteamOS-ARM-sm8550.img[.gz]> [out-parent]
set -euo pipefail

src="${1:?image (.img or .img.gz)}"
parent="${2:-/work/kernel-prebuilt}"
work="$(mktemp -d /work/.kernel-import.XXXX)"
loop=""
cleanup() {
  umount "$work/boot" "$work/root" 2>/dev/null || true
  [[ -n "$loop" ]] && losetup -d "$loop" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

img="$src"
if [[ "$src" == *.gz ]]; then
  img="${src%.gz}"
  [[ -f "$img" ]] || { echo "decompressing to $img"; gzip -dc "$src" >"$img.part" && mv "$img.part" "$img"; }
fi

loop="$(losetup -fP --show -r "$img")"
mkdir -p "$work/boot" "$work/root"
bootp="" rootp=""
for p in "${loop}"p*; do
  t="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
  if [[ "$t" == vfat && -z "$bootp" ]]; then
    mount -o ro "$p" "$work/boot"
    if [[ -f "$work/boot/KERNEL" ]]; then bootp="$p"; else umount "$work/boot"; fi
  elif [[ "$t" == ext4 && -z "$rootp" ]]; then
    mount -o ro,noload "$p" "$work/root"
    if [[ -d "$work/root/usr/lib/modules" ]]; then rootp="$p"; else umount "$work/root"; fi
  fi
done
[[ -n "$bootp" && -n "$rootp" ]] || { echo "BOOT ($bootp) or root ($rootp) not found" >&2; exit 1; }

# Their image carries an old 6.18 module dir too; take the KERNEL's release.
krel="$(python3 - "$work/boot/KERNEL" <<'PY'
import re, struct, sys, zlib
d = open(sys.argv[1], "rb").read()
ks, = struct.unpack_from("<I", d, 8)
ps, = struct.unpack_from("<I", d, 36)
img = zlib.decompressobj(31).decompress(d[ps:ps + ks])
print(re.search(rb"Linux version (\S+)", img).group(1).decode())
PY
)"
[[ -d "$work/root/usr/lib/modules/$krel" ]] || { echo "no modules for $krel" >&2; exit 1; }
out="$parent/$krel"
echo "BOOT=$bootp root=$rootp kernel=$krel -> $out"

rm -rf "$out"
mkdir -p "$out/boot" "$out/modules" "$out/firmware"
install -m0644 "$work/boot/KERNEL" "$out/boot/KERNEL"
(cd "$out/boot" && md5sum KERNEL >KERNEL.md5)
cp -a "$work/root/usr/lib/modules/$krel" "$out/modules/$krel"
for c in "$work/root/boot/config-$krel" "$work/root/usr/lib/modules/$krel/config"; do
  [[ -f "$c" ]] && { cp "$c" "$out/config-$krel"; break; }
done

# Firmware: only what this kernel's SM8550 devices load (GPU, DSPs, audio
# topology/amp tuning, panels). Everything else stays the Frame's.
fw="$work/root/usr/lib/firmware"
for f in qcom/sm8550 qcom/a740_sqe.fw qcom/gmu_gen70200.bin qcom/vpu; do
  for g in "$fw/$f" "$fw/$f".zst "$fw/$f".xz; do
    [[ -e "$g" ]] || continue
    mkdir -p "$out/firmware/$(dirname "$f")"
    cp -a "$g" "$out/firmware/$(dirname "$f")/"
  done
done

# The image links whole device dirs to the Odin 2's files (ayaneo -> ayn/odin2,
# ayn/odin2mini|odin2portal -> odin2). The rootfs already has real
# per-device dirs there (own amp tuning, AYANEO's own DSP split as .mdt), and
# rsync can't put a link over a dir. So: keep the real dirs, and give AYANEO
# the names its DTBs ask for, resolving to what that image loads.
s="$out/firmware/qcom/sm8550"
if [[ -L "$s/ayaneo" ]]; then
  rm "$s/ayaneo"
  mkdir -p "$s/ayaneo"
  for f in adsp.mbn adsp_dtb.mbn; do ln -s "../ayn/odin2/$f" "$s/ayaneo/$f"; done
  ln -s ../ayn/a740_zap.mbn "$s/ayaneo/a740_zap.mbn"
fi
for d in odin2mini odin2portal; do [[ -L "$s/ayn/$d" ]] && rm "$s/ayn/$d"; done

# Boot file: the kernel section (Image.gz + their appended DTBs) untouched,
# with OUR busybox initramfs (bootlog.txt, debug file, update recovery) as the
# ramdisk at the beta 2 addresses. A tester's hybrid with exactly this layout
# reached switch_root on an Odin 2; the image's own Debian initramfs is kept aside.
repo="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
kc="$repo/external-and-mods/kernel-common"
mv "$out/boot/KERNEL" "$out/boot/KERNEL.orig"
python3 - "$out/boot/KERNEL.orig" "$work/kernel.bin" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
assert d[:8] == b"ANDROID!"
ks, = struct.unpack_from("<I", d, 8)
ps, = struct.unpack_from("<I", d, 36)
k = d[ps:ps + ks]
# The appended DTBs follow the gzipped Image. Its AYANEO Pocket trees give
# the GPU "qcom,adreno-43050a00", which Mesa takes for an Adreno A32 (G3x
# Gen 2), so Turnip drove the 740 wrong and the screen stayed black (EVO,
# beta 5). The AYN/Retroid trees and upstream sm8550.dtsi use 43050a01.
# Same length, so a byte swap keeps every DTB intact.
import zlib
z = zlib.decompressobj(31); z.decompress(k)
img_len = len(k) - len(z.unused_data)
bad, good = b"qcom,adreno-43050a00", b"qcom,adreno-43050a01"
n = k[img_len:].count(bad)
k = k[:img_len] + k[img_len:].replace(bad, good)
print(f"dtb fixup: {n} x {bad.decode()} -> {good.decode()}")

# Touch: the RP6 and Thor trees pre-rotate their touchscreens (swapped-x-y +
# inverted-x) for a compositor that doesn't rotate touch itself. gamescope
# and KWin rotate touch by the panel orientation, so it got rotated twice
# (RP6 tester: taps land in the wrong place). Keep panel-native coordinates:
# the RP6 keeps inverted-y (its sensor is flipped),
# the Odin 2 Mini keeps its flags (its sensor is mounted sideways).
import re, subprocess, tempfile
TOUCH_FIX = {b"Retroid Pocket 6", b"AYN Thor"}
DROP = ("touchscreen-swapped-x-y;", "touchscreen-inverted-x;")
dtbs, rest, i = [], k[img_len:], 0
while True:
    a = rest.find(b"\xd0\x0d\xfe\xed", i)
    if a < 0:
        break
    size = int.from_bytes(rest[a + 4:a + 8], "big")
    dtbs.append(rest[a:a + size]); i = a + size
out = []
for b in dtbs:
    names = set(re.findall(rb"(AYN Thor|Retroid Pocket 6)(?=[\x00 ])", b))
    if not names & TOUCH_FIX:
        out.append(b); continue
    with tempfile.TemporaryDirectory() as td:
        open(f"{td}/in.dtb", "wb").write(b)
        dec = lambda f: subprocess.run(["dtc", "-q", "-I", "dtb", "-O", "dts", f], check=True, capture_output=True, text=True).stdout
        dts = dec(f"{td}/in.dtb")
        # Find the touchscreen nodes' paths from the decompiled tree, then
        # delete the flags in the binary with fdtput. No dts -> dtb compile:
        # dtc prints some u32s as strings ("\0" "2K" for vreg_bob1's 3296000)
        # and reads them back wrong ("\02K" -> 02 4b 00). That broke the
        # main regulator in beta 8 and the RP6 and Thor stopped booting.
        stack, edits = [], []
        for line in dts.splitlines():
            m = re.match(r"\s*(?:[\w-]+:\s*)?([^\s{]+) \{$", line)
            if m:
                stack.append("" if m.group(1) == "/" else m.group(1)); continue
            if line.strip() == "};":
                stack.pop(); continue
            if stack and stack[-1].startswith("touchscreen@") and line.strip() in DROP:
                edits.append(("/".join(stack) or "/", line.strip()[:-1]))
        for node, prop in edits:
            subprocess.run(["fdtput", "-d", f"{td}/in.dtb", node, prop], check=True)
        dropped = len(edits)
        nb = open(f"{td}/in.dtb", "rb").read()
        # Straight decompile of both binaries: only the dropped lines may differ.
        before, after = dts.splitlines(), dec(f"{td}/in.dtb").splitlines()
        gone = [l for l in before if l not in after]
        assert len(before) - len(after) == dropped and all(l.strip() in DROP for l in gone), \
            "dtb edit changed more than the touch flags"
    print(f"touch fixup: {', '.join(x.decode() for x in names)}: dropped {dropped} flags")
    out.append(nb)
assert sum(map(len, dtbs)) == len(rest), "unexpected data between the DTBs"
k = k[:img_len] + b"".join(out)
open(sys.argv[2], "wb").write(k)
PY
rd="$work/initramfs"
mkdir -p "$rd/root/bin" "$rd/root/dev" "$rd/root/proc" "$rd/root/sys"
cp /bin/busybox "$rd/root/bin/busybox"
file -L /bin/busybox | grep -q "statically linked" || { echo "need static busybox" >&2; exit 1; }
install -m0755 "$kc/initramfs/init" "$rd/root/init"
install -m0755 "$kc/initramfs/konkr-update-recover" "$rd/root/konkr-update-recover"
install -m0755 "$kc/initramfs/bootdebug" "$rd/root/bootdebug"
(cd "$rd/root" && find . | cpio -o -H newc --owner=0:0 2>/dev/null) | gzip -9 -n >"$rd/initrd.gz"
python3 "$kc/mkbootimg-v0.py" --kernel "$work/kernel.bin" --ramdisk "$rd/initrd.gz" \
  --kernel-addr 0x10008000 --ramdisk-addr 0x16000000 --tags-addr 0x10000100 \
  --cmdline "root=PARTUUID=00000000-02" --out "$out/boot/KERNEL"
(cd "$out/boot" && md5sum KERNEL >KERNEL.md5)
# Extra modules this kernel lacks, built against a vanilla tree of the same
# release with its own config (no MODVERSIONS/signing, so vermagic is all it
# checks): sgm3804 powers the Pocket DMG / ACE panel (the base tree's driver).
kver="${krel%%-*}"
ksrc="/work/sgm/linux-$kver"
if [[ ! -d "$ksrc" ]]; then
  mkdir -p /work/sgm
  curl -sfL "https://cdn.kernel.org/pub/linux/kernel/v${kver%%.*}.x/linux-$kver.tar.xz" | tar -xJ -C /work/sgm
fi
cp "$out/config-$krel" "$ksrc/.config" 2>/dev/null || python3 - "$work/boot/KERNEL" "$ksrc/.config" <<'PY'
import struct, sys, zlib
d = open(sys.argv[1], "rb").read()
ks, = struct.unpack_from("<I", d, 8); ps, = struct.unpack_from("<I", d, 36)
img = zlib.decompressobj(31).decompress(d[ps:ps + ks])
i = img.find(b"IKCFG_ST")
open(sys.argv[2], "wb").write(zlib.decompressobj(31).decompress(img[i + 8:]))
PY
make -s -C "$ksrc" olddefconfig >/dev/null
make -s -C "$ksrc" -j"$(nproc)" modules_prepare
[[ "$(cat "$ksrc/include/config/kernel.release")" == "$krel" ]] || { echo "extra modules: release mismatch" >&2; exit 1; }
for m in "$repo"/external-and-mods/kernel-sm8550/extra-modules/*/; do
  b="$work/extra-$(basename "$m")"; cp -r "$m" "$b"
  make -s -C "$ksrc" M="$b" KBUILD_MODPOST_WARN=1 modules 2>/dev/null
  for ko in "$b"/*.ko; do
    strip --strip-debug "$ko"
    install -D -m0644 "$ko" "$out/modules/$krel/extra/$(basename "$ko")"
    echo "extra module: $(basename "$ko")"
  done
done
# qcom_battmgr with our battery fixes (kernel-sm8550/patches/*qcom-battmgr*:
# charge unit / CHARGE_NOW, steady discharge current): without it charge_full reads "no data" and there is no charge_now,
# so nothing can work out the time left and Steam shows "?h ?m". Built the
# same way and put over the stock module.
bm="$work/extra-qcom_battmgr"; rm -rf "$bm"; mkdir -p "$bm"
cp "$ksrc/drivers/power/supply/qcom_battmgr.c" "$bm/"
for bp in "$repo"/external-and-mods/kernel-sm8550/patches/*qcom-battmgr*.patch; do
  patch -s -d "$bm" -p4 <"$bp"
done
echo "obj-m += qcom_battmgr.o" >"$bm/Makefile"
make -s -C "$ksrc" M="$bm" KBUILD_MODPOST_WARN=1 modules 2>/dev/null
strip --strip-debug "$bm/qcom_battmgr.ko"
bm_dst="$(find "$out/modules/$krel/kernel" -name qcom_battmgr.ko | head -1)"
[[ -n "$bm_dst" ]] || { echo "qcom_battmgr.ko not in $krel" >&2; exit 1; }
install -m0644 "$bm/qcom_battmgr.ko" "$bm_dst"
echo "patched module: qcom_battmgr.ko"
mkdir -p "$work/dm/lib" && ln -sfn "$out/modules" "$work/dm/lib/modules"
depmod -b "$work/dm" "$krel"
chown -R -h root:root "$out"
du -sh "$out"/* "$out"/boot/* | sed "s|$out/||"
