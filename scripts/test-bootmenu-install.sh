#!/bin/bash
# tablet-bootmenu-install on files: no tablet, no root.
#
#   test-bootmenu-install.sh BUNDLE_DIR KERNEL_OUT
#
# BUNDLE_DIR is what build-kshimc.sh made (aarch64 tools, run it on aarch64).
# KERNEL_OUT is a Gen 4 kernel output (boot/Image, dtbs/sm8750-lenovo-elden.dtb).
# A stand-in 96 MiB stock Android boot image (header v4, raw ARM64 kernel, AVB
# footer) and a SteamOS boot_b are made here; the tool installs the menu into a
# boot_a file, which is checked, restored byte for byte, and bad inputs refused.
set -euo pipefail
B="$(readlink -f "${1:?bundle dir}")" KO="$(readlink -f "${2:?kernel output}")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/var/tmp}/bootmenu-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
SIZE=100663296
pass=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

export TABLET_BOOTMENU_TEST=1 BACKUP="$T/backup" BOOTMENU_STATE="$T/state" BOOT_A="$T/boot_a" BOOT_B="$T/boot_b"
export TABLET_SLOT="$T/slot.sh" BOOTMENU_DTB="$KO/dtbs/sm8750-lenovo-elden.dtb" TMPDIR="$T"
cat >"$T/slot.sh" <<'SLOT'
#!/bin/bash
echo "$*" >>"$(dirname "$0")/slot.log"
SLOT
chmod +x "$T/slot.sh"
tool() { "$B/tablet-bootmenu-install" "$@"; }

# --- stand-in images -------------------------------------------------------
python3 -I - "$T" <<'PY'
import os, struct, sys, random
t = sys.argv[1]
random.seed(7)
# A raw ARM64 Image: branch at 0, header fields, magic at 0x38, bulk after.
n = 24 * 1024 * 1024
img = bytearray(random.randbytes(n))
img[0:4] = struct.pack("<I", 0x14000010)       # b +0x40
img[4:8] = struct.pack("<I", 0)
img[8:16] = struct.pack("<Q", 0)               # text_offset
img[16:24] = struct.pack("<Q", n + 1048576)    # image_size (bss beyond the file)
img[24:32] = struct.pack("<Q", 0xA)            # flags
img[32:56] = bytes(24)                         # reserved: the packer's fields
img[56:60] = b"ARM\x64"
def boot(kernel, ver=4, ramdisk=0, sig=0):
    h = struct.pack("<8s4I4II1536sI", b"ANDROID!", len(kernel), ramdisk, 0x1E000000, 1584, 0, 0, 0, 0,
                    ver, b"console=ttyMSM0".ljust(1536, b"\0"), sig)
    b = h + bytes(4096 - len(h)) + kernel
    return b + bytes(-len(b) % 4096)
open(t + "/stock.pre", "wb").write(boot(bytes(img)))
open(t + "/stock-v3.pre", "wb").write(boot(bytes(img), ver=3))
open(t + "/stock-ramdisk.pre", "wb").write(boot(bytes(img), ramdisk=4096))
PY
python3 "$B/avbtool.py" add_hash_footer --image "$T/stock.pre" --partition_size $SIZE --partition_name boot --algorithm NONE
cp "$T/stock.pre" "$T/stock.img"
python3 "$B/avbtool.py" add_hash_footer --image "$T/stock-v3.pre" --partition_size $SIZE --partition_name boot --algorithm NONE
python3 "$B/avbtool.py" add_hash_footer --image "$T/stock-ramdisk.pre" --partition_size $SIZE --partition_name boot --algorithm NONE
# No footer: a plain 96 MiB file.
head -c 8388608 "$T/stock.img" >"$T/nofooter.img"; truncate -s $SIZE "$T/nofooter.img"
# SteamOS boot_b: the kernel with the steamos root, as boot-dual.img has it.
python3 -I - "$KO/boot/Image" "$T/Image.steamos" <<'PY'
import sys
k = open(sys.argv[1], "rb").read()
for old in (b"root=PARTLABEL=userdata", b"root=PARTLABEL=steamos"):
    if old in k:
        k = k.replace(old, b"root=PARTLABEL=steamos".ljust(len(old), b" ") if len(old) >= 22 else old)
        break
else:
    sys.exit("no root= in the kernel")
assert b"root=PARTLABEL=steamos" in k
open(sys.argv[2], "wb").write(k)
PY
python3 "$HERE/../external-and-mods/kernel-common/mkbootimg-v4.py" --kernel "$T/Image.steamos" --out "$T/boot_b.pre"
python3 "$B/avbtool.py" add_hash_footer --image "$T/boot_b.pre" --partition_size $SIZE --partition_name boot --algorithm NONE
cp "$T/boot_b.pre" "$T/boot_b.img"
[[ $(stat -c %s "$T/stock.img") == "$SIZE" && $(stat -c %s "$T/boot_b.img") == "$SIZE" ]] || fail "stand-in images are not 96 MiB"
reset() { cp "$T/stock.img" "$BOOT_A"; cp "$T/boot_b.img" "$BOOT_B"; rm -rf "$BACKUP" "$BOOTMENU_STATE" "$T/slot.log"; }
kind() { python3 "$B/tablet-bootmenu-pack" kind "$1" | sed 's/^kind=//'; }
expect_fail() {  # expect_fail DESCRIPTION PATTERN COMMAND...
  local d=$1 pat=$2; shift 2
  if out=$("$@" 2>&1); then fail "$d: should have been refused"; fi
  grep -qi -- "$pat" <<<"$out" || fail "$d: refused, but not with '$pat': $out"
  ok "$d refused ($pat)"
}

