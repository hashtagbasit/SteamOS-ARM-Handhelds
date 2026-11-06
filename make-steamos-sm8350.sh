#!/usr/bin/env bash
# Build a Zaviya fastboot kit for the REDMAGIC 6 (Nubia NX669J, SM8350).
#
# The phone has no SD slot and boots from Nubia's stock (unlocked) ABL, so
# instead of a card image this makes a kit that fastboot flashes:
#   boot.img                   the kernel (external-and-mods/kernel-sm8350)
#   vendor_boot.img            DTB + initramfs + cmdline
#   vendor_boot-debug.img      same, verbose, with a USB debug shell
#   userdata.img               sparse ext4: root with /home inside it, grown to
#                              the whole partition on first boot (x-systemd.growfs)
#   vbmeta.img                 Nubia's, with verification disabled
#   flash-redmagic6.sh / .bat  the fastboot steps (docs/redmagic6.md)
# The root is found by PARTLABEL=userdata, so nothing is patched per kit.
#
# The userspace is the rootfs every chip shares: either the one
# make-steamos-sm8650.sh built (default: ${STEAMOS_WORK}/rootfs) or the one
# in a released card image (--from-img). It is copied, then
# scripts/apply-overlays-sm8350.sh swaps in this kernel's modules and the
# REDMAGIC 6 overlay.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="${ROOT}/scripts"
MOD="${ROOT}/external-and-mods"
# Rootfs, mounts and kit must live on a Linux filesystem (not exFAT).
WORKDIR="${STEAMOS_WORK:-/work}"
R="${STEAMOS_ROOTFS:-${WORKDIR}/rootfs-sm8350}"
KOUT="$(readlink -f "${KERNEL_OUT:-${WORKDIR}/kernel-sm8350/output/current}")"
KIT="${STEAMOS_KIT:-${WORKDIR}/steamos-sm8350-redmagic6}"
# Stock images from scripts/extract-nx669j-firmware.sh (for vbmeta).
NX669J_STOCK="${NX669J_STOCK:-${WORKDIR}/nx669j-firmware.stock}"
MNT="${WORKDIR}/.image-mnt"
LOOPDEV=""

SRC_ROOTFS="${WORKDIR}/rootfs"
SRC_IMG=""
SKIP_COPY=0
SKIP_APPLY=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

sudo_run() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return
  fi
  sudo "$@"
}

usage() {
  cat <<EOF
Usage: $0 [options]

  --from-rootfs DIR  Shared rootfs to start from (default: ${SRC_ROOTFS},
                     built by make-steamos-sm8650.sh)
  --from-img IMG     Start from a released Zaviya card image instead
                     (its p2 root and p3 home)
  --skip-copy        Reuse ${R} as it is (no fresh copy)
  --skip-apply       Do not re-run scripts/apply-overlays-sm8350.sh
  --kit DIR          Output directory (default: ${KIT})

Env: STEAMOS_WORK STEAMOS_ROOTFS KERNEL_OUT NX669J_STOCK STEAMOS_KIT
Before this: scripts/extract-nx669j-firmware.sh NX669J-update.zip and
external-and-mods/kernel-sm8350/build.sh (see docs/redmagic6.md).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-rootfs) SRC_ROOTFS="$2"; shift ;;
    --from-img) SRC_IMG="$(readlink -f "$2")"; shift ;;
    --skip-copy) SKIP_COPY=1 ;;
    --skip-apply) SKIP_APPLY=1 ;;
    --kit) KIT="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

check_inputs() {
  [[ -f "${KOUT}/boot/boot.img" && -f "${KOUT}/boot/vendor_boot.img" ]] \
    || die "no SM8350 kernel at ${KOUT} (external-and-mods/kernel-sm8350/build.sh)"
  [[ -f "${NX669J_STOCK}/vbmeta.img" ]] \
    || die "missing ${NX669J_STOCK}/vbmeta.img (scripts/extract-nx669j-firmware.sh)"
  command -v mkfs.ext4 >/dev/null || die "mkfs.ext4 missing"
  command -v uuidgen >/dev/null || die "uuidgen missing"
}

cleanup_image() {
  sync || true
  sudo_run umount "${MNT}/root" 2>/dev/null || true
  sudo_run umount "${MNT}/home" 2>/dev/null || true
  if [[ -n "${LOOPDEV:-}" ]]; then
    sudo_run losetup -d "${LOOPDEV}" 2>/dev/null || true
    LOOPDEV=""
  fi
}

