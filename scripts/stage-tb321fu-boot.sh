#!/bin/bash
# Fill a Lenovo Legion Y700 Gen 3 (TB321FU) ESP and fetch its boot.img.
#
#   stage-tb321fu-boot.sh ESP_DIR KERNEL_OUT boe|csot CMDLINE [BOOTIMG_OUT]
#
# ESP_DIR     the FAT ESP to fill (the internal install's ROCKNIX partition, or
#             a staging dir copied there)
# KERNEL_OUT  kernel-tb321fu output (boot/Image, dtbs/)
# boe|csot    the panel supplier (stock Android: getprop
#             ro.vendor.display.paneltype, 1 = BOE), or "both" for the
#             installer image: a menu with both, BOE first
# CMDLINE     the kernel cmdline (root=PARTLABEL=STORAGE ...)
# BOOTIMG_OUT where to put the UEFI boot.img for the boot partition
#
# Downloads are cached in ${CACHE:-/work/cache/tb321fu-boot} and checked
# against release.env.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../external-and-mods/tb321fu-boot/release.env"
ESP="$1" KOUT="$2" PANEL="$3" CMDLINE="$4" BOOTIMG_OUT="${5:-}"
CACHE="${CACHE:-/work/cache/tb321fu-boot}"
die() { echo "stage-tb321fu-boot: $*" >&2; exit 1; }
case "$PANEL" in
  boe|csot) PANELS="$PANEL" ;;
  both) PANELS="boe csot" ;;
  *) die "panel must be boe, csot or both" ;;
esac
[[ -s "$KOUT/boot/Image" ]] || die "no $KOUT/boot/Image (kernel-tb321fu builds it)"
for p in $PANELS; do
  [[ -s "$KOUT/dtbs/sm8650-lenovo-tb321fu-${p}.dtb" ]] || die "no $KOUT/dtbs/sm8650-lenovo-tb321fu-${p}.dtb"
done

get() {  # get URL FILE SHA256
  local f="$CACHE/$2"
  mkdir -p "$CACHE"
  if [[ ! -s "$f" ]] || ! echo "$3  $f" | sha256sum -c --quiet 2>/dev/null; then
    curl -fsSL --retry 3 -o "$f.part" "$1"
    mv -f "$f.part" "$f"
  fi
  echo "$3  $f" | sha256sum -c --quiet || die "hash mismatch: $2"
}
get "${TB321FU_GRUB_URL}/BOOTAA64.EFI" BOOTAA64.EFI "$TB321FU_BOOTAA64_SHA256"
get "${TB321FU_GRUB_URL}/QCOMRAMP-CONFIGFILE.EFI" QCOMRAMP-CONFIGFILE.EFI "$TB321FU_QCOMRAMP_SHA256"

mkdir -p "$ESP/EFI/BOOT" "$ESP/dtb"
# GRUB finds its own partition by a marker unique to it, not the first /Image:
# with the USB installer plugged into an installed tablet both have one, and
# a wrong pick boots the other one's kernel (or a stale one: black screen).
MARK="steamos-arm-boot-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
rm -f "$ESP"/steamos-arm-boot-*
echo "Zaviya boot partition (GRUB looks for this file)" >"$ESP/$MARK"
cp "$CACHE/BOOTAA64.EFI" "$ESP/EFI/BOOT/BOOTAA64.EFI"
cp "$CACHE/QCOMRAMP-CONFIGFILE.EFI" "$ESP/EFI/BOOT/QCOMRAMP.EFI"
cp "$KOUT/boot/Image" "$ESP/Image"
for p in $PANELS; do cp "$KOUT/dtbs/sm8650-lenovo-tb321fu-${p}.dtb" "$ESP/dtb/"; done

# First stage: BOOTAA64.EFI is GRUB with its prefix built in as /boot/grub,
# so it reads /boot/grub/grub.cfg on its own partition (with no file there it
# stops at a grub> prompt). It only chains to the second stage; it has no
# reboot/halt modules, so no such entries.
mkdir -p "$ESP/boot/grub"
cat >"$ESP/boot/grub/grub.cfg" <<CFG
set timeout=0
set default=0
set gfxpayload=keep
search --no-floppy --file /$MARK --set=root
menuentry "Zaviya" {
    search --no-floppy --file /$MARK --set=root
    chainloader /EFI/BOOT/QCOMRAMP.EFI
    boot
}
CFG
rm -f "$ESP/EFI/BOOT/grub.cfg"
# Second stage (QCOMRAMP.EFI): the kernel with the memory map from the RAM
# partition table, minus Android's carve-outs.
reserved="qcomfdtmem disable-reserved"
for p in $TB321FU_DISABLE_RESERVED; do reserved="$reserved $p"; done
# One panel: straight in. Both (the installer image, before the panel is
# known): a few seconds to pick, the BOE one first.
timeout=0; [[ "$PANEL" == both ]] && timeout=8
{
  printf 'set timeout=%s\nset default=0\nset gfxpayload=keep\n' "$timeout"
  for p in $PANELS; do
    name="Zaviya"; [[ "$PANEL" == both ]] && name="Zaviya (${p^^} panel)"
    cat <<CFG

menuentry "$name" {
    search --no-floppy --file /$MARK --set=root
    devicetree /dtb/sm8650-lenovo-tb321fu-${p}.dtb
    qcomfdtmem source rampartition
    $reserved
    linuxdirect /Image $CMDLINE
}
CFG
  done
} >"$ESP/EFI/BOOT/qcomramp.cfg"

if [[ -n "$BOOTIMG_OUT" ]]; then
  get "$TB321FU_BOOTIMG_URL" boot.img.7z "$TB321FU_BOOTIMG_7Z_SHA256"
  rm -rf "$CACHE/x"; mkdir -p "$CACHE/x"
  7z x -y -o"$CACHE/x" "$CACHE/boot.img.7z" >/dev/null
  echo "$TB321FU_BOOTIMG_SHA256  $CACHE/x/boot.img" | sha256sum -c --quiet || die "boot.img hash mismatch"
  cp "$CACHE/x/boot.img" "$BOOTIMG_OUT"
fi
echo "staged $ESP ($PANEL)"