# --- dry run ---------------------------------------------------------------
reset
tool --dry-run >"$T/dry.out" 2>&1 || { cat "$T/dry.out"; fail "dry run failed"; }
grep -q "Dry run: nothing changed" "$T/dry.out" || fail "dry run: no end line"
cmp "$BOOT_A" "$T/stock.img" && [[ ! -e $BACKUP && ! -e $T/slot.log ]] || fail "dry run changed something"
ok "dry run packs and checks, changes nothing"

# --- install ---------------------------------------------------------------
tool --yes >"$T/install.out" 2>&1 || { cat "$T/install.out"; fail "install failed"; }
[[ $(kind "$BOOT_A") == menu ]] || fail "boot_a is not the menu"
[[ $(stat -c %s "$BOOT_A") == "$SIZE" ]] || fail "boot_a changed size"
cmp "$BOOT_B" "$T/boot_b.img" || fail "boot_b changed"
ok "install: boot_a is the menu image (96 MiB), boot_b untouched"
saved=$(ls "$BACKUP"/boot_a-stock-*.img) && cmp "$saved" "$T/stock.img" || fail "backup is not the stock image"
[[ $(cut -d' ' -f1 "$saved.sha256") == $(sha256sum "$T/stock.img" | cut -d' ' -f1) ]] || fail "backup sha256"
ok "stock image saved with its sha256"
grep -qx 'activate a' "$T/slot.log" || fail "slot A not activated"
ok "slot A made active"
mkdir -p "$T/verify" && cp "$BOOT_A" "$T/verify/boot.img"
python3 "$B/avbtool.py" verify_image --image "$T/verify/boot.img" >/dev/null && ok "avbtool verify_image on boot_a"
# the packed kernel holds SteamOS as the second manifest entry, Android first
python3 -I - "$BOOT_A" <<'PY'
import gzip, struct, sys
b = open(sys.argv[1], "rb").read()
ks = struct.unpack_from("<I", b, 8)[0]
raw = gzip.decompress(b[4096:4096 + ks])
mo = struct.unpack_from("<Q", raw, 32)[0]
magic, vmaj, vmin, count, default, timeout = struct.unpack_from("<IHHIII", raw, mo)
assert magic == 0x464D504B and count == 4 and default == 1 and timeout == 8000, (count, default, timeout)
names = []
cur = mo + 60
for _ in range(count):
    nl = struct.unpack_from("<I", raw, cur + 52)[0]
    names.append(raw[cur + 56:cur + 56 + nl].decode())
    cur += (56 + nl + 3) // 4 * 4
assert names[:3] == ["Android", "SteamOS", "SteamOS DTB"], names
print("manifest entries:", names, "default", default, "timeout", timeout)
PY
ok "manifest: Android, SteamOS, default SteamOS, 8 s"

# --- run again: packs from the saved stock image ---------------------------
tool --yes >"$T/again.out" 2>&1 || { cat "$T/again.out"; fail "second install failed"; }
[[ $(ls "$BACKUP"/boot_a-stock-*.img | wc -l) == 1 ]] || fail "second install saved another backup"
ok "second run packs from the saved stock image, no second backup"

# --- sync ------------------------------------------------------------------
sha_a=$(sha256sum "$BOOT_A" | cut -d' ' -f1)
tool --sync || fail "sync failed"
[[ $(sha256sum "$BOOT_A" | cut -d' ' -f1) == "$sha_a" ]] || fail "sync rewrote boot_a with an unchanged kernel"
ok "sync: unchanged kernel, boot_a untouched"
python3 -I - "$T/Image.steamos" "$T/Image.new" <<'PY'
import sys
k = bytearray(open(sys.argv[1], "rb").read()); k[4096] ^= 0xFF
open(sys.argv[2], "wb").write(bytes(k))
PY
python3 "$HERE/../external-and-mods/kernel-common/mkbootimg-v4.py" --kernel "$T/Image.new" --out "$T/boot_b2.pre"
python3 "$B/avbtool.py" add_hash_footer --image "$T/boot_b2.pre" --partition_size $SIZE --partition_name boot --algorithm NONE
cp "$T/boot_b2.pre" "$BOOT_B"
tool --sync >"$T/sync.out" 2>&1 || { cat "$T/sync.out"; fail "sync with a new kernel failed"; }
[[ $(sha256sum "$BOOT_A" | cut -d' ' -f1) != "$sha_a" && $(kind "$BOOT_A") == menu ]] || fail "sync did not pack the new kernel"
python3 "$B/tablet-bootmenu-pack" kernel "$BOOT_B" "$T/k.new"
python3 -I - "$BOOT_A" "$T/k.new" <<'PY'
import gzip, struct, sys
b = open(sys.argv[1], "rb").read(); k = open(sys.argv[2], "rb").read()
raw = gzip.decompress(b[4096:4096 + struct.unpack_from("<I", b, 8)[0]])
assert k in raw, "new kernel not in boot_a"
PY
ok "sync: a new kernel in boot_b is packed into boot_a"