# Fresh copy of the shared rootfs into ${R}; the source is never modified.
copy_rootfs() {
  [[ "$SKIP_COPY" -eq 1 ]] && { [[ -x "${R}/usr/bin/bash" ]] || die "no rootfs at ${R}"; return 0; }
  mkdir -p "${R}"
  if [[ -n "${SRC_IMG}" ]]; then
    [[ -f "${SRC_IMG}" ]] || die "no image ${SRC_IMG}"
    log "Release image $(basename "${SRC_IMG}")"
    LOOPDEV="$(sudo_run losetup -f --show -r -P "${SRC_IMG}")"
    trap cleanup_image EXIT
    for _ in $(seq 1 50); do [[ -b "${LOOPDEV}p3" ]] && break; sleep 0.1; done
    [[ -b "${LOOPDEV}p2" && -b "${LOOPDEV}p3" ]] \
      || die "${SRC_IMG} is not a Zaviya card image (p2 root, p3 home)"
    mkdir -p "${MNT}/root" "${MNT}/home"
    sudo_run mount -o ro "${LOOPDEV}p2" "${MNT}/root"
    sudo_run mount -o ro "${LOOPDEV}p3" "${MNT}/home"
    [[ -x "${MNT}/root/usr/bin/bash" && -f "${MNT}/root/opt/steamos-sm8650/IMAGE.txt" ]] \
      || die "p2 is not a Zaviya root"
    log "$(tr '\n' ' ' <"${MNT}/root/opt/steamos-sm8650/IMAGE.txt")"
    log "Copying root + home to ${R}"
    sudo_run rsync -aHAX --numeric-ids --delete --info=progress2 "${MNT}/root/" "${R}/"
    sudo_run mkdir -p "${R}/home"
    sudo_run rsync -aHAX --numeric-ids --delete --exclude=/lost+found "${MNT}/home/" "${R}/home/"
    sudo_run mkdir -p "${R}/opt/steamos-sm8650"
    sudo_run cp "${MNT}/root/opt/steamos-sm8650/IMAGE.txt" "${R}/opt/steamos-sm8650/RELEASE-BASE.txt"
    cleanup_image
    trap - EXIT
  else
    [[ -x "${SRC_ROOTFS}/usr/bin/bash" ]] \
      || die "no rootfs at ${SRC_ROOTFS}: run make-steamos-sm8650.sh first, or use --from-img"
    [[ "$(readlink -f "${SRC_ROOTFS}")" != "$(readlink -f "${R}")" ]] \
      || die "the source rootfs and ${R} must differ (apply-overlays-sm8350 changes it)"
    log "Copying ${SRC_ROOTFS} to ${R}"
    sudo_run rsync -aHAX --numeric-ids --delete --info=progress2 \
      --exclude='/.image-mnt' "${SRC_ROOTFS}/" "${R}/"
  fi
}

apply_mods() {
  [[ "$SKIP_APPLY" -eq 1 ]] && { log "Skipping apply-overlays-sm8350"; return 0; }
  log "Applying the REDMAGIC 6 kernel modules, firmware and overlay"
  sudo_run env STEAMOS_WORK="${WORKDIR}" STEAMOS_ROOTFS="${R}" KERNEL_OUT="${KOUT}" \
    "${SCRIPTS}/apply-overlays-sm8350.sh"
}

restore_image_suid() {
  local dest="$1" p
  [[ -d "${dest}/usr/bin" ]] || return 0
  log "Restoring setuid root on pkexec/sudo in the image"
  for p in \
    usr/bin/pkexec usr/sbin/pkexec usr/bin/sudo usr/sbin/sudo \
    usr/lib/polkit-1/polkit-agent-helper-1 \
    usr/bin/su usr/bin/passwd usr/bin/newgrp usr/bin/chsh usr/bin/chfn \
    usr/bin/gpasswd usr/bin/unix_chkpwd usr/bin/mount usr/bin/umount
  do
    [[ -e "${dest}/${p}" ]] || continue
    sudo_run chown root:root "${dest}/${p}"
    sudo_run chmod 4755 "${dest}/${p}"
  done
  if [[ -e "${dest}/usr/lib/dbus-1.0/dbus-daemon-launch-helper" ]]; then
    sudo_run chown root:root "${dest}/usr/lib/dbus-1.0/dbus-daemon-launch-helper"
    sudo_run chmod 4750 "${dest}/usr/lib/dbus-1.0/dbus-daemon-launch-helper"
  fi
}

