#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Install the Zaviya running from the microSD card to internal UFS.
# KONKR Pocket FIT / AYANEO Pocket S2 (SM8650), SM8550 handhelds such as
# the AYN Odin 2 / Odin 2 Mini / Odin 2 Portal, and the AYN Odin 3 / KONKR
# Pocket FIT Elite (SM8750), with OpenABL.
#
#   ... | userdata (Android, you pick) | boot 2G | system 20G | home (rest) |
#
# Android's partitions stay as they are; only userdata's end moves, and it is
# erased. The old partition table is saved to the SD card's /boot/ufs-backup
# first, and `ufs-partition.py restore` puts it back.
#
# Usage (from Zaviya on the SD card, as root):
#   install-to-internal.sh                  interactive
#   install-to-internal.sh --android-gb 32
#   install-to-internal.sh --dry-run        show the plan, write nothing
#   install-to-internal.sh --resume         partitions exist: copy again
#
# Options:
#   --android-gb N     Android userdata size (GiB)
#   --storage-gb N     Zaviya system partition (GiB, default 20)
#   --home all|essentials|none
#                      what to bring from the SD's /home (default all);
#                      essentials leaves installed games behind
#   --expect FP        only write if the table fingerprint is still FP (GUI)
#   --force            no confirmation prompt
set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BOOT_LABEL="$(cat "$HERE/boot-label")"
PART=(python3 "$HERE/ufs-partition.py")
BOOTIMG=(python3 "$HERE/ufs-bootimg.py")

ANDROID_GB=""
STORAGE_GB=20
HOME_MODE=all
EXPECT=""
DRY_RUN=0
FORCE=0
RESUME=0
DISK=""
WORK=/run/ufs-install
BACKUP_DIR=/boot/ufs-backup

log()  { printf '\033[1;32m[ufs]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ufs] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --android-gb) ANDROID_GB="${2:?}"; shift 2 ;;
    --storage-gb) STORAGE_GB="${2:?}"; shift 2 ;;
    --home) HOME_MODE="${2:?}"; shift 2 ;;
    --expect) EXPECT="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --resume|--deploy-only) RESUME=1; shift ;;
    --disk) DISK="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done
case "$HOME_MODE" in all|essentials|none) ;; *) die "--home all|essentials|none" ;; esac

# ------------------------------------------------------------ preflight ----
[[ $EUID -eq 0 ]] || die "run as root (sudo)"
for t in sfdisk mkfs.vfat mkfs.ext4 rsync findmnt lsblk python3 md5sum blockdev; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done

# TABLET: a Lenovo tablet booted by its own bootloader, running from our image
# on a USB drive (no OpenABL, no microSD slot): its boot files go to the
# ESP and its boot partition instead of a KERNEL for the ABL.
TABLET=""
compat="$(tr '\0' '\n' </sys/firmware/devicetree/base/compatible)"
grep -qx 'lenovo,tb321fu' <<<"$compat" && TABLET=tb321fu
grep -qx 'lenovo,elden' <<<"$compat" && TABLET=elden
grep -qx 'qcom,sm8250' <<<"$compat" \
  && die "internal install isn't supported on Snapdragon 865 devices yet, keep running Zaviya from the microSD card"
[[ -n "$TABLET" ]] || grep -qxE 'qcom,sm8650|qcom,sm8550|qcom,sm8750' <<<"$compat" \
  || die "this installer is for SM8650, SM8550 and SM8750 devices (KONKR Pocket FIT / Pocket FIT Elite, AYANEO Pocket S2, AYN Odin 2 / Odin 2 Mini / Odin 2 Portal / Odin 3) and the Lenovo Legion Y700 Gen 3 / Gen 4"
MODEL="$(tr -d '\0' </sys/firmware/devicetree/base/model)"