# --- restore ---------------------------------------------------------------
: >"$T/slot.log"
tool --restore --dry-run >/dev/null || fail "restore --dry-run"
[[ $(kind "$BOOT_A") == menu ]] || fail "restore --dry-run changed boot_a"
tool --restore --yes >"$T/restore.out" 2>&1 || { cat "$T/restore.out"; fail "restore failed"; }
cmp "$BOOT_A" "$T/stock.img" || fail "restore is not byte-identical to the stock image"
grep -qx 'activate b' "$T/slot.log" || fail "slot B not activated"
[[ ! -e $BOOTMENU_STATE/state.env ]] || fail "state kept after restore"
ok "restore: boot_a byte-identical to the stock image, slot B active again"

# --- refusals --------------------------------------------------------------
reset; head -c $((SIZE - 1048576)) "$T/stock.img" >"$BOOT_A"
expect_fail "boot_a not 96 MiB" "96 MiB\|not 96\|bytes" tool --yes
reset; cp "$T/stock-v3.pre" "$BOOT_A"
expect_fail "header version 3" "version" tool --yes
reset; cp "$T/stock-ramdisk.pre" "$BOOT_A"
expect_fail "stock with a ramdisk" "ramdisk" tool --yes
reset; cp "$T/nofooter.img" "$BOOT_A"
expect_fail "no AVB footer / not an Android image" "boot image\|AVB\|neither" tool --yes
reset; head -c $SIZE /dev/zero >"$BOOT_A"
expect_fail "empty boot_a" "neither" tool --yes
reset; head -c $SIZE /dev/zero >"$BOOT_B"
expect_fail "boot_b not Android" "boot_b" tool --yes
reset; python3 "$HERE/../external-and-mods/kernel-common/mkbootimg-v4.py" --kernel "$KO/boot/Image" --out "$T/other.pre"
python3 "$B/avbtool.py" add_hash_footer --image "$T/other.pre" --partition_size $SIZE --partition_name boot --algorithm NONE
if grep -q 'root=PARTLABEL=steamos' "$KO/boot/Image"; then
  python3 -I - "$KO/boot/Image" "$T/Image.other" <<'PY'
import sys
k = open(sys.argv[1], "rb").read().replace(b"root=PARTLABEL=steamos", b"root=PARTLABEL=userdata")
open(sys.argv[2], "wb").write(k)
PY
  python3 "$HERE/../external-and-mods/kernel-common/mkbootimg-v4.py" --kernel "$T/Image.other" --out "$T/other.pre"
  python3 "$B/avbtool.py" add_hash_footer --image "$T/other.pre" --partition_size $SIZE --partition_name boot --algorithm NONE
fi
cp "$T/other.pre" "$BOOT_B"
expect_fail "boot_b not started from the steamos partition" "steamos" tool --yes
reset; : >"$T/other.dtb"
expect_fail "empty device tree" "device tree" env BOOTMENU_DTB="$T/other.dtb" "$B/tablet-bootmenu-install" --yes
reset; tool --yes >/dev/null 2>&1; rm -rf "$BACKUP"
expect_fail "menu in boot_a but no saved stock image" "saved stock" tool --yes
reset; tool --yes >/dev/null 2>&1; echo corrupt >>"$(ls "$BACKUP"/boot_a-stock-*.img)"
expect_fail "saved stock image damaged" "saved stock" tool --yes
reset; mkdir -p "$T/small" "$T/bin"
cat >"$T/bin/df" <<'DF'
#!/bin/bash
case "$*" in
  *small*) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nx 1000 990 10 99%% /\n' ;;
  *) exec /bin/df "$@" ;;
esac
DF
chmod +x "$T/bin/df"
expect_fail "no space for the backup" "free" env PATH="$T/bin:$PATH" BACKUP="$T/small/b" "$B/tablet-bootmenu-install" --yes
cmp "$BOOT_A" "$T/stock.img" || fail "a refused run changed boot_a"
ok "refused runs left boot_a alone"

# --- wrong tablet ----------------------------------------------------------
python3 -I - "$KO/dtbs/sm8750-lenovo-elden.dtb" "$T/gen5.dtb" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
assert b"qcom,sm8750" in d
open(sys.argv[2], "wb").write(d.replace(b"qcom,sm8750", b"qcom,sm8850"))
PY
reset
expect_fail "device tree of another tablet" "Gen 4\|another" env BOOTMENU_DTB="$T/gen5.dtb" "$B/tablet-bootmenu-install" --yes

echo
echo "bootmenu install: $pass checks passed"
