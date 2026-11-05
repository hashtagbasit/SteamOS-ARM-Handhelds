#!/usr/bin/env bash
# Build one handheld release image with the full release settings:
#   sudo STEAMOS_ARM_VERSION=1.5.0 bash scripts/release-images.sh <sm8650|sm8550|sm8250|sm8750>
# REL_DIR holds the rootfs and image; it must be a Linux filesystem.
set -euo pipefail

SOC="${1:?usage: $0 <sm8650|sm8550|sm8250|sm8750>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="${STEAMOS_WORK:-/work}"
REL_DIR="${REL_DIR:-${W}2}"
: "${STEAMOS_ARM_VERSION:?set STEAMOS_ARM_VERSION}"
export STEAMOS_ARM_VERSION
export MESA_STACK="${MESA_STACK:-$W/mesa/out}"
export GAMESCOPE_BUILD="${GAMESCOPE_BUILD:-$W/gamescope-build}"
export NETWORKMANAGER_BUILD="${NETWORKMANAGER_BUILD:-$W/networkmanager-build}"
export MANGOHUD_BUILD="${MANGOHUD_BUILD:-$W/mangohud-build}"
export BOX64_SRC="${BOX64_SRC:-$W/box64}"
export STEAM_ARM_SEED="${STEAM_ARM_SEED:-$W/steam-seed-home/.local/share/Steam}"
export STEAMOS_ROOTFS="$REL_DIR/rootfs-$SOC"
K="$(readlink -f "$W/kernel-$SOC/output/current")"

cd "$ROOT"
case "$SOC" in
  sm8650|sm8250)
    export SOC STEAMOS_SM8650_IMG="$REL_DIR/rel-$SOC.img" IMAGE_KERNEL_OUT="$K" KERNEL_OUT="$K"
    exec ./make-steamos-sm8650.sh ;;
  sm8550)
    # A spare kernel on BOOT, to start the card when the main one doesn't.
    PRE="$W/kernel-prebuilt/7.0.14-edge-sm8550"
    export SOC STEAMOS_SM8650_IMG="$REL_DIR/rel-$SOC.img" IMAGE_KERNEL_OUT="$K" KERNEL_OUT="$PRE $K"
    export TEST_KERNEL_OUT="$PRE" TEST_SM8550_KERNEL=prebuilt TEST_KERNEL_NAME=KERNEL-prebuilt
    exec ./make-steamos-sm8650.sh ;;
  sm8750)
    export STEAMOS_WORK="$W/sm8750-work" STEAMOS_SM8750_IMG="$REL_DIR/rel-$SOC.img"
    export SM8750_KERNEL=source SM8750_KERNEL_WORK="$W/kernel-sm8750" KERNEL_OUT="$K"
    exec ./make-steamos-sm8750.sh ;;
  *) echo "ERROR: unknown chip $SOC" >&2; exit 1 ;;
esac