# The initramfs carries no modules, so root on UFS needs the drivers built in.
for m in ufshcd_core ufshcd_pltfrm ufs_qcom phy_qcom_qmp_ufs sd_mod; do
  [[ -e /sys/module/$m/initstate ]] && die "$m is a loadable module; this kernel can't boot from UFS"
done

ROOT_SRC="$(findmnt -no SOURCE /)"
ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" | head -1)"
if [[ -n "$TABLET" ]]; then
  case "$(readlink -f "/sys/class/block/${ROOT_DISK#/dev/}")" in
    */usb*) ;;
    *) die "run this from the image on a USB drive (/ is on $ROOT_SRC)" ;;
  esac
else
  [[ "$ROOT_DISK" == /dev/mmcblk* ]] || die "run this from the microSD install (/ is on $ROOT_SRC)"
fi

[[ -f /boot/KERNEL ]] || die "/boot/KERNEL not found (is the SD's boot partition mounted?)"
"${BOOTIMG[@]}" check /boot/KERNEL >/dev/null \
  || die "the SD's KERNEL can't boot from a partition label; update the SD image first"

# /boot is mounted read-only by default on some targets (e.g. SM8750);
# remount it read-write so the GPT backup can be saved before repartitioning.
mount -o remount,rw /boot 2>/dev/null || true

if [[ -z "$DISK" ]]; then
  for d in /dev/sd[a-z]; do
    [[ -b "$d" && "$d" != "$ROOT_DISK" ]] || continue
    lsblk -rno PARTLABEL "$d" 2>/dev/null | grep -qx userdata && { DISK="$d"; break; }
  done
fi
[[ -n "$DISK" ]] || die "no internal disk with a userdata partition found"
[[ "$DISK" != "$ROOT_DISK" ]] || die "refusing to install onto the disk we're running from"

# ---------------------------------------------------------------- inspect --
eval "$("${PART[@]}" detect --disk "$DISK" --storage-gib "$STORAGE_GB" \
       | sed -n "s/^\([A-Z_]*\)=\([^']*\)$/P_\1='\2'/p")"
log "$MODEL: internal disk $DISK (${P_DISK_GIB} GiB, ${P_SECTOR_SIZE}-byte sectors)"

case "$P_MODE" in
  fresh)
    (( RESUME )) && die "--resume needs an existing install; this disk has none" ;;
  installed)
    (( RESUME )) || die "Zaviya partitions already exist. Use Zaviya Update to preserve games and saves. --resume reformats system and HOME, erasing internal user data. For a fresh install, remove them first in the ABL menu (UNINSTALL CFW)." ;;
  occupied)
    die "unknown partitions after userdata (${P_OCCUPIED}). Remove them with the ABL menu (UNINSTALL CFW) first; nothing was changed." ;;
  toosmall)
    die "not enough room after userdata for Zaviya" ;;
  *) die "unexpected disk state ${P_MODE}" ;;
esac
[[ -z "$EXPECT" || "$EXPECT" == "$P_TABLE_FINGERPRINT" ]] \
  || die "the partition table changed since it was checked; check again"

part_of() {   # GPT name -> /dev node on $DISK, read from the table (not udev)
  "${PART[@]}" detect --disk "$DISK" --storage-gib "$STORAGE_GB" | sed -n "s/^NODE_$1=//p"
}

