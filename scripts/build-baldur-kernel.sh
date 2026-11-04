#!/bin/bash
# Lenovo Legion Y700 Gen 5 (TB323FU, SM8850, board "baldur") kernel: mainline
# v7.3-rc4 with the board's patch series, device tree, config fragments and
# the out-of-tree aw882xx speaker amplifier driver from
# github.com/joonhoekim/tb323fu-linux (pinned in
# external-and-mods/kernel-baldur/release.env), plus our SteamOS options
# (kernel-common/steamos.config, kernel-baldur/steamos.config) and our startup
# code built in (kernel-common/initramfs, root=PARTLABEL=steamos-gen5).
#
#   build-baldur-kernel.sh OUT_DIR INITRD_CPIO
#
# OUT_DIR gets boot/Image, modules/<kver>/ (aw882xx in extra/), config-<kver>.
# The Image still has to go into the owner's own stock boot image
# (scripts/gen5/boot-repack.py, on their PC): the patched bootloader only
# takes a boot image with the stock signature blob. Runs as root in the build
# VM (docker, ubuntu:24.04, clang 18 like the board project's releases).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
source "$ROOT/external-and-mods/kernel-baldur/release.env"
OUT="${1:?output dir}"; CPIO="$(readlink -f "${2:?initrd.cpio}")"
W="${WORK:-/work/kernel-baldur}"
die() { echo "ERROR: $*" >&2; exit 1; }
[[ -s "$CPIO" ]] || die "no $CPIO"
mkdir -p "$W/cache" "$W/build"
ksrc="$W/cache/linux-${BALDUR_KVER}.tar.gz"
port="$W/cache/tb323fu-linux-${BALDUR_PORT_COMMIT}.tar.gz"
[[ -s "$ksrc" ]] || curl -fsSL --retry 3 -o "$ksrc" "$BALDUR_KSRC_URL"
[[ -s "$port" ]] || curl -fsSL --retry 3 -o "$port" "$BALDUR_PORT_URL"

