#!/usr/bin/env bash
# Kernel for Zaviya on the REDMAGIC 6 (SM8350):
#   bash external-and-mods/kernel-sm8350/build.sh [--repack-boot]
#
# Mainline ${KVER} + patches/ (NX669J DTS, panel, fan, triggers, GT9897) on
# the arm64 defconfig, plus ../kernel-common/steamos.config and ./steamos.config.
# Builds natively on aarch64 or cross-compiles elsewhere
# (CROSS_COMPILE, default aarch64-linux-gnu-).
#
# Needs the phone's firmware from scripts/extract-nx669j-firmware.sh
# (NX669J_FW, default ${STEAMOS_WORK:-/work}/nx669j-firmware).
#
# Output: output/<release>/
#   boot/boot.img               header v3, the kernel (stock ABL layout)
#   boot/vendor_boot.img        header v3: DTB + initramfs + cmdline
#   boot/vendor_boot-debug.img  same, verbose, USB debug shell (soc.env CMDLINE_DEBUG)
#   modules/<release>, firmware/, dtbs/, config-<release>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="${HERE}/../kernel-common"
# shellcheck source=soc.env
source "${HERE}/soc.env"

LOCALVERSION="${LOCALVERSION:--${SOC}-steamos}"
WORK="${WORK:-${STEAMOS_WORK:-/work}/kernel-${SOC}}"
CACHE="${WORK}/cache"
SRC="${WORK}/linux-${KVER}"
OUT_BASE="${OUT_BASE:-${WORK}/output}"
NX669J_FW="${NX669J_FW:-${STEAMOS_WORK:-/work}/nx669j-firmware}"
JOBS="${JOBS:-$(nproc)}"

export ARCH=arm64
if [[ "$(uname -m)" != aarch64 ]]; then
  export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
fi

