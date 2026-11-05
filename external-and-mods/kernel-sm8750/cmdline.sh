#!/usr/bin/env bash
# ABL cmdline for SM8750 SteamOS (AYN Odin 3 / SM8750 devices).
# ABL picks the DTB by model ("AYN Odin 3") — never put devicetree=/dtb= here.
# No initramfs: root must be PARTUUID (or /dev/…), the kernel cannot resolve
# root=UUID= on its own.
#
# Quiet by default: no kernel text, penguin logo or blinking cursor on the
# panel before Steam (the journal still has everything). CMDLINE_QUIET=0 gives
# verbose console back.

build_cmdline() {
  local partuuid="$1" boot_src=LABEL=BOOT disk_src=LABEL=home
  [[ -n "${BOOT_FS_UUID:-}" ]] && boot_src="UUID=${BOOT_FS_UUID}"
  [[ -n "${HOME_FS_UUID:-}" ]] && disk_src="UUID=${HOME_FS_UUID}"
  local -a parts=(
    video=efifb:off
    irqaffinity=0-1
    cgroup.memory=nokmem,nosocket
    nosoftlockup
    mem_sleep_default=s2idle
  )
  if [[ "${CMDLINE_QUIET:-0}" == 1 ]]; then
    parts+=(quiet loglevel=0 systemd.show_status=0 rd.udev.log_level=0
            logo.nologo vt.global_cursor_default=0)
  else
    parts+=(console=tty0 loglevel=4)
  fi
  parts+=(
    # The base's init mounts these before post-flash.sh runs. By UUID when the
    # image build knows them, so another card's or install's BOOT/home can't
    # be picked.
    "boot=${boot_src}"
    "disk=${disk_src}"
    rw rootwait
    "root=PARTUUID=${partuuid}"
    rootfstype=ext4
    errors=remount-ro
  )
  if [[ -n "${KERNEL_CMDLINE_EXTRA:-}" ]]; then
    local -a extra
    read -ra extra <<<"${KERNEL_CMDLINE_EXTRA}"
    parts+=("${extra[@]}")
  fi
  printf '%s' "${parts[*]}"
}