# A fresh tree each time: the series is applied to a clean v7.3-rc4.
rm -rf "$W/build/linux" "$W/build/port"; mkdir -p "$W/build/port"
tar -xzf "$ksrc" -C "$W/build"; mv "$W/build/linux-${BALDUR_KVER}" "$W/build/linux"
tar -xzf "$port" -C "$W/build/port" --strip-components=1 --wildcards "*/kernel/*"
P="$W/build/port/kernel"
[[ -d "$P/patches" && -d "$P/out-of-tree/aw882xx" ]] || die "board kernel files not found in the pinned source"
n=0
for p in "$P"/patches/*.patch; do
  patch -d "$W/build/linux" -p1 -s --no-backup-if-mismatch < "$p" || die "patch $(basename "$p")"
  n=$((n + 1))
done
echo "applied $n board patches"
# Ours on top (kernel-baldur/patches: ath12k 5 GHz scanning and TX during
# scans, from github.com/mydanyi/armadaos-freedom), and the GPU off the
# board-temperature throttle in the built-in device tree.
K="$ROOT/external-and-mods/kernel-baldur"
for p in "$K"/patches/*.patch; do
  patch -d "$W/build/linux" -p1 -s -F0 --no-backup-if-mismatch < "$p" || die "patch $(basename "$p")"
done
dq="$W/build/linux/arch/arm64/boot/dts/qcom"
cp "$K/dts/baldur-gpu-no-skin-throttle.dtsi" "$dq/"
grep -q '"baldur-skin-thermal.dtsi"' "$dq/kaanapali-lenovo-baldur-display.dts" || die "display dts without skin thermal"
echo '#include "baldur-gpu-no-skin-throttle.dtsi"' >> "$dq/kaanapali-lenovo-baldur-display.dts"
cp "$K/dts/baldur-sd-sdr50.dtsi" "$dq/"
echo '#include "baldur-sd-sdr50.dtsi"' >> "$dq/kaanapali-lenovo-baldur-display.dts"
cp "$CPIO" "$W/build/initrd.cpio"
cat "$ROOT/external-and-mods/kernel-common/steamos.config" "$ROOT/external-and-mods/kernel-baldur/steamos.config" \
  > "$W/build/steamos.fragment"
mkdir -p "$W/build/frag"; cp "$P"/config/baldur.fragment "$P"/config/baldur-display.fragment "$P"/config/baldur-extra.fragment "$W/build/frag/"

docker run --rm -v "$W/build:/build" -w /build/linux \
  -e KBUILD_BUILD_USER=steamos -e KBUILD_BUILD_HOST=builder ubuntu:24.04 bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update >/dev/null
    apt-get -qq install -y clang-18 lld-18 llvm-18 make bc bison flex libssl-dev libelf-dev python3 \
      cpio kmod dwarves xz-utils zstd perl rsync device-tree-compiler >/dev/null
    for t in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-strip llvm-readelf; do
      ln -sf /usr/bin/$t-18 /usr/local/bin/$t; done
    M="make ARCH=arm64 LLVM=1 O=/build/out"
    $M defconfig >/dev/null
    scripts/kconfig/merge_config.sh -m -O /build/out /build/out/.config \
      arch/arm64/configs/kaanapali-oneplus-infiniti_defconfig \
      /build/frag/baldur.fragment /build/frag/baldur-display.fragment /build/frag/baldur-extra.fragment /build/steamos.fragment >/dev/null
    $M olddefconfig >/dev/null
    for o in CONFIG_INITRAMFS_SOURCE=\"/build/initrd.cpio\" CONFIG_CMDLINE_FORCE=y CONFIG_OVERLAY_FS=y \
             CONFIG_ANDROID_BINDERFS=y CONFIG_UNICODE=y CONFIG_DRM_PANEL_NOVATEK_NT36523=y \
             CONFIG_ZRAM_BACKEND_ZSTD=y; do
      grep -qx "$o" /build/out/.config || { echo "config: $o did not stick"; exit 1; }
    done
    $M -j"$(nproc)" dtbs >/dev/null
    d=/build/out/arch/arm64/boot/dts/qcom/kaanapali-lenovo-baldur-display.dtb
    for m in map2 map5 map8 map10; do
      ! fdtget -l $d /thermal-zones/quiet-thermal/cooling-maps | grep -qx $m || { echo "dtb: GPU skin throttle $m still there"; exit 1; }
    done
    fdtget -l $d /thermal-zones/quiet-thermal/cooling-maps | grep -qx map0 || { echo "dtb: CPU skin throttle gone"; exit 1; }
    dtc -I dtb -O dts $d 2>/dev/null | grep -q "max-frequency = <0x5f5e100>" || { echo "dtb: SD card max-frequency not set"; exit 1; }
    $M -j"$(nproc)" Image modules
    rm -rf /build/mods; $M INSTALL_MOD_PATH=/build/mods INSTALL_MOD_STRIP=1 modules_install >/dev/null
    $M M=/build/port/kernel/out-of-tree/aw882xx CONFIG_SND_SOC_AW882XX=m modules
    kr=$($M -s kernelrelease)
    mkdir -p /build/mods/lib/modules/$kr/extra
    find /build/port/kernel/out-of-tree/aw882xx -name "*.ko" -exec llvm-strip --strip-debug {} \; \
      -exec cp {} /build/mods/lib/modules/$kr/extra/ \;
    depmod -b /build/mods "$kr"
    echo "$kr" > /build/kernelrelease
  '

kr="$(cat "$W/build/kernelrelease")"
[[ -s "$W/build/out/arch/arm64/boot/Image" ]] || die "no Image"
ls "$W/build/mods/lib/modules/$kr/extra/"*aw882xx*.ko >/dev/null 2>&1 || die "aw882xx module missing"
strings "$W/build/out/arch/arm64/boot/Image" | grep -c "root=PARTLABEL=steamos-gen5" >/dev/null || die "cmdline missing"
rm -rf "$OUT"; mkdir -p "$OUT/boot" "$OUT/modules"
cp "$W/build/out/arch/arm64/boot/Image" "$OUT/boot/Image"
cp -a "$W/build/mods/lib/modules/$kr" "$OUT/modules/$kr"
rm -f "$OUT/modules/$kr/build" "$OUT/modules/$kr/source"
cp "$W/build/out/.config" "$OUT/config-$kr"
echo "kernel $kr -> $OUT"
ls -l "$OUT/boot"
