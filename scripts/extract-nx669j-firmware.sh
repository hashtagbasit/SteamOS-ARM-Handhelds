#!/usr/bin/env bash
# REDMAGIC 6 (NX669J) firmware for the Zaviya image, taken from Nubia's
# own OTA (it cannot be redistributed, so bring your own):
#
#   scripts/extract-nx669j-firmware.sh NX669J-update.zip [OUT]
#
# OUT (default ${STEAMOS_WORK:-/work}/nx669j-firmware) becomes a
# /lib/firmware tree:
#   qcom/sm8350/nubia/nx669j/  adsp cdsp slpi modem ipa_fws a660_zap (.mbn,
#                              squashed from .mdt/.bNN) + the .jsn service
#                              maps pd-mapper reads
#   qcom/a660_sqe.fw a660_gmu.bin   Adreno 660 microcode (Nubia's copies)
#   ath11k/WCN6855/hw2.{0,1}/  amss.bin m3.bin regdb.bin (Wi-Fi, QCA6490)
#   nubia/nx669j/wlan/         bdwlan.* board files (board-2.bin is built on
#                              the device, it needs the chip's board id)
#   qca/                       hpbtfw*.tlv hpnv*.* (Bluetooth)
#   nubia/nx669j/aw22xxx/      aw_cfg_*.bin (back RGB light effects)
#
# OUT.stock/ gets the stock boot, vendor_boot, dtbo, vbmeta and vbmeta_system
# images: the flash script needs vbmeta (flashed with verification off), the
# rest is what it takes to go back to Android.
#
# Needs: unzip, python3, debugfs (e2fsprogs), mtools. No root.
# payload-dumper-go is downloaded if it is not installed.
set -euo pipefail

ZIP="${1:?usage: $0 NX669J-update.zip [OUT]}"
OUT="${2:-${STEAMOS_WORK:-/work}/nx669j-firmware}"
PDG_VER=1.3.0

log() { printf '[nx669j-fw] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

for c in unzip python3 debugfs mcopy mdir; do
  command -v "$c" >/dev/null || die "missing $c"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

unzip -p "$ZIP" META-INF/com/android/metadata >"$tmp/metadata" 2>/dev/null \
  || die "$ZIP is not an OTA zip"
grep -q '^pre-device=NX669J' "$tmp/metadata" || die "not an NX669J OTA ($(grep ^pre-device "$tmp/metadata"))"
log "$(grep ^post-build= "$tmp/metadata")"

pdg="$(command -v payload-dumper-go || true)"
if [[ -z "$pdg" ]]; then
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) die "no payload-dumper-go for $(uname -m)" ;;
  esac
  log "fetching payload-dumper-go ${PDG_VER}"
  curl -fsSL "https://github.com/ssut/payload-dumper-go/releases/download/${PDG_VER}/payload-dumper-go_${PDG_VER}_linux_${arch}.tar.gz" \
    | tar -C "$tmp" -xz payload-dumper-go
  pdg="$tmp/payload-dumper-go"
fi

log "extracting modem, vendor, bluetooth from payload.bin"
unzip -o -q "$ZIP" payload.bin -d "$tmp"
"$pdg" -p modem,vendor,bluetooth,boot,vendor_boot,dtbo,vbmeta,vbmeta_system \
  -o "$tmp/img" "$tmp/payload.bin" >/dev/null
rm -f "$tmp/payload.bin"

m="$tmp/modem" v="$tmp/vendor" b="$tmp/bt"
mkdir -p "$m" "$v" "$b"
mcopy -n -s -i "$tmp/img/modem.img" ::image "$m/"
mcopy -n -s -i "$tmp/img/bluetooth.img" ::image "$b/"
debugfs -R "rdump /firmware $v" "$tmp/img/vendor.img" >/dev/null 2>&1
[[ -f "$m/image/adsp.mdt" ]] || die "modem image has no adsp.mdt"
[[ -f "$v/firmware/a660_zap.mdt" ]] || die "vendor image has no a660_zap.mdt"