log() { printf '[kernel-%s] %s\n' "$SOC" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

check_deps() {
  local missing=() c
  for c in make bc bison flex python3 curl tar xz gzip cpio patch perl rsync ar depmod; do
    command -v "$c" >/dev/null || missing+=("$c")
  done
  command -v "${CROSS_COMPILE:-}gcc" >/dev/null || missing+=("${CROSS_COMPILE:-}gcc")
  ((${#missing[@]})) && die "missing: ${missing[*]}"
  [[ -f "${NX669J_FW}/SHA256SUMS" ]] \
    || die "no firmware in ${NX669J_FW}: run scripts/extract-nx669j-firmware.sh NX669J-update.zip first"
}

fetch() {
  local url="$1" dest="$2"
  [[ -s "$dest" ]] && return 0
  mkdir -p "$(dirname "$dest")"
  log "download ${url}"
  curl -fL --retry 3 -o "${dest}.part" "$url"
  mv -f "${dest}.part" "$dest"
}

prepare_source() {
  local tarball="${CACHE}/linux-${KVER}.tar.xz" digest
  fetch "https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-${KVER}.tar.xz" "$tarball"
  digest="$(cat "${HERE}"/patches/*.patch | sha256sum | cut -d' ' -f1)"
  if [[ -f "${SRC}/.${SOC}-patched" && "$(cat "${SRC}/.${SOC}-patched")" == "$digest" ]]; then
    log "source already patched: ${SRC}"
    return 0
  fi
  rm -rf "$SRC"
  mkdir -p "$WORK"
  log "extract linux-${KVER}"
  tar -C "$WORK" -xf "$tarball"
  local p
  for p in "${HERE}"/patches/*.patch; do
    log "patch $(basename "$p")"
    patch -d "$SRC" -p1 -N --no-backup-if-mismatch -s <"$p" || die "patch failed: $p"
  done
  echo "$digest" >"${SRC}/.${SOC}-patched"
}

configure() {
  make -C "$SRC" defconfig >/dev/null
  local sc="${SRC}/scripts/config --file ${SRC}/.config"
  $sc --set-str LOCALVERSION "$LOCALVERSION"
  $sc --disable LOCALVERSION_AUTO
  $sc --set-str INITRAMFS_SOURCE ""
  local frag="${WORK}/steamos.config.merged" line opt val
  cat "${COMMON}/steamos.config" "${HERE}/steamos.config" >"$frag"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    opt="${line%%=*}"; val="${line#*=}"; opt="${opt#CONFIG_}"
    case "$val" in
      y) $sc --enable "$opt" ;;
      m) $sc --module "$opt" ;;
      n) $sc --disable "$opt" ;;
      \"*) $sc --set-str "$opt" "$(eval echo "$val")" ;;
      *) $sc --set-val "$opt" "$val" ;;
    esac
  done <"$frag"
  make -C "$SRC" olddefconfig >/dev/null
  local bad=0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    opt="${line%%=*}"; val="${line#*=}"
    if [[ "$val" == n ]]; then
      grep -q "^${opt}=" "${SRC}/.config" && { log "WARN ${opt} still set"; bad=1; }
    elif ! grep -qx "${opt}=${val}" "${SRC}/.config"; then
      log "WARN ${opt}=${val} not applied (got: $(grep -E "^(# )?${opt}[= ]" "${SRC}/.config" || echo unset))"; bad=1
    fi
  done <"$frag"
  ((bad)) && log "some fragment options did not stick (see WARN lines)"
  return 0
}

build_kernel() {
  log "make -j${JOBS} Image modules dtbs"
  make -C "$SRC" -j"$JOBS" Image modules qcom/${DTB}.dtb
  KREL="$(make -s -C "$SRC" kernelrelease)"
  log "kernel release ${KREL}"
}

build_initramfs() {
  local deb="${CACHE}/${BUSYBOX_DEB}" d="${WORK}/initramfs"
  fetch "https://deb.debian.org/debian/pool/main/b/busybox/${BUSYBOX_DEB}" "$deb"
  echo "${BUSYBOX_DEB_SHA256}  ${deb}" | sha256sum -c --quiet || die "busybox .deb checksum mismatch"
  rm -rf "$d"; mkdir -p "$d/deb" "$d/root/bin" "$d/root/dev" "$d/root/proc" "$d/root/sys"
  (cd "$d/deb" && ar x "$deb" && tar -xf data.tar.* ./usr/bin/busybox)
  install -m0755 "$d/deb/usr/bin/busybox" "$d/root/bin/busybox"
  install -m0755 "${COMMON}/initramfs/init" "$d/root/init"
  install -m0755 "${COMMON}/initramfs/konkr-update-recover" "$d/root/konkr-update-recover"
  install -m0755 "${COMMON}/initramfs/bootdebug" "$d/root/bootdebug"
  (cd "$d/root" && find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 --reproducible 2>/dev/null) \
    | gzip -9 -n >"$d/initrd.gz"
  INITRD="$d/initrd.gz"
}

# Nubia's ABL only starts the stock layout: header v3 boot (kernel) +
# vendor_boot (DTB, ramdisk, cmdline). boot.img is the same for both
# cmdlines; the debug variant is just another vendor_boot.
pack_boot() {
  local dir="$1" vb="$2" extra="$3" cmdline img="${SRC}/arch/arm64/boot/Image"
  cmdline="$(bash -c "source '${HERE}/soc.env'; KERNEL_CMDLINE_EXTRA='${KERNEL_CMDLINE_EXTRA} ${extra}'; \
    CMDLINE_QUIET=$([[ -n "$extra" ]] && echo 0 || echo 1); source '${COMMON}/cmdline.sh'; build_cmdline '${ROOT_SPEC}'")"
  gzip -9 -n -c "$img" >"${WORK}/Image.gz"
  python3 "${HERE}/mkbootimg-v3.py" --kernel "${WORK}/Image.gz" --ramdisk "$INITRD" \
    --dtb "${SRC}/arch/arm64/boot/dts/qcom/${DTB}.dtb" --cmdline "$cmdline" \
    --board-ids "${BOARD_IDS}" --boot "${dir}/boot.img" --vendor-boot "${dir}/${vb}"
  log "${vb}: ${cmdline}"
}

pack_all() {
  local dir="$1"
  pack_boot "$dir" vendor_boot.img ""
  pack_boot "$dir" vendor_boot-debug.img "${CMDLINE_DEBUG}"
  (cd "$dir" && sha256sum boot.img vendor_boot.img vendor_boot-debug.img >SHA256SUMS)
}

install_output() {
  local o="${OUT_BASE}/${KREL}"
  rm -rf "$o"
  mkdir -p "$o/boot" "$o/modules" "$o/firmware" "$o/dtbs"
  log "modules_install"
  make -C "$SRC" INSTALL_MOD_PATH="$o/staging" INSTALL_MOD_STRIP=1 modules_install >/dev/null
  depmod -b "$o/staging" "$KREL"
  mv "$o/staging/lib/modules/${KREL}" "$o/modules/${KREL}"
  rm -rf "$o/staging" "$o/modules/${KREL}/build" "$o/modules/${KREL}/source"

  log "firmware from ${NX669J_FW}"
  rsync -a --exclude SHA256SUMS "${NX669J_FW}/" "$o/firmware/"

  cp "${SRC}/arch/arm64/boot/dts/qcom/${DTB}.dtb" "$o/dtbs/"
  cp "${SRC}/.config" "$o/config-${KREL}"
  cp "${SRC}/System.map" "$o/System.map-${KREL}"
  pack_all "$o/boot"
  ln -sfn "$KREL" "${OUT_BASE}/current"
  log "done: $o"
  ls -la "$o/boot" >&2
}

main() {
  if [[ "${1:-}" == --repack-boot ]]; then
    [[ -s "$SRC/arch/arm64/boot/Image" ]] || die "no previously built kernel Image"
    KREL="$(make -s -C "$SRC" kernelrelease)"
    [[ -d "$OUT_BASE/$KREL" ]] || die "no previously built kernel output"
    mkdir -p "$CACHE"
    build_initramfs
    rm -f "$OUT_BASE/$KREL/boot/boot-debug.img"
    pack_all "$OUT_BASE/$KREL/boot"
    return
  fi
  check_deps
  mkdir -p "$CACHE"
  prepare_source
  configure
  build_kernel
  build_initramfs
  install_output
}

main "$@"
