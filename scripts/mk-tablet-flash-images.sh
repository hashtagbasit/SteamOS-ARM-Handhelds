#!/bin/bash
# Lenovo Legion Y700 Gen 3 / Gen 4: fastboot images for an internal install.
#
#   mk-tablet-flash-images.sh tb321fu|elden IMAGE OUT_DIR [KERNEL_OUT]
#
# IMAGE is the tablet's image (BOOT, root and home partitions). Neither
# tablet can start the system from a USB drive, so it goes on internal
# storage, written by fastboot:
#   boot.img       Gen 3 -> boot_a: GUF296's UEFI loader (from the image's
#                  tablet/). Gen 4 -> the active boot slot: our kernel, DTB,
#                  cmdline and startup code in one header v4 image.
#   super.img      Gen 3 only -> super: GUF296's 256 MiB GRUB template with our
#                  one-stage menu, Image and DTBs. The startup code mounts it as /boot
#                  (steamos.bootlabel=super), logs go there too. Android's
#                  system partitions are replaced, so Android is gone;
#                  Lenovo's rescue tool (LMSA) puts it back. The Gen 4 keeps
#                  super: its firmware is copied out of it.
#   userdata.simg  -> userdata: the system and /home in one ext4 filesystem,
#                  Android sparse, grown to the whole partition on first boot
# FLASH_WORK=DIR keeps the scratch files (a 14 GB userdata.img) off /work.
# FLASH_CONSUME_IMAGE=1 deletes IMAGE once userdata.img is written.
# KERNEL_OUT replaces the image's kernel and modules (a newer build of the
# same kernel); the Gen 4 needs it, its boot.img is built from it.
set -euo pipefail
DEV="${1:?tb321fu or elden}"; IMG="${2:?image}"; OUT="${3:?output dir}"; KO="${4:+$(readlink -f "$4")}"
log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
[[ $(id -u) = 0 ]] || die "run as root"
case "$DEV" in tb321fu|elden) ;; *) die "unknown tablet $DEV" ;; esac
[[ $DEV == tb321fu || -n "$KO" ]] || die "the Gen 4 boot.img is built from KERNEL_OUT"
command -v img2simg >/dev/null || die "img2simg missing (android-sdk-libsparse-utils)"

W=$(mktemp -d "${FLASH_WORK:-/work}/$DEV-flash.XXXXXX")
LOOP=""; FAT=""
cleanup() {
  set +e
  for m in "$W/super" "$W/ud" "$W/home" "$W/root" "$W/boot"; do mountpoint -q "$m" && umount "$m"; done
  [[ -n "$FAT" ]] && losetup -d "$FAT"
  [[ -n "$LOOP" ]] && losetup -d "$LOOP"
  rm -rf "$W"
}
trap cleanup EXIT
mkdir -p "$OUT" "$W"/{boot,root,home,super,ud}
rm -f "$OUT"/{boot.img,super.img,userdata.img,userdata.simg,SHA256SUMS}

LOOP=$(losetup -fP --show -r "$IMG")
mount -o ro "${LOOP}p1" "$W/boot"
mount -o ro "${LOOP}p2" "$W/root"
mount -o ro "${LOOP}p3" "$W/home"
B=$W/boot

case "$DEV" in
  tb321fu)
    log "boot.img (UEFI loader)"
    cp "$B/tablet/lenovo-legion-tab-gen3-boot.img" "$OUT/boot.img"
    ;;
  elden)
    log "boot.img (kernel from $KO)"
    mkdir -p "$W/stage"
    bash "$(dirname "$0")/stage-tablet-boot.sh" "$W/stage" elden "$KO" >/dev/null
    cp "$W/stage/tablet/lenovo-legion-y700-gen4-boot.img" "$OUT/boot.img"
    # The startup code inside the Image knows every option, so check the
    # kernel's own cmdline, not the Image.
    cmdline=$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$KO"/config-*)
    [[ " $cmdline " == *" root=PARTLABEL=userdata "* ]] || die "kernel cmdline isn't root=PARTLABEL=userdata"
    [[ " $cmdline " != *" steamos.usbimage=1 "* ]] || die "kernel still has the USB image fallback"
    ;;
esac