GAMES_EXCLUDES=(
  --exclude='/steamos/.local/share/Steam/steamapps/common/'
  --exclude='/steamos/.local/share/Steam/steamapps/shadercache/'
  --exclude='/steamos/.local/share/Steam/steamapps/compatdata/'
  --exclude='/steamos/.local/share/Steam/steamapps/downloading/'
  --exclude='/steamos/.local/share/Steam/steamapps/appmanifest_*.acf'
)
# "Start fresh" still needs the Steam client and Decky from /home, or Steam
# can't start at all (black screen). Leave out everything personal instead.
FRESH_EXCLUDES=(
  "${GAMES_EXCLUDES[@]}"
  --exclude='/steamos/.local/share/Steam/config/loginusers.vdf'
  --exclude='/steamos/.local/share/Steam/config/config.vdf'
  --exclude='/steamos/.local/share/Steam/config/DialogConfig.vdf'
  --exclude='/steamos/.local/share/Steam/config/libraryfolders.vdf'
  --exclude='/steamos/.local/share/Steam/config/remoteclients.vdf'
  --exclude='/steamos/.local/share/Steam/config/avatarcache/'
  --exclude='/steamos/.local/share/Steam/config/htmlcache/'
  --exclude='/steamos/.local/share/Steam/appcache/httpcache/'
  --exclude='/steamos/.local/share/Steam/appcache/cefdata/'
  --exclude='/steamos/.local/share/Steam/userdata/'
  --exclude='/steamos/.local/share/Steam/ssfn*'
  --exclude='/steamos/.local/share/Steam/logs/'
  --exclude='/steamos/.steam/registry.vdf'
  --exclude='/steamos/Android/'
  --exclude='/steamos/.local/share/konkr-apk/'
  --exclude='/steamos/.local/share/Trash/'
  --exclude='/steamos/.var/'
  --exclude='/steamos/.mozilla/'
  --exclude='/steamos/Documents/*' --exclude='/steamos/Downloads/*'
  --exclude='/steamos/Pictures/*' --exclude='/steamos/Music/*' --exclude='/steamos/Videos/*'
)
home_bytes() {
  case "$HOME_MODE" in
    all) du -sxb /home | awk '{print $1}' ;;
    essentials|none)
      local g=/home/steamos/.local/share/Steam/steamapps t s
      t=$(du -sxb /home | awk '{print $1}')
      s=$(du -scxb "$g/common" "$g/shadercache" "$g/compatdata" 2>/dev/null | tail -1 | awk '{print $1}')
      echo $(( t - ${s:-0} )) ;;
  esac
}

# ------------------------------------------------------------------ plan ---
if (( ! RESUME )); then
  if [[ -z "$ANDROID_GB" ]]; then
    (( FORCE )) && die "--android-gb is required with --force"
    echo
    echo "Android keeps its system; its user data (apps, photos, accounts) is erased."
    echo "Android userdata can be ${P_ANDROID_MIN_GIB}..${P_ANDROID_MAX_GIB} GiB; Zaviya gets the rest."
    read -r -p "Android size in GiB: " ANDROID_GB
  fi
  [[ "$ANDROID_GB" =~ ^[0-9]+$ ]] || die "Android size must be a whole number of GiB"
  (( ANDROID_GB >= P_ANDROID_MIN_GIB && ANDROID_GB <= P_ANDROID_MAX_GIB )) \
    || die "Android size must be ${P_ANDROID_MIN_GIB}..${P_ANDROID_MAX_GIB} GiB"
  PLAN="$("${PART[@]}" apply --disk "$DISK" --storage-gib "$STORAGE_GB" \
          --android-gib "$ANDROID_GB" --expect "$P_TABLE_FINGERPRINT" \
          --backup-dir "$BACKUP_DIR" --dry-run | sed '/^--- new table/,$d')"
  # The plan is every line before the table dump. Counting them (1,4p) lost
  # HOME once the metadata line was added, and every fresh install then
  # stopped with "doesn't fit HOME (0 GiB)".
  home_size=$(awk '/^HOME/ {print $5}' <<<"$PLAN")
  [[ "$home_size" =~ ^[0-9]+$ ]] || die "could not read the HOME size from the plan"
  home_size=$(( home_size * P_SECTOR_SIZE ))
else
  home_size=$(blockdev --getsize64 "$(part_of HOME)")
fi

need=$(home_bytes)
root_used=$(df -B1 --output=used / | tail -1)
(( root_used < STORAGE_GB * (1 << 30) * 9 / 10 )) \
  || die "the SD system ($(( root_used >> 30 )) GiB) doesn't fit a ${STORAGE_GB} GiB STORAGE"
