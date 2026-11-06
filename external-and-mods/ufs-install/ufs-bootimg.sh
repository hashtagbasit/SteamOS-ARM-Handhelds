#!/usr/bin/env bash
# Shell helpers for ufs-diagnose.sh / ufs-fix-internal-boot.sh, on top of
# ufs-bootimg.py (reads and rebuilds the ABL KERNEL; no mkbootimg needed).
# Source this file; don't run it.

_UFS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_LABEL="$(cat "${_UFS_HERE}/boot-label")"
_ufs_bootimg() { python3 "${_UFS_HERE}/ufs-bootimg.py" "$@"; }

have_bootimg_tools() { command -v python3 >/dev/null; }

read_bootimg_cmdline() {
    _ufs_bootimg info "$1" 2>/dev/null | sed -n 's/^CMDLINE=//p'
}

# KERNEL for the boot partition: the SD KERNEL with root=PARTLABEL=STORAGE.
install_kernel_for_ufs() {
    local src="$1" dst="$2"
    _ufs_bootimg check "$src" >/dev/null || return 1
    _ufs_bootimg retarget "$src" "$dst" --root PARTLABEL=STORAGE >/dev/null
}

verify_ufs_kernel_cmdline() {
    local info
    info="$(_ufs_bootimg info "$1" 2>/dev/null)" || return 1
    grep -q 'root=PARTLABEL=STORAGE' <<<"$info" && grep -q '^ID_OK=yes' <<<"$info"
}
verify_internal_kernel_cmdline() { verify_ufs_kernel_cmdline "$@"; }

describe_kernel_root() {
    local cmdline
    cmdline="$(read_bootimg_cmdline "$1")"
    case " ${cmdline} " in
        *" root=PARTLABEL=STORAGE "*) echo "internal UFS (root=PARTLABEL=STORAGE)" ;;
        *" root=PARTUUID="*) echo "microSD (root=PARTUUID=…), would not boot from internal" ;;
        "  ") echo "unreadable KERNEL" ;;
        *) echo "other: ${cmdline}" ;;
    esac
}

ufs_fstab_text() {
    cat <<EOF
# Zaviya on internal UFS (partitions by GPT name)
PARTLABEL=STORAGE  /      ext4  defaults,noatime                  0 1
PARTLABEL=${BOOT_LABEL}  /boot  vfat  defaults,umask=0077,nofail        0 2
PARTLABEL=HOME     /home  ext4  defaults,noatime,commit=30        0 2
EOF
}

# Both layers: the system mounts /etc as an overlay and the upper copy wins.
write_ufs_fstab_tree() {
    local root="$1"
    mkdir -p "${root}/etc"
    ufs_fstab_text >"${root}/etc/fstab"
    if [[ -d "${root}/var/lib/overlays/etc/upper" ]]; then
        ufs_fstab_text >"${root}/var/lib/overlays/etc/upper/fstab"
    fi
}
