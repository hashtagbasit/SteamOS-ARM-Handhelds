#!/bin/sh
# SteamOS Boot Hook for AYN Odin 3 (SM8750)

echo "" > /dev/console
echo "=============================================" > /dev/console
echo "   Zaviya — AYN Odin 3 (SM8750)        " > /dev/console
echo "=============================================" > /dev/console
echo "Locating and mounting SteamOS system (root)..." > /dev/console

mkdir -p /sysroot

# The image build puts this card's root filesystem UUID here, so another
# install with a partition called "root" (UFS, a second card) can't get
# picked. LABEL=root and p2 are only the fallback for a hand-made card.
ROOT_UUID="@ROOT_UUID@"
ROOT_DEV=""
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  case "$ROOT_UUID" in
    @*) ;;
    *) if mount -o rw "UUID=$ROOT_UUID" /sysroot 2>/dev/null; then
         ROOT_DEV="UUID=$ROOT_UUID"
         break
       fi
       usleep 500000
       continue ;;
  esac
  if mount -o rw LABEL=root /sysroot 2>/dev/null; then
    ROOT_DEV="LABEL=root"
    break
  fi
  for cand in /dev/disk/by-label/root /dev/mmcblk*p2 /dev/sda2; do
    if [ -b "$cand" ] && mount -o rw "$cand" /sysroot 2>/dev/null; then
      ROOT_DEV="$cand"
      break 2
    fi
  done
  usleep 500000
done

if [ -z "$ROOT_DEV" ] && mount -o rw LABEL=root /sysroot 2>/dev/null; then
  ROOT_DEV="LABEL=root"
  echo "WARNING: UUID=$ROOT_UUID not found, using LABEL=root" > /dev/console
fi

if [ -z "$ROOT_DEV" ] || [ ! -f /sysroot/usr/lib/systemd/systemd ]; then
  echo "ERROR: Could not mount SteamOS root partition!" > /dev/console
  exit 1
fi

echo "SteamOS root mounted from ${ROOT_DEV}." > /dev/console
echo "Pivoting root to SteamOS systemd..." > /dev/console

# Prepare sysroot directories
mkdir -p /sysroot/dev /sysroot/proc /sysroot/sys /sysroot/run /sysroot/boot

# Move virtual filesystems into sysroot
mount --move /dev /sysroot/dev
mount --move /proc /sysroot/proc
mount --move /sys /sysroot/sys
mount --move /run /sysroot/run 2>/dev/null || true

# Unmount /flash so systemd's fstab can mount /boot cleanly
umount /flash 2>/dev/null || true

# Hand over execution to SteamOS systemd
exec /usr/bin/busybox switch_root /sysroot /usr/lib/systemd/systemd