(( need < home_size * 95 / 100 )) \
  || die "/home to copy ($(( need >> 30 )) GiB) doesn't fit HOME ($(( home_size >> 30 )) GiB); try --home essentials"

echo
echo "Plan for $DISK:"
if (( RESUME )); then
  echo "  REINSTALL: reformat boot / system / home; all internal Linux games, saves and login data are ERASED"
else
  sed 's/^/  /' <<<"$PLAN"
  echo "  Android userdata is ERASED (Android sets itself up again on its next boot)"
  echo "  the old partition table is saved to the SD card first: $BACKUP_DIR"
fi
echo "  system: a copy of this SD install ($(( root_used >> 30 )) GiB)"
case "$HOME_MODE" in
  all) echo "  /home: copied from the SD card, games included ($(( need >> 30 )) GiB)" ;;
  essentials) echo "  /home: copied without installed games ($(( need >> 30 )) GiB)" ;;
  none) echo "  /home: fresh, no account or personal data (Steam starts from its first-run setup)" ;;
esac
echo
if (( DRY_RUN )); then
  log "dry run: nothing was written"
  exit 0
fi
if (( ! FORCE )); then
  read -r -p "Type ERASE to continue: " ok
  [[ "$ok" == ERASE ]] || die "cancelled; nothing was written"
fi

# --------------------------------------------------------------- execute ---
mounted=()
cleanup() {
  local i
  for (( i=${#mounted[@]}-1; i>=0; i-- )); do umount "${mounted[i]}" 2>/dev/null || true; done
  mounted=()
}
trap cleanup EXIT
mnt() { mkdir -p "$2"; mount "${@:3}" "$1" "$2"; mounted+=("$2"); }

# The boot partition the tablet starts from: Qualcomm A/B keeps the active
# slot in the GPT attributes (bit 50 of boot_a / boot_b); without slots, boot.
boot_slot_part() {
  local s attrs
  for s in a b; do
    [[ -e /dev/disk/by-partlabel/boot_$s ]] || continue
    attrs="$(sfdisk --part-attrs "$(lsblk -no PKNAME "$(readlink -f /dev/disk/by-partlabel/boot_$s)" | sed 's|^|/dev/|')" \
      "$(cat "/sys/class/block/$(basename "$(readlink -f /dev/disk/by-partlabel/boot_$s)")/partition")" 2>/dev/null)"
    grep -Eq '(^|[^0-9])50([^0-9]|$)' <<<"${attrs#*GUID:}" && [[ "$attrs" == *GUID:* ]] \
      && { readlink -f /dev/disk/by-partlabel/boot_$s; return 0; }
  done
  [[ -e /dev/disk/by-partlabel/boot ]] && { readlink -f /dev/disk/by-partlabel/boot; return 0; }
  return 1
}

# Write a boot image to the active boot partition, the stock one saved first
# (once) to HOME's .ufs-backup, and read back.
flash_boot() {
  local img="$1" part size n
  part="$(boot_slot_part)" || die "no boot partition found"
  size="$(blockdev --getsize64 "$part")"
  n="$(stat -c %s "$img")"
  (( n <= size )) || die "$(basename "$img") ($n bytes) doesn't fit $part ($size)"
  mkdir -p "$WORK/home/.ufs-backup"
  local stock="$WORK/home/.ufs-backup/stock-$(basename "$(udevadm info -q property -n "$part" | sed -n 's/^ID_PART_ENTRY_NAME=//p')").img"
  [[ -s "$stock" ]] || dd if="$part" of="$stock" bs=4M status=none conv=fsync
  log "writing $(basename "$img") to $part (stock copy: ${stock#$WORK/home/})"
  dd if="$img" of="$part" bs=4M status=none conv=fsync
  cmp -s -n "$n" "$img" "$part" || die "$part doesn't read back as written; restore $stock with fastboot"
}

install_tablet_boot() {
  case "$TABLET" in
    tb321fu)
      # The panel this boot is running on is the one that works.
      local panel
      case "$MODEL" in
        *"BOE panel"*) panel=boe ;;
        *"CSOT panel"*) panel=csot ;;
        *) die "can't tell the panel from \"$MODEL\"" ;;
      esac
      log "Legion Y700 Gen 3 ($panel panel): GRUB and the kernel on the boot partition"
      # The drive's BOOT already has it all (stage-tablet-boot.sh); take it
      # from there, with only this panel's entry and no menu wait.
      local dtb="sm8650-lenovo-tb321fu-$panel.dtb" f
      for f in EFI/BOOT/BOOTAA64.EFI EFI/BOOT/QCOMRAMP.EFI EFI/BOOT/grub.cfg EFI/BOOT/qcomramp.cfg \
               Image "dtb/$dtb" tablet/lenovo-legion-tab-gen3-boot.img; do
        [[ -s "/boot/$f" ]] || die "/boot/$f missing on the USB drive's BOOT"
      done
      mkdir -p "$WORK/boot/EFI/BOOT" "$WORK/boot/dtb"
      cp /boot/EFI/BOOT/BOOTAA64.EFI /boot/EFI/BOOT/QCOMRAMP.EFI /boot/EFI/BOOT/grub.cfg "$WORK/boot/EFI/BOOT/"
      cp /boot/Image "$WORK/boot/Image"
      cp "/boot/dtb/$dtb" "$WORK/boot/dtb/"
      python3 - "/boot/EFI/BOOT/qcomramp.cfg" "$WORK/boot/EFI/BOOT/qcomramp.cfg" "$dtb" <<'PY' || die "no $panel entry in the GRUB config"