# .mdt + .bNN -> one .mbn, what qcom_mdt_load() / remoteproc expect
# (same as linux-msm/pil-squasher).
squash() {
  python3 - "$1" "$2" <<'PY'
import struct, sys
from pathlib import Path
mdt, out = Path(sys.argv[1]), Path(sys.argv[2])
d = mdt.read_bytes()
if d[:4] != b"\x7fELF":
    sys.exit(f"{mdt}: not ELF")
if d[4] == 1:
    phoff, = struct.unpack_from("<I", d, 0x1c)
    phentsize, phnum = struct.unpack_from("<HH", d, 0x2a)
    def ph(i):
        _, off, _, _, filesz, _, _, _ = struct.unpack_from("<8I", d, phoff + i * phentsize)
        return off, filesz
else:
    phoff, = struct.unpack_from("<Q", d, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", d, 0x36)
    def ph(i):
        _, _, off, _, _, filesz, _, _ = struct.unpack_from("<IIQQQQQQ", d, phoff + i * phentsize)
        return off, filesz
img = bytearray()
for i in range(phnum):
    off, size = ph(i)
    if not size:
        continue
    seg = mdt.with_suffix(f".b{i:02d}")
    data = seg.read_bytes() if seg.exists() else d[off:off + size]
    if len(img) < off + len(data):
        img.extend(b"\0" * (off + len(data) - len(img)))
    img[off:off + len(data)] = data
hdr = phoff + phnum * phentsize
img[:hdr] = d[:hdr]
out.write_bytes(img)
PY
}

q="$OUT/qcom/sm8350/nubia/nx669j"
rm -rf "$OUT" "${OUT}.stock"
mkdir -p "$q" "$OUT/qcom" "$OUT/qca" "$OUT/nubia/nx669j/wlan" "${OUT}.stock"
for i in boot vendor_boot dtbo vbmeta vbmeta_system; do
  cp "$tmp/img/${i}.img" "${OUT}.stock/"
done
grep ^post-build= "$tmp/metadata" >"${OUT}.stock/BUILD"

for fw in adsp cdsp slpi modem; do
  squash "$m/image/${fw}.mdt" "$q/${fw}.mbn"
done
squash "$v/firmware/a660_zap.mdt" "$q/a660_zap.mbn"
squash "$v/firmware/ipa_fws.mdt" "$q/ipa_fws.mbn"
cp "$m"/image/*.jsn "$q/"
cp "$v/firmware/a660_sqe.fw" "$v/firmware/a660_gmu.bin" "$OUT/qcom/"

# Wi-Fi: Nubia ships firmware for both QCA6490 steppings (amss20 = 2.0).
for hw in hw2.0 hw2.1; do
  mkdir -p "$OUT/ath11k/WCN6855/$hw"
  cp "$m/image/m3.bin" "$m/image/regdb.bin" "$OUT/ath11k/WCN6855/$hw/"
done
cp "$m/image/amss20.bin" "$OUT/ath11k/WCN6855/hw2.0/amss.bin"
cp "$m/image/amss.bin" "$OUT/ath11k/WCN6855/hw2.1/amss.bin"
cp "$m"/image/bdwlan.* "$OUT/nubia/nx669j/wlan/"

cp "$b"/image/hpbtfw* "$b"/image/hpnv* "$OUT/qca/"

# Back RGB light: Nubia's effect scripts (leds-nubia-nx669j replays them).
mkdir -p "$OUT/nubia/nx669j/aw22xxx"
cp "$v"/firmware/aw_cfg_*.bin "$OUT/nubia/nx669j/aw22xxx/"

(cd "$OUT" && find . -type f | sort | xargs sha256sum) >"$OUT/SHA256SUMS"
(cd "${OUT}.stock" && sha256sum ./*.img >SHA256SUMS)
log "done: $OUT ($(find "$OUT" -type f | wc -l) files, $(du -sh "$OUT" | cut -f1)), stock images in ${OUT}.stock"
