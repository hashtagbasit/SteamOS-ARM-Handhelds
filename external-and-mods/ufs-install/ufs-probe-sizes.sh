#!/usr/bin/env bash
# Sizing probe for the Zaviya installer GUI. Prints KEY=VALUE lines from
# ufs-partition.py detect (the same numbers the installer uses), plus the
# older keys the GUI reads.
set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
STORAGE_GIB="${STORAGE_GIB:-20}"

root_disk="/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)"
disk=""
for d in /dev/sd[a-z]; do
  [[ -b "$d" && "$d" != "$root_disk" ]] || continue
  lsblk -rno PARTLABEL "$d" 2>/dev/null | grep -qx userdata && { disk="$d"; break; }
done
[[ -n "$disk" ]] || { echo "ERROR=no internal disk with a userdata partition found"; exit 1; }

out="$(python3 "$HERE/ufs-partition.py" detect --disk "$disk" --storage-gib "$STORAGE_GIB")" \
  || { echo "ERROR=could not read the internal partition table"; exit 1; }
echo "$out"
get() { sed -n "s/^$1=//p" <<<"$out"; }
max=$(get ANDROID_MAX_GIB)
rec=64; (( rec > max )) && rec=$max
echo "DEVICE=$disk"
echo "DISK_TOTAL_GIB=$(get DISK_GIB)"
echo "ORIG_ANDROID_GIB=$(get AVAILABLE_GIB | cut -d. -f1)"
echo "MIN_ANDROID_GIB=$(get ANDROID_MIN_GIB)"
echo "MAX_ANDROID_GIB=$max"
echo "RECOMMENDED_ANDROID_GIB=$rec"
echo "BOOT_PART_GIB=2"
echo "ROOT_PART_GIB=$STORAGE_GIB"
echo "EXISTING_INSTALL=$([[ $(get MODE) == installed ]] && echo 1 || echo 0)"
# Lenovo tablets have no microSD slot: our image runs from a USB drive there.
tablet=0
grep -aqE 'lenovo,(tb321fu|elden)' /sys/firmware/devicetree/base/compatible 2>/dev/null && tablet=1
from_usb=0
case "$(readlink -f "/sys/class/block/${root_disk#/dev/}")" in */usb*) from_usb=1 ;; esac
echo "TABLET=$tablet"
if (( tablet )); then
  echo "RUNNING_FROM_SD=$from_usb"
else
  echo "RUNNING_FROM_SD=$([[ $root_disk == /dev/mmcblk* ]] && echo 1 || echo 0)"
fi