import re, sys
src, dst, dtb = sys.argv[1:]
text = open(src).read()
entries = re.findall(r'menuentry "[^"]*" \{.*?\n\}', text, re.S)
mine = [e for e in entries if "/dtb/" + dtb in e]
if not mine:
    sys.exit(1)
entry = re.sub(r'menuentry "[^"]*"', 'menuentry "Zaviya"', mine[0], count=1)
open(dst, "w").write("set timeout=0\nset default=0\nset gfxpayload=keep\n\n" + entry + "\n")
PY
      # This ESP's own marker (the USB drive's stays on the drive), in both
      # GRUB stages.
      local mark="steamos-arm-boot-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      echo "Zaviya boot partition (GRUB looks for this file)" >"$WORK/boot/$mark"
      sed -i -E "s|--file /[^ ]+ --set=root|--file /$mark --set=root|" \
        "$WORK/boot/EFI/BOOT/qcomramp.cfg" "$WORK/boot/EFI/BOOT/grub.cfg"
      grep -q -- "--file /$mark --set=root" "$WORK/boot/EFI/BOOT/qcomramp.cfg" \
        && grep -q -- "--file /$mark --set=root" "$WORK/boot/EFI/BOOT/grub.cfg" \
        || die "GRUB configs don't point at this ESP"
      grep -q 'root=PARTLABEL=STORAGE' "$WORK/boot/EFI/BOOT/qcomramp.cfg" || die "GRUB config has no root=PARTLABEL=STORAGE"
      flash_boot /boot/tablet/lenovo-legion-tab-gen3-boot.img ;;
    elden)
      log "Legion Y700 Gen 4: firmware from Android, then the boot image"
      local fw=/var/lib/steamos-arm/firmware/elden
      /usr/lib/steamos-arm/tablet-firmware /usr/share/steamos-arm/tablets/elden-firmware.json "$fw" \
        --also /usr/lib/firmware
      mkdir -p "$WORK/root$fw"
      rsync -a "$fw/" "$WORK/root$fw/"
      flash_boot /boot/tablet/lenovo-legion-y700-gen4-boot.img ;;
  esac
}