build_kit() {
  local root_uuid used_mib root_mib raw="${WORKDIR}/.userdata-sm8350.img"
  [[ -x "${R}/usr/bin/bash" ]] || die "rootfs not ready"

  used_mib="$(sudo_run du -sm --exclude=boot --exclude=proc --exclude=sys --exclude=dev \
    --exclude=tmp --exclude=run --exclude='.image-mnt' "${R}" | awk '{print $1}')"
  # Root and home share the partition; 2 GiB of room for first boot, the
  # filesystem then grows to the whole userdata partition.
  root_mib=$((used_mib + 2048 + used_mib / 50 + 128))
  root_uuid="$(uuidgen)"
  log "userdata: ${root_mib} MiB ext4 UUID=${root_uuid} (rootfs ${used_mib} MiB, grows on first boot)"

  rm -f "${raw}"
  truncate -s "${root_mib}M" "${raw}"
  sudo_run mkfs.ext4 -F -L steamos -U "${root_uuid}" -m 1 "${raw}" >/dev/null
  mkdir -p "${MNT}/root"
  LOOPDEV="$(sudo_run losetup -f --show "${raw}")"
  [[ -n "${LOOPDEV}" ]] || die "losetup failed"
  trap cleanup_image EXIT
  sudo_run mount "${LOOPDEV}" "${MNT}/root"

  log "Copying root filesystem (with /home)"
  sudo_run rsync -aHAX --numeric-ids --info=progress2 \
    --exclude='/boot/**' --exclude='/dev/**' --exclude='/proc/**' \
    --exclude='/sys/**' --exclude='/tmp/**' --exclude='/run/**' \
    "${R}/" "${MNT}/root/"
  sudo_run mkdir -p "${MNT}/root/boot" "${MNT}/root/dev" "${MNT}/root/proc" \
    "${MNT}/root/sys" "${MNT}/root/tmp" "${MNT}/root/run"
  if [[ -d "${MNT}/root/home/steamos" ]]; then
    sudo_run chown -R 1000:1000 "${MNT}/root/home/steamos"
  fi
  restore_image_suid "${MNT}/root"
  # Each new installation must generate its own D-Bus/network identity.
  sudo_run truncate -s 0 "${MNT}/root/etc/machine-id"
  if [[ -f "${MNT}/root/var/lib/overlays/etc/upper/machine-id" ]]; then
    sudo_run truncate -s 0 "${MNT}/root/var/lib/overlays/etc/upper/machine-id"
  fi

  # SteamOS mounts /etc from the overlay: write both layers.
  printf '%s\n' \
    "# Zaviya (sm8350, REDMAGIC 6): one ext4 on the UFS userdata partition," \
    "# /home included. No boot partition: the kernel lives in boot_a/boot_b." \
    "UUID=${root_uuid}  /  ext4  defaults,noatime,commit=30,x-systemd.growfs  0 1" \
    | sudo_run tee "${MNT}/root/etc/fstab" >/dev/null
  sudo_run mkdir -p "${MNT}/root/var/lib/overlays/etc/upper"
  sudo_run cp -a "${MNT}/root/etc/fstab" "${MNT}/root/var/lib/overlays/etc/upper/fstab"
  sudo_run mkdir -p "${MNT}/root/opt/steamos-sm8650"
  printf '%s\n' \
    "image=$(basename "${KIT}")" \
    "soc=sm8350" \
    "device=REDMAGIC 6 (NX669J)" \
    "kernel=$(basename "${KOUT}")" \
    "built=$(date -Iseconds)" \
    "root_uuid=${root_uuid}" \
    "root=PARTLABEL=userdata" \
    "layout=ext4 userdata (root + home), kernel in boot_a/boot_b" \
    | sudo_run tee "${MNT}/root/opt/steamos-sm8650/IMAGE.txt" >/dev/null
  sync
  cleanup_image
  trap - EXIT
  sudo_run e2fsck -fy "${raw}" >/dev/null || true
  sudo_run chown "$(id -u):$(id -g)" "${raw}"

  rm -rf "${KIT}"
  mkdir -p "${KIT}"
  cp "${KOUT}/boot/boot.img" "${KOUT}/boot/vendor_boot.img" \
    "${KOUT}/boot/vendor_boot-debug.img" "${KIT}/"
  # Nubia's vbmeta with flags 3 (verity + verification off), what
  # fastboot --disable-verification would write; that option fails on the
  # NX669J's vbmeta_a/vbmeta_b.
  python3 - "${NX669J_STOCK}/vbmeta.img" "${KIT}/vbmeta.img" <<'PY'
import struct, sys
d = bytearray(open(sys.argv[1], "rb").read())
if d[:4] != b"AVB0":
    sys.exit("stock vbmeta.img has no AVB0 header")
struct.pack_into(">I", d, 120, 3)
open(sys.argv[2], "wb").write(d)
PY
  if command -v img2simg >/dev/null; then
    log "Sparse image (img2simg)"
    img2simg "${raw}" "${KIT}/userdata.img"
    rm -f "${raw}"
  else
    log "img2simg missing: raw userdata.img (fastboot sparses it itself)"
    mv "${raw}" "${KIT}/userdata.img"
  fi
  install -m0755 "${MOD}/kernel-sm8350/flash-redmagic6.sh" "${KIT}/flash-redmagic6.sh"
  # CRLF for cmd.exe
  sed -e 's/$/\r/' "${MOD}/kernel-sm8350/flash-redmagic6.bat" >"${KIT}/flash-redmagic6.bat"
  (cd "${KIT}" && sha256sum ./*.img >SHA256SUMS)
  log "Kit ready: ${KIT} (flash with flash-redmagic6.sh / .bat, see docs/redmagic6.md)"
  ls -lh "${KIT}"
}

check_inputs
copy_rootfs
apply_mods
build_kit
