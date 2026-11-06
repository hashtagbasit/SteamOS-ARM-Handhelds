#!/bin/bash
# Lenovo Legion Y700 Gen 3 (TB321FU) kernel from the 7.2.6 tree that boots on
# the tablet: kernel.org 7.2.6, the tablet patch series and device trees from
# the pinned port tree (packages/kernel; SRC_URL below), arm64
# defconfig plus its config fragment. On top: our startup code built in (the
# GRUB entry passes no initrd), the CSOT device tree (upstream ships it; older
# packages only select BOE, then it is generated) and a
# neutral version suffix.
#
#   build-tb321fu-kernel-726.sh OUT_DIR INITRD_CPIO
#
# OUT_DIR gets the layout mk-tablet-flash-images.sh takes as KERNEL_OUT:
# boot/Image, dtbs/sm8650-lenovo-tb321fu-{boe,csot}.dtb, modules/<kver>/,
# config-<kver>. Runs as root in the build VM (docker, fedora:43). FAST=1
# reuses the last build tree (only the config fragment changed).
set -euo pipefail
OUT="${1:?output dir}"; CPIO="$(readlink -f "${2:?initrd.cpio}")"
SRC_COMMIT=8a5c57995104d99806b83f9644ba7a025ee4ead2
SRC_URL="https://codeload.github.com/enij90/armada-tb321fu/tar.gz/${SRC_COMMIT}"
W="${WORK:-/work/kernel-tb321fu-726}"
die() { echo "ERROR: $*" >&2; exit 1; }
[[ -s "$CPIO" ]] || die "no $CPIO"
mkdir -p "$W/cache" "$W/out"
rm -rf "$W/pkg" "$W/out"/*

tarball="$W/cache/src-${SRC_COMMIT}.tar.gz"
[[ -s "$tarball" ]] || curl -fsSL --retry 3 -o "$tarball" "$SRC_URL"
mkdir -p "$W/pkg"
tar -xzf "$tarball" -C "$W/pkg" --strip-components=3 --wildcards '*/packages/kernel/*'
P="$W/pkg"
[[ -f "$P/scripts/build-kernel.sh" && -f "$P/patches/series" ]] || die "kernel package not found in the source"

dts="$P/dts/sm8650-lenovo-tb321fu.dts"
# Volume keys the way Android has them: the series swaps them for a
# controller grip, and in our landscape they came out reversed (test 6).
grep -q 'linux,code = <KEY_VOLUMEDOWN>;' "$dts" && grep -q 'linux,code = <KEY_VOLUMEUP>;' "$dts" || die "volume keys not found"
sed -i -e 's/linux,code = <KEY_VOLUMEDOWN>;/linux,code = <KEY_VOLUME_SWAP>;/' \
       -e 's/linux,code = <KEY_VOLUMEUP>;/linux,code = <KEY_VOLUMEDOWN>;/' \
       -e 's/linux,code = <KEY_VOLUME_SWAP>;/linux,code = <KEY_VOLUMEUP>;/' "$dts"
awk '/key-volume-up/ {f=1} f && /linux,code/ {print; exit}' "$dts" | grep -q KEY_VOLUMEUP || die "volume keys not swapped back"
# Bluetooth NVM: the device tree asks for hmtnv20_Kirby_row.bin (its Bluetooth
# is marked work in progress). The PRC NVM is what worked for testers on tests
# 7/8, ROW is unconfirmed, so keep PRC. The CSOT dts includes this file; a
# separate CSOT copy is covered by the loop.
for f in "$dts" "$P/dts/sm8650-lenovo-tb321fu-csot.dts"; do
  [[ -f "$f" ]] && sed -i 's/hmtnv20_Kirby_row\.bin/hmtnv20_Kirby_prc.bin/g' "$f"
done
grep -q 'hmtnv20_Kirby_prc\.bin' "$dts" && ! grep -q 'hmtnv20_Kirby_row' "$dts" "$P"/dts/sm8650-lenovo-tb321fu*.dts || die "Bluetooth NVM not switched to PRC"
# CSOT: upstream ships the CSOT device tree (it includes the BOE board file, so
# the volume swap above covers both); older packages need it made from the BOE one.
if [[ -f "$P/dts/sm8650-lenovo-tb321fu-csot.dts" ]]; then
  grep -q '#include "sm8650-lenovo-tb321fu.dts"' "$P/dts/sm8650-lenovo-tb321fu-csot.dts" || die "upstream CSOT dts no longer includes the board file"
  ! grep -q 'linux,code = <KEY_VOLUME' "$P/dts/sm8650-lenovo-tb321fu-csot.dts" || die "upstream CSOT dts has its own volume keys"
else
  sed -e 's/kirby-nt36523-boe-dsc/kirby-nt36523-csot-dsc/g' \
      -e 's/kirby_nt36523_boe_dsc_vid/kirby_nt36523_csot_dsc_vid/' \
      -e 's|^\(\s*model = "\)Lenovo Legion Y700 (2025) / TB321FU"|\1Lenovo Legion Y700 Gen 3 (CSOT panel)"|' \
      "$dts" > "$P/dts/sm8650-lenovo-tb321fu-csot.dts"
  ! grep -q 'boe-dsc' "$P/dts/sm8650-lenovo-tb321fu-csot.dts" || die "BOE left in the CSOT device tree"
fi
grep -q 'kirby-nt36523-csot-dsc-vid' "$P/dts/sm8650-lenovo-tb321fu-csot.dts" || die "CSOT panel not selected"
! grep -q 'boe-dsc' "$P/dts/sm8650-lenovo-tb321fu-csot.dts" || die "BOE left in the CSOT device tree"

# Our own patches for the Gen 3 kernel, applied after the whole upstream series
# (they were checked to apply to this exact tree with no fuzz and no rejects).
OURP="$(cd "$(dirname "$0")/.." && pwd)/external-and-mods/kernel-tb321fu-726/patches"
ls "$OURP"/*.patch >/dev/null 2>&1 || die "no patches in $OURP"
{ echo; echo "# Zaviya: our own patches for the Gen 3 kernel"; } >> "$P/patches/series"
for f in "$OURP"/*.patch; do
  cp "$f" "$P/patches/"; basename "$f" >> "$P/patches/series"
done

cp "$CPIO" "$P/initrd.cpio"
cat >> "$P/config/armada-kernel.config.overrides" <<EOF

# Zaviya: startup code built in, our version suffix
CONFIG_INITRAMFS_SOURCE="/src/initrd.cpio"
CONFIG_INITRAMFS_COMPRESSION_NONE=y
CONFIG_LOCALVERSION="-tb321fu"
# CONFIG_LOCALVERSION_AUTO is not set
CONFIG_FONTS=y
CONFIG_FONT_TER16x32=y
# The startup code has no modules and mounts the /etc overlay itself.
CONFIG_OVERLAY_FS=y

# Zaviya: options from our own kernel fragments (systemd resource
# control, firewalld, zswap, Bluetooth PAN, suspend debug, USB disks)
CONFIG_BT_RFCOMM_TTY=y
CONFIG_BT_BNEP=m
CONFIG_SQUASHFS_XZ=y
CONFIG_CFS_BANDWIDTH=y
CONFIG_BLK_DEV_THROTTLING=y
CONFIG_CGROUP_MISC=y
CONFIG_ZSWAP=y
CONFIG_CRYPTO_USER_API_AEAD=y
CONFIG_LEDS_TRIGGER_PATTERN=m
CONFIG_CPU_IDLE_GOV_TEO=y
CONFIG_PM_ADVANCED_DEBUG=y
CONFIG_NFT_FIB_IPV4=m
CONFIG_NFT_FIB_IPV6=m
CONFIG_NFT_FIB_INET=m
CONFIG_NF_LOG_IPV4=m
CONFIG_USB_UAS=y
# Temperatures and GPU load for MangoHud (thermal zones as hwmon devices), the
# PMIC power-on trigger, and zram with zstd (zram-generator asks for it).
CONFIG_QCOM_TSENS=y
CONFIG_THERMAL_OF=y
CONFIG_THERMAL_HWMON=y
CONFIG_PM_DEVFREQ=y
CONFIG_POWER_RESET_QCOM_PON=y
CONFIG_ZRAM=m
CONFIG_ZRAM_BACKEND_ZSTD=y
CONFIG_ZRAM_BACKEND_LZ4=y
CONFIG_CRYPTO_ZSTD=y
CONFIG_CRYPTO_LZ4=y
# Android USB tethering (phone as network)
CONFIG_USB_NET_RNDIS_HOST=m
EOF

docker run --rm -v "$P:/src" -v "$W/out:/work/out" -v "$W/cache:/cache" -w /src \
  -e KBUILD_BUILD_USER=steamos -e KBUILD_BUILD_HOST=builder -e FAST="${FAST:-}" \
  fedora:43 bash -c '
    set -e
    dnf -q -y install gcc binutils make bc bison flex openssl-devel elfutils-libelf-devel \
      dwarves zstd xz cpio patch curl perl-interpreter python3 findutils diffutils gawk \
      grep sed coreutils hostname gzip tar kmod >/dev/null
    WORK_DIR=/cache/build OUT_DIR=/work/out bash scripts/build-kernel.sh
  '

pkg=$(ls "$W"/out/*.tar.zst | head -1)
[[ -s "$pkg" ]] || die "no kernel package built"
rm -rf "$W/stage"; mkdir -p "$W/stage"
zstd -dc "$pkg" | tar -xf - -C "$W/stage"
# The package stages Image and DTBs under the release it read before the
# config fragment (7.2.6) and the modules under the real one (7.2.6-tb321fu).
st="$W/stage/lib/modules"
kver=$(basename "$(dirname "$(ls "$st"/*/modules.dep | head -1)")")
img=$(ls "$st"/*/vmlinuz | head -1); dtbd=$(dirname "$(ls "$st"/*/dtb/qcom/sm8650-lenovo-tb321fu.dtb | head -1)")
rm -rf "$OUT"; mkdir -p "$OUT/boot" "$OUT/dtbs" "$OUT/modules"
cp "$img" "$OUT/boot/Image"
cp "$dtbd/sm8650-lenovo-tb321fu.dtb" "$OUT/dtbs/sm8650-lenovo-tb321fu-boe.dtb"
cp "$dtbd/sm8650-lenovo-tb321fu-csot.dtb" "$OUT/dtbs/sm8650-lenovo-tb321fu-csot.dtb"
m="$st/$kver"
rm -rf "$m/dtb" "$m/vmlinuz" "$m/.armada-source"
mv "$m" "$OUT/modules/$kver"
cp "$W/cache/build/linux-"*/.config "$OUT/config-$kver"
# Every option from our fragment must have survived Kconfig.
sed -n '/^# Zaviya: options from our own kernel fragments/,/^EOF$/p' "$0" | grep '^CONFIG_' | while read -r opt; do
  grep -qx "$opt" "$OUT/config-$kver" || { echo "ERROR: config option did not stick: $opt (got: $(grep -m1 "^${opt%%=*}[= ]\|^# ${opt%%=*} " "$OUT/config-$kver" || echo missing))" >&2; exit 1; }
done
grep -q 'steamos.bootlabel' "$OUT/boot/Image" || die "startup code isn't in the Image"
echo "kernel $kver -> $OUT"
ls -l "$OUT/boot" "$OUT/dtbs"