if (( ! RESUME )); then
  log "repartitioning (one write; the old table goes to $BACKUP_DIR first)"
  "${PART[@]}" apply --disk "$DISK" --storage-gib "$STORAGE_GB" \
    --android-gib "$ANDROID_GB" --expect "$P_TABLE_FINGERPRINT" --backup-dir "$BACKUP_DIR"
fi
udevadm settle -t 10 >/dev/null 2>&1 || true
BOOTP="$(part_of "$BOOT_LABEL")"; ST="$(part_of STORAGE)"; HM="$(part_of HOME)"
[[ -b "$BOOTP" && -b "$ST" && -b "$HM" ]] || die "new partitions didn't show up; reboot to the SD and run with --resume"
for p in "$BOOTP" "$ST" "$HM"; do
  if findmnt -rno TARGET -S "$p" >/dev/null; then die "$p is mounted; unmount it first"; fi
done

log "formatting"
mkfs.vfat -F 32 -S "$P_SECTOR_SIZE" -n "$BOOT_LABEL" "$BOOTP" >/dev/null
mkfs.ext4 -F -q -L STORAGE -m 1 "$ST"
mkfs.ext4 -F -q -L home -m 0 "$HM"

mnt "$BOOTP" "$WORK/boot"
mnt "$ST" "$WORK/root"
mnt "$HM" "$WORK/home"
# The SD's root filesystem alone, read-only: no /proc, /run, /home or /boot
# submounts, and /etc as its two overlay layers rather than the merged view,
# so the copy is exactly what's on the card.
mnt / "$WORK/src" --bind
mount -o remount,bind,ro "$WORK/src"

log "copying the system (a few minutes)"
rsync -aAXH --numeric-ids --info=progress2 "$WORK/src/" "$WORK/root/"

FSTAB="# Zaviya on internal UFS (partitions by GPT name)
PARTLABEL=STORAGE  /      ext4  defaults,noatime                  0 1
PARTLABEL=$BOOT_LABEL  /boot  vfat  defaults,umask=0077,nofail        0 2
PARTLABEL=HOME     /home  ext4  defaults,noatime,commit=30        0 2
"
printf '%s' "$FSTAB" >"$WORK/root/etc/fstab"
if [[ -d "$WORK/root/var/lib/overlays/etc/upper" ]]; then
  printf '%s' "$FSTAB" >"$WORK/root/var/lib/overlays/etc/upper/fstab"
fi
# HOME already fills its partition; the SD's first-boot grow must not run.
mkdir -p "$WORK/root/var/lib/steamos-sm8550"
touch "$WORK/root/var/lib/steamos-sm8550/home-expanded"

case "$HOME_MODE" in
  all)
    log "copying /home (games included)"
    rsync -aAXH --numeric-ids --info=progress2 --exclude=/lost+found /home/ "$WORK/home/" ;;
  essentials)
    log "copying /home without installed games"
    rsync -aAXH --numeric-ids --info=progress2 --exclude=/lost+found "${GAMES_EXCLUDES[@]}" \
      /home/ "$WORK/home/" ;;
  none)
    log "copying a fresh /home (Steam client and Decky, no account or personal data)"
    rsync -aAXH --numeric-ids --info=progress2 --exclude=/lost+found "${FRESH_EXCLUDES[@]}" \
      /home/ "$WORK/home/"
    # Same first-run state as a freshly flashed card: Steam's setup runs, and
    # Wi-Fi stays on wpa_supplicant (see install-complete-steam-client.sh).
    mkdir -p "$WORK/home/steamos/.steam" "$WORK/home/steamos/.local/share/Steam/config"
    printf '%b\n' '"Registry"' '{' '\t"HKCU"' '\t{' '\t\t"Software"' '\t\t{' \
      '\t\t\t"Valve"' '\t\t\t{' '\t\t\t\t"Steam"' '\t\t\t\t{' \
      '\t\t\t\t\t"RunningAppID"\t\t"0"' \
      '\t\t\t\t\t"ForceOOBE"\t\t"1"' \
      '\t\t\t\t}' '\t\t\t}' '\t\t}' '\t}' '}' >"$WORK/home/steamos/.steam/registry.vdf"
    printf '%b\n' '"InstallConfigStore"' '{' '\t"SteamOS"' '\t{' \
      '\t\t"WifiForceWPASupplicant"\t\t"1"' '\t}' '}' \
      >"$WORK/home/steamos/.local/share/Steam/config/config.vdf"
    chown 1000:1000 "$WORK/home/steamos" "$WORK/home/steamos/.steam" \
      "$WORK/home/steamos/.steam/registry.vdf" "$WORK/home/steamos/.local/share/Steam/config" \
      "$WORK/home/steamos/.local/share/Steam/config/config.vdf" ;;
