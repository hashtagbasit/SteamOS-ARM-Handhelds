#!/usr/bin/env bash
# ABL cmdline for SteamOS ARM. ABL picks the DTB by model, never put
# devicetree=/dtb= here. root must be PARTUUID (or /dev/…), the initramfs
# does not resolve root=UUID=.
#
# The SoC part (CMDLINE_SOC) comes from external-and-mods/kernel-<soc>/soc.env,
# source that first.
#
# Quiet by default: no kernel text, penguin logo or blinking cursor on the
# panel before Steam (the journal still has everything). CMDLINE_QUIET=0 gives
# the verbose console back (scripts/sd-debug-boot.sh sets it).

build_cmdline() {
  # A bare PARTUUID, or a full spec like PARTLABEL=userdata.
  local root="$1"
  [[ "$root" == *=* ]] || root="PARTUUID=${root}"
  [[ -n "${CMDLINE_SOC:-}" ]] || { echo "build_cmdline: source kernel-<soc>/soc.env first" >&2; return 1; }
  # No clk_ignore_unused / pd_ignore_unused: the base boots without them and
  # they can upset display bring-up.
  local -a parts=(video=efifb:off)
  local -a soc
  read -ra soc <<<"${CMDLINE_SOC}"
  parts+=("${soc[@]}")
  if [[ "${CMDLINE_QUIET:-1}" == 1 ]]; then
    parts+=(quiet loglevel=0 systemd.show_status=0 rd.udev.log_level=0
            logo.nologo vt.global_cursor_default=0)
  else
    parts+=(console=tty0 loglevel=4)
  fi
  parts+=(
    rw rootwait
    "root=${root}"
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
