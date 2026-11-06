#!/usr/bin/env bash
# Zaviya on the Lenovo Legion Y700 Gen 5 (TB323FU), from a PC (Linux or
# macOS; Windows: WSL2) with adb. Android stays on the tablet.
#
#   install-gen5.sh [--switch]
#
# Before: the tablet rooted without unlocking (LTBox + KernelSU, ZUI
# 18.0.12.104), adb with root allowed for the shell, and the microSD card
# written with steamos-gen5-card.img and back in the tablet.
#
# What it does, each step checked before anything is written:
#   1. checks the tablet, its firmware version and root
#   2. keeps your own Android boot image in boot_b (the way back; once)
#   3. copies the tablet's firmware out of Android (signed for the device,
#      it can't be shipped) and puts it on the card
#   4. builds SteamOS's boot image from your own Android boot image and our
#      kernel (the bootloader only takes one with its stock signature blob)
#   5. stages it for the "Switch to SteamOS" KernelSU module
#   6. with --switch: writes it to boot_a and restarts into SteamOS
# Back to Android: Restart into ZUXOS in Zaviya Control, or hold volume up
# + volume down for 10 s.
set -Eeuo pipefail
# Never stop without saying why.
trap 'printf "\nERROR: stopped at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$HERE/Image-gen5"
MANIFEST="$HERE/firmware.tsv"
MODULE="$HERE/switch-to-steamos"
WANT_FW=18.0.12.104
D=/data/adb/steamos-gen5
SWITCH=0; [[ "${1:-}" == --switch || "${1:-}" == -switch ]] && SWITCH=1
# adb: ADB=/path/to/adb, else adb, else Windows' adb.exe (WSL). adb.exe
# prints CRLF and can't open WSL paths, so its output is stripped of \r and
# the work folder sits next to this script, on the Windows drive.
ADB="${ADB:-}"
if [[ -z "$ADB" ]]; then
  if command -v adb >/dev/null; then ADB=adb; elif command -v adb.exe >/dev/null; then ADB=adb.exe; fi
