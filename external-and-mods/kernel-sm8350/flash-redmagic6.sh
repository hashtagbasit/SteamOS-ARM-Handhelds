#!/bin/sh
# Zaviya for the REDMAGIC 6 (NX669J): install from fastboot mode.
#
# Hold Power + Volume Down to reach fastboot, bootloader unlocked.
# This ERASES Android and everything on the phone (userdata).
# Test boot on slot b first (Android and userdata untouched), see
# docs/redmagic6.md. Back to Android: flash Nubia's full OTA.
set -e
cd "$(dirname "$0")"

command -v fastboot >/dev/null || { echo "fastboot not found (install Android platform-tools)"; exit 1; }
fastboot devices | grep -q . || { echo "no device in fastboot mode"; exit 1; }
fastboot getvar unlocked 2>&1 | grep -q 'unlocked: yes' || { echo "bootloader is locked"; exit 1; }
sha256sum -c SHA256SUMS >/dev/null 2>&1 || shasum -a 256 -c SHA256SUMS >/dev/null \
  || { echo "image checksums do not match SHA256SUMS"; exit 1; }

printf 'This erases Android and everything on the phone. Type YES to continue: '
read -r answer
[ "$answer" = YES ] || exit 1

# The boot images are not signed with Nubia's keys: vbmeta.img is Nubia's
# with verification disabled (flags 3; fastboot's --disable-verification
# fails on the slot-suffixed partitions of this phone).
fastboot flash vbmeta_a vbmeta.img
fastboot flash vbmeta_b vbmeta.img
# With a valid dtbo, ABL overlays Nubia's board dtbo and the hypervisor's
# overlays onto the DTB, which fails on a mainline tree.
fastboot erase dtbo_a
fastboot erase dtbo_b
# Nubia's ABL only starts its own layout: kernel in boot, DTB + initramfs in
# vendor_boot. Use vendor_boot-debug.img instead for a USB debug shell.
fastboot flash boot_a boot.img
fastboot flash boot_b boot.img
fastboot flash vendor_boot_a vendor_boot.img
fastboot flash vendor_boot_b vendor_boot.img
fastboot flash userdata userdata.img
fastboot --set-active=a
fastboot reboot
echo "Done. The first boot takes a few minutes (the filesystem grows to the whole partition)."
