#!/usr/bin/env bash
# Stage the SM8750 kernel, modules, firmware and ABL bootloader from the official
# base SM8750 release (Linux 7.2.0).
#
# Target output structure matches KERNEL_OUT expected by make-steamos-sm8750.sh:
#   <output>/
#     boot/KERNEL
#     boot/KERNEL.md5
#     modules/7.2.0/
#     firmware/
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
WORKDIR="${STEAMOS_WORK:-${ROOT}/sm8750-work}"
OUT_DIR="${1:-${WORKDIR}/kernel-sm8750-release/7.2.0}"
ROCKNIX_VERSION="${ROCKNIX_VERSION:-20260901}"
TAR_NAME="ROCKNIX-SM8750.aarch64-${ROCKNIX_VERSION}.tar"
TAR_URL="https://github.com/ROCKNIX/distribution/releases/download/${ROCKNIX_VERSION}/${TAR_NAME}"
TAR_FILE="${WORKDIR}/${TAR_NAME}"

log() { printf '[kernel-sm8750] %s\n' "$*"; }
die() { printf 'ERROR: [kernel-sm8750] %s\n' "$*" >&2; exit 1; }

mkdir -p "${WORKDIR}" "${OUT_DIR}/boot" "${OUT_DIR}/modules" "${OUT_DIR}/firmware"

if [[ -f "${OUT_DIR}/boot/KERNEL" && -d "${OUT_DIR}/modules/7.2.0" && -d "${OUT_DIR}/firmware/qcom" ]]; then
  log "SM8750 kernel release already staged in ${OUT_DIR}"
  exit 0
fi

if [[ ! -f "${TAR_FILE}" ]]; then
  log "Downloading ${TAR_URL}"
  curl -fL -o "${TAR_FILE}" "${TAR_URL}"
fi

STAGE_DIR="${WORKDIR}/.rocknix-stage"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"

log "Extracting KERNEL and SYSTEM from ${TAR_NAME}"
tar -xf "${TAR_FILE}" -C "${STAGE_DIR}"

KSRC="${STAGE_DIR}/ROCKNIX-SM8750.aarch64-${ROCKNIX_VERSION}/target/KERNEL"
KMD5="${STAGE_DIR}/ROCKNIX-SM8750.aarch64-${ROCKNIX_VERSION}/target/KERNEL.md5"
SYSTEM="${STAGE_DIR}/ROCKNIX-SM8750.aarch64-${ROCKNIX_VERSION}/target/SYSTEM"

[[ -f "${KSRC}" ]] || die "missing KERNEL in ${TAR_NAME}"
[[ -f "${SYSTEM}" ]] || die "missing SYSTEM squashfs in ${TAR_NAME}"

log "Copying KERNEL and KERNEL.md5"
cp -a "${KSRC}" "${OUT_DIR}/boot/KERNEL"
cp -a "${KMD5}" "${OUT_DIR}/boot/KERNEL.md5"

log "Extracting modules to ${OUT_DIR}/modules/7.2.0"
rm -rf "${OUT_DIR}/modules/7.2.0"
unsquashfs -f -d "${WORKDIR}/.unsquash-tmp" "${SYSTEM}" "usr/lib/kernel-overlays/base/lib/modules/7.2.0"
mv "${WORKDIR}/.unsquash-tmp/usr/lib/kernel-overlays/base/lib/modules/7.2.0" "${OUT_DIR}/modules/"
rm -rf "${WORKDIR}/.unsquash-tmp"

log "Extracting firmware to ${OUT_DIR}/firmware"
rm -rf "${OUT_DIR}/firmware"
unsquashfs -f -d "${WORKDIR}/.unsquash-tmp" "${SYSTEM}" "usr/lib/kernel-overlays/base/lib/firmware"
mv "${WORKDIR}/.unsquash-tmp/usr/lib/kernel-overlays/base/lib/firmware" "${OUT_DIR}/"
rm -rf "${WORKDIR}/.unsquash-tmp"

ABL_SRC="${STAGE_DIR}/ROCKNIX-SM8750.aarch64-${ROCKNIX_VERSION}/3rdparty/bootloader/rocknix_abl"
if [[ -d "${ABL_SRC}" ]]; then
  log "Extracting rocknix_abl bootloader files to ${WORKDIR}/rocknix_abl"
  rm -rf "${WORKDIR}/rocknix_abl"
  cp -a "${ABL_SRC}" "${WORKDIR}/rocknix_abl"
fi

rm -rf "${STAGE_DIR}"
log "SM8750 kernel, modules, and firmware successfully staged in ${OUT_DIR}"