esac

log "installing KERNEL (root=PARTLABEL=STORAGE)"
"${BOOTIMG[@]}" retarget /boot/KERNEL "$WORK/boot/KERNEL" --root PARTLABEL=STORAGE >/dev/null
(cd "$WORK/boot" && md5sum KERNEL >KERNEL.md5)
EFI_SYNC=/usr/lib/steamos-arm/kernel-efi-sync
[[ -x "$EFI_SYNC" ]] && "$EFI_SYNC" --boot "$WORK/boot" --force >/dev/null || true
if [[ -n "$TABLET" ]]; then
  install_tablet_boot
fi
if compgen -G "$BACKUP_DIR/ufs-gpt-*" >/dev/null; then
  mkdir -p "$WORK/home/.ufs-backup"
  cp "$BACKUP_DIR"/ufs-gpt-* "$WORK/home/.ufs-backup/"
fi
sync

# ----------------------------------------------------------------- verify --
log "checking the result"
info="$("${BOOTIMG[@]}" info "$WORK/boot/KERNEL")"
grep -q 'root=PARTLABEL=STORAGE' <<<"$info" || die "KERNEL cmdline is wrong"
grep -q '^ID_OK=yes' <<<"$info" || die "KERNEL header checksum is wrong"
(cd "$WORK/boot" && md5sum -c --quiet KERNEL.md5) || die "KERNEL.md5 mismatch"
[[ -e "$WORK/root/sbin/init" || -L "$WORK/root/sbin/init" ]] || die "system copy is incomplete (no /sbin/init)"
cmp -s <(printf '%s' "$FSTAB") "$WORK/root/etc/fstab" || die "fstab not written"
[[ -d "$WORK/home/steamos" ]] || die "/home/steamos missing on HOME"
[[ "$(stat -c %u "$WORK/home/steamos")" == 1000 ]] || die "/home/steamos has the wrong owner"

cleanup
echo
log "done. Zaviya is on internal storage."
if [[ -n "$TABLET" ]]; then
  echo "  - Power off and unplug the USB drive, then power on: it starts Zaviya from"
  echo "    internal storage."
  echo "  - Android's boot image is saved in /home/.ufs-backup (stock-boot_*.img). To go back"
  echo "    to Android, flash it from a PC: fastboot flash boot stock-boot_<slot>.img"
  exit 0
fi
echo "  - Power off and take out the SD card. In the ABL menu (hold Volume Down at power-on),"
echo "    set Boot source to Internal, then boot Linux. With Boot source on SD it stops at"
echo "    \"no volumes match boot source\"."
echo "  - Android: pick it in the ABL menu; it sets itself up again (userdata was erased)."
if (( ! RESUME )); then
  echo "  - Old partition table: $BACKUP_DIR on the SD card (a copy is in /home/.ufs-backup)."
  echo "    To give the space back to Android, boot the SD card and run:"
  echo "      sudo ufs-partition.py restore --backup <that .sfdisk file>"
fi