fi
WIN=0; [[ "$ADB" == *.exe ]] && WIN=1
adb() { "$ADB" "$@"; }
host() { if ((WIN)) && command -v wslpath >/dev/null; then wslpath -w "$1"; else printf '%s' "$1"; fi; }
if ((WIN)); then W="$(mktemp -d "$HERE/.work.XXXXXX")"; else W="$(mktemp -d)"; fi
trap 'rm -rf "$W"' EXIT
say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
su_() { adb shell "su -c '$*'" | tr -d '\r'; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
[[ -n "$ADB" ]] && command -v "$ADB" >/dev/null || die "needs adb (or ADB=/mnt/c/platform-tools/adb.exe from WSL)"
for t in python3 tar; do command -v $t >/dev/null || die "needs $t"; done
for f in "$KERNEL" "$MANIFEST" "$MODULE/action.sh" "$HERE/boot-repack.py"; do [[ -e "$f" ]] || die "missing $f (run from the unpacked release)"; done

say "1. The tablet"
[[ "$(adb get-state 2>/dev/null | tr -d '\r')" == device ]] || die "no tablet over adb (USB debugging on, one device)"
model="$(adb shell getprop ro.product.model | tr -d '\r') $(adb shell getprop ro.product.device | tr -d '\r')"
grep -qi "TB323FU\|baldur" <<<"$model" || die "this is not a Legion Y700 Gen 5 ($model)"
fw="$(adb shell getprop ro.build.display.id | tr -d '\r')"
echo "firmware: $fw"
grep -q "$WANT_FW" <<<"$fw" || die "only ZUI $WANT_FW is known to work (newer firmware hangs at boot and can't be downgraded)"
[[ "$(su_ id)" == *"uid=0"* ]] || die "no root for the adb shell (KernelSU: allow Shell)"
bootdir=/dev/block/by-name
a="$(su_ readlink -f $bootdir/boot_a)"; b="$(su_ readlink -f $bootdir/boot_b)"
[[ -n "$a" && -n "$b" && "$a" != "$b" ]] || die "boot_a / boot_b not found"
sa="$(su_ sha256sum $a | cut -d' ' -f1)"; sb="$(su_ sha256sum $b | cut -d' ' -f1)"

say "2. Your Android boot image, kept in boot_b"
prev="$(su_ cat $D/android.sha256 2>/dev/null | cut -d' ' -f1 || true)"
if [[ ${#prev} == 64 ]]; then
  [[ "$sb" == "$prev" ]] || die "boot_b isn't the Android image recorded at the last install: stopping"
  android="$prev"; echo "boot_b already holds it ($android)"
else
  # First install: Android is running, so boot_a is its boot image.
  android="$sa"
  if [[ "$sb" != "$sa" ]]; then
    echo "boot_a (Android) -> boot_b"
    su_ dd if=$a of=$b bs=4096 conv=fsync >/dev/null 2>&1
    su_ "echo 3 > /proc/sys/vm/drop_caches"
    [[ "$(su_ sha256sum $b | cut -d' ' -f1)" == "$android" ]] || die "boot_b doesn't verify after the copy"
  fi
  su_ "mkdir -p $D && echo $android > $D/android.sha256"
fi
adb exec-out "su -c 'cat $b'" > "$W/stock-boot.img"
[[ "$(sha "$W/stock-boot.img")" == "$android" ]] || die "the copy of the Android boot image on the PC doesn't verify"
echo "Android boot image $android"

say "3. Firmware from the tablet's Android"
paths=()
while IFS=$'\t' read -r target hash src how; do
  [[ "$target" == \#* || -z "$target" ]] && continue
  if [[ "$how" == squash ]]; then paths+=("$src" "${src%.mdt}.b*"); else paths+=("$src"); fi
done < "$MANIFEST"
adb exec-out "su -c 'cd / && tar -cf - $(printf '%s ' "${paths[@]#/}") 2>/dev/null'" > "$W/fw-src.tar"
# Tar to tar, never through folders on the PC: on Windows and macOS disks
# qcom/kaanapali/Lenovo/ (the GPU's zap shader) and qcom/kaanapali/lenovo/
# (everything else) are one folder, and the GPU never found its zap shader.
python3 - "$MANIFEST" "$W/fw-src.tar" "$W/firmware.tar" <<'PY'
import hashlib, io, struct, sys, tarfile, time
manifest, src, out = sys.argv[1:]
files = {}
with tarfile.open(src) as t:
    for m in t:
        if m.isfile(): files["/" + m.name.lstrip("./")] = t.extractfile(m).read()
def read(path):
    if path not in files: raise OSError("not on the tablet")
    return files[path]
def squash(mdt):
    """Qualcomm split image (X.mdt + X.bNN) back into one ELF, each segment at its p_offset."""
    data = read(mdt)
    if data[:4] != b"\x7fELF": raise ValueError("not an ELF")
    is64 = data[4] == 2
    phoff = struct.unpack_from("<Q" if is64 else "<I", data, 0x20 if is64 else 0x1c)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36 if is64 else 0x2a)
    img = bytearray(data[:phoff + phnum * phentsize])
    for i in range(phnum):
        ph = phoff + i * phentsize
        off, size = (struct.unpack_from("<Q", data, ph + 8)[0], struct.unpack_from("<Q", data, ph + 0x20)[0]) if is64 \
            else (struct.unpack_from("<I", data, ph + 4)[0], struct.unpack_from("<I", data, ph + 0x10)[0])
        if not size: continue
        seg = f"{mdt[:-4]}.b{i:02d}"
        if seg in files: chunk = files[seg]
        elif off + size <= len(data): chunk = data[off:off + size]
        else: raise ValueError(f"missing {seg.rsplit('/', 1)[1]}")
        if len(chunk) != size: raise ValueError(f"{seg.rsplit('/', 1)[1]} has the wrong size")
        if len(img) < off: img += bytes(off - len(img))
        img[off:off + size] = chunk
    return bytes(img)
missing, other, n = [], 0, 0
with tarfile.open(out, "w") as t:
    for line in open(manifest):
        if line.startswith("#") or not line.strip(): continue
        target, want, srcpath, how = line.rstrip("\n").split("\t")
        try:
            blob = squash(srcpath) if how == "squash" else read(srcpath)
        except (OSError, ValueError) as e:
            missing.append(f"{target} ({e})"); continue
        if hashlib.sha256(blob).hexdigest() != want: other += 1
        m = tarfile.TarInfo("./" + target); m.size = len(blob); m.mode = 0o644; m.mtime = int(time.time())
        t.addfile(m, io.BytesIO(blob)); n += 1
print(f"firmware: {n} files" + (f", {other} differ from the 18.0.12.104 set" if other else ""))
if missing:
    print("missing:\n  " + "\n  ".join(missing)); sys.exit(1)
PY
echo "$android" > "$W/android-boot.sha256"

say "   ... onto the microSD card"
# The loop's last grep fails for every partition after the match, and adb
# hands that status back: with pipefail it ended the script here silently.
part() { { adb shell "su -c 'for u in /sys/class/block/*/uevent; do grep -qx PARTNAME=$1 \$u && sed -n s/^DEVNAME=//p \$u; done; true'" || true; } | tr -d '\r' | head -1; }
logs="$(part steamos-gen5-logs)"; root="$(part steamos-gen5)"
[[ -n "$logs" && -n "$root" ]] || die "no SteamOS card in the tablet: write steamos-gen5-card.img to the microSD card first"
adb push "$(host "$W/firmware.tar")" "$(host "$W/android-boot.sha256")" /data/local/tmp/ >/dev/null
su_ "mkdir -p /data/local/tmp/sg5 && mount -t vfat /dev/block/$logs /data/local/tmp/sg5 && cp /data/local/tmp/firmware.tar /data/local/tmp/android-boot.sha256 /data/local/tmp/sg5/ && sync && umount /data/local/tmp/sg5; rm -f /data/local/tmp/firmware.tar /data/local/tmp/android-boot.sha256" \
  || die "could not write to the card's steamos-gen5-logs partition"
echo "firmware and the Android image hash are on the card"

say "4. SteamOS's boot image"
python3 "$HERE/boot-repack.py" "$W/stock-boot.img" "$KERNEL" "$W/linux.img" | tail -2
linux="$(sha "$W/linux.img")"
echo "SteamOS boot image $linux"

say "5. Switch to SteamOS (KernelSU module)"
adb push "$(host "$W/linux.img")" /data/local/tmp/steamos-gen5.img >/dev/null
su_ "mkdir -p $D && mv /data/local/tmp/steamos-gen5.img $D/linux.img && echo $linux > $D/linux.img.sha256 && chmod 600 $D/linux.img"
[[ "$(su_ sha256sum $D/linux.img | cut -d' ' -f1)" == "$linux" ]] || die "the staged image doesn't verify on the tablet"
rm -rf "$W/module"; cp -r "$MODULE" "$W/module"; echo "$android" > "$W/module/android.sha256"
(cd "$W/module" && python3 -c "import shutil; shutil.make_archive('$W/switch-to-steamos', 'zip', '.')")
adb push "$(host "$W/switch-to-steamos.zip")" /data/local/tmp/ >/dev/null
su_ "cp /data/local/tmp/switch-to-steamos.zip $D/ && /data/adb/ksud module install /data/local/tmp/switch-to-steamos.zip >/dev/null 2>&1; rm -f /data/local/tmp/switch-to-steamos.zip" \
  || echo "note: install switch-to-steamos.zip from $D in the KernelSU app"
adb push "$(host "$MODULE/action.sh")" /data/local/tmp/sg5-action.sh >/dev/null
su_ "mv /data/local/tmp/sg5-action.sh $D/action.sh && chmod 755 $D/action.sh"
echo "staged. In Android: KernelSU > Modules > Switch to SteamOS > Action"

if [[ $SWITCH == 1 ]]; then
  say "6. Restarting into SteamOS"
  # The tablet restarts while this runs, which drops adb: not an error.
  { adb shell "su -c 'sh $D/action.sh'" || true; } | tr -d '\r' || true
fi
say "Done"