if [[ $DEV == tb321fu ]]; then
  log "super.img (GRUB template, one-stage menu)"
  source "$(dirname "$0")/../external-and-mods/tb321fu-boot/release.env"
  tmpl="${CACHE:-/work/cache}/tb321fu-boot/super-template.img"
  mkdir -p "$(dirname "$tmpl")"
  if ! echo "$TB321FU_SUPER_TEMPLATE_SHA256  $tmpl" | sha256sum -c --quiet >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$tmpl" "$TB321FU_SUPER_TEMPLATE_URL"
    echo "$TB321FU_SUPER_TEMPLATE_SHA256  $tmpl" | sha256sum -c --quiet || die "super template hash mismatch"
  fi
  cp "$tmpl" "$OUT/super.img"
  FAT=$(losetup -f --show "$OUT/super.img")
  mount "$FAT" "$W/super"
  S=$W/super
  rm -f "$S/Image" "$S"/dtb/*
  if [[ -n "$KO" ]]; then
    cp "$KO/boot/Image" "$S/Image"
    cp "$KO"/dtbs/sm8650-lenovo-tb321fu-{boe,csot}.dtb "$S/dtb/"
  else
    cp "$B/Image" "$S/Image"
    cp "$B"/dtb/sm8650-lenovo-tb321fu-{boe,csot}.dtb "$S/dtb/"
  fi
  # The template's BOOTAA64.EFI reads boot/grub/grub.cfg on this FAT and sets
  # $root to it. One stage: the DTB and the kernel through its EFI stub, no
  # initrd (the startup code is in the Image). The kernel prints on the panel
  # (beta), its logs go to this FAT (steamos.bootlabel=super), and the Logs
  # entries show them, since nothing can read super from a PC.
  opts="root=PARTLABEL=userdata rw rootwait rootfstype=ext4 steamos.bootlabel=super"
  opts+=" firmware_class.path=/usr/lib/firmware/steamos-arm/tb321fu efi=novamap"
  opts+=" console=tty1 fbcon=map:0 console=tty0 loglevel=4 allow_mismatched_32bit_el0"
  opts+=" fw_devlink.strict=1 pcie_ports=compat cgroup.memory=nokmem,nosocket swiotlb=8192"
  opts+=" irqaffinity=0-1 mem_sleep_default=s2idle"
  {
    printf 'set timeout=-1\nset default=0\nset gfxpayload=keep\n'
    for p in csot boe; do
      printf '\nmenuentry "Zaviya (%s panel)" {\n' "${p^^}"
      printf '    devicetree /dtb/sm8650-lenovo-tb321fu-%s.dtb\n    linux /Image %s\n}\n' "$p" "$opts"
    done
    cat <<'CFG'

menuentry "Logs 1: list the log files" {
    insmod ls
    insmod sleep
    ls -l /
    echo "--- debug-logs:"
    ls -l /debug-logs/
    echo "(hold Power ~15 s to leave)"
    sleep 900
}

menuentry "Logs 2: boot log (end of it)" {
    insmod cat
    insmod sleep
    cat /bootlog.txt
    echo "(hold Power ~15 s to leave)"
    sleep 900
}

menuentry "Logs 3: live kernel log after the handover (end of it)" {
    insmod cat
    insmod sleep
    cat /bootlog-live-0.txt
    echo "=== that was live-0, live-1 follows in 20 s"
    sleep 20
    cat /bootlog-live-1.txt
    echo "(hold Power ~15 s to leave)"
    sleep 900
}

menuentry "Logs 4: system partition (did Linux start?)" {
    insmod ls
    insmod sleep
    insmod part_gpt
    insmod ext2
    insmod search_label
    search --no-floppy --label userdata --set=ud
    echo "system partition: $ud"
    echo "--- /var/log:"
    ls -l ($ud)/var/log/
    echo "--- journal:"
    ls -l ($ud)/var/log/journal/
    echo "--- steamos-arm-boot:"
    ls -l ($ud)/var/log/steamos-arm-boot/
    echo "--- /var/lib/systemd:"
    ls -l ($ud)/var/lib/systemd/
    echo "(hold Power ~15 s to leave)"
    sleep 900
}

menuentry "Logs 5: system partition boot log (end of it)" {
    insmod cat
    insmod sleep
    insmod part_gpt
    insmod ext2
    insmod search_label
    search --no-floppy --label userdata --set=ud
    cat ($ud)/var/log/steamos-arm-boot/bootlog.txt
    echo "(hold Power ~15 s to leave)"
    sleep 900
}
CFG
  } > "$S/boot/grub/grub.cfg"
  echo 'configfile /boot/grub/grub.cfg' > "$S/EFI/BOOT/grub.cfg"
  [[ $(grep -c '^menuentry "Zaviya' "$S/boot/grub/grub.cfg") = 2 ]] || die "boot entries missing"
  ! grep -q -E 'usbimage|STORAGE' "$S/boot/grub/grub.cfg" || die "old root or USB fallback in the menu"
  # Beta: logs on every boot (bootlog.txt, debug-logs/). Delete /boot/debug to stop them.
  : > "$S/debug"
  sync; umount "$S"; losetup -d "$FAT"; FAT=""
  fsck.fat -n "$OUT/super.img" | tail -1
fi
# SUPER_ONLY=1 (Gen 3): just boot.img and super.img, to try a new kernel
# against the system already on the tablet.
if [[ ${SUPER_ONLY:-0} == 1 ]]; then
  (cd "$OUT" && sha256sum boot.img super.img > SHA256SUMS && cat SHA256SUMS)
  log "done (super only)"
  exit 0
fi

log "userdata.img (ext4: system and /home)"
used=$(( $(du -sxB1M "$W/root" | cut -f1) + $(du -sxB1M "$W/home" | cut -f1) ))
size=$(( used * 110 / 100 + 1024 ))
truncate -s "${size}M" "$OUT/userdata.img"
mkfs.ext4 -q -F -L userdata -m 1 "$OUT/userdata.img"
mount "$OUT/userdata.img" "$W/ud"
U=$W/ud
rsync -aAXH --numeric-ids --exclude='/home/*' --exclude='/boot/*' "$W/root/" "$U/"
rsync -aAXH --numeric-ids --exclude='/lost+found' "$W/home/" "$U/home/"
if [[ -n "$KO" ]]; then
  kr=$(basename "$(ls -d "$KO"/modules/lib/modules/* 2>/dev/null || ls -d "$KO"/modules/*)")
  src=$(ls -d "$KO"/modules/lib/modules/"$kr" 2>/dev/null || ls -d "$KO"/modules/"$kr")
  rm -rf "$U/usr/lib/modules/$kr"; cp -a "$src" "$U/usr/lib/modules/$kr"
  log "kernel and modules from $KO ($kr)"
fi
FSTAB='# Lenovo Legion Y700: system and /home on userdata
PARTLABEL=userdata  /      ext4  defaults,noatime,x-systemd.growfs  0 1
'
# super is a 512-byte-sector FAT on 4K-sector UFS: Linux mounts it only
# through a loop device. Readable by everyone (writable by root only): a
# tester sends debug-logs from it with the file manager.
[[ $DEV == tb321fu ]] && FSTAB+='/dev/disk/by-partlabel/super  /boot  vfat  loop,defaults,umask=0022,nofail  0 0
'
printf '%s' "$FSTAB" > "$U/etc/fstab"
[[ -d "$U/var/lib/overlays/etc/upper" ]] && printf '%s' "$FSTAB" > "$U/var/lib/overlays/etc/upper/fstab"
# /home is a folder on the system partition here. Without a /home line in
# fstab, SteamOS's own home.mount takes over and waits for the Deck's home
# partition (by-partsets/shared/home), and basic.target fails with it.
ln -sfn /dev/null "$U/etc/systemd/system/home.mount"
# Never let systemd-repart (Valve's repart.d adds a home partition) touch the
# internal disk, where Android's partitions are; efi.mount, esp.mount and
# steamos-boot wait for the Deck's EFI partition. The chip images mask these
# too, but tablet images built before that was fixed on 8 Elite don't.
for u in systemd-repart.service efi.mount esp.mount steamos-boot.service; do
  ln -sfn /dev/null "$U/etc/systemd/system/$u"
done
# /home is already the whole partition: the microSD image's first-boot grow
# of its home partition must not run.
mkdir -p "$U/var/lib/steamos-sm8550"; touch "$U/var/lib/steamos-sm8550/home-expanded"
[[ -x "$U/sbin/init" || -L "$U/sbin/init" ]] || die "no /sbin/init in the system"
[[ -d "$U/home/steamos" ]] || die "no /home/steamos"
sync; umount "$U"
e2fsck -fy "$OUT/userdata.img" >/dev/null 2>&1 || true
e2fsck -fn "$OUT/userdata.img" >/dev/null || die "userdata.img doesn't check clean"

# FLASH_CONSUME_IMAGE=1: the image is no longer needed once userdata.img is
# written, so release and delete it before the sparse copy (short of disk).
if [[ ${FLASH_CONSUME_IMAGE:-0} == 1 ]]; then
  for m in "$W/root" "$W/home" "$W/boot"; do umount "$m"; done
  losetup -d "$LOOP"; LOOP=""
  rm -f "$IMG"
fi

log "userdata.simg (Android sparse)"
img2simg "$OUT/userdata.img" "$OUT/userdata.simg"
rm -f "$OUT/userdata.img"
(cd "$OUT" && sha256sum boot.img $([[ -f super.img ]] && echo super.img) userdata.simg > SHA256SUMS && cat SHA256SUMS)
ls -l "$OUT"
log "done"
