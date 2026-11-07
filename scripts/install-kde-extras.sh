#!/usr/bin/env bash
# Bluetooth and display settings for Desktop Mode (bluez-qt, bluedevil,
# libkscreen, kscreen), built inside the Frame rootfs by
# build-kde-extras-in-rootfs.sh. The stock aarch64 repos don't carry them.
#
# Usage: install-kde-extras.sh <rootfs>
# KDE_EXTRAS points at the kde-extras.tar (default: the build's usual place).
# Without one the image is built as before and Desktop Mode lacks both pages.
set -euo pipefail

R="${1:?rootfs}"
T="${KDE_EXTRAS:-/work/kde-extras-build/kde-extras.tar}"

if [[ ! -s "$T" ]]; then
  echo "WARNING: no $T: Desktop Mode gets no Bluetooth or display settings" >&2
  echo "         (scripts/build-kde-extras-in-rootfs.sh builds it)" >&2
  exit 0
fi
tar -C "$R" --no-same-owner -xf "$T"
for f in usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_bluetooth.so \
         usr/lib/qt6/plugins/plasma/kcms/systemsettings/kcm_kscreen.so \
         usr/lib/qt6/plugins/kf6/kded/bluedevil.so usr/lib/qt6/plugins/kf6/kscreen/KSC_KWayland.so; do
  [[ -f "$R/$f" ]] || { echo "ERROR: $f missing after unpacking $T" >&2; exit 1; }
done
echo "kde-extras: Bluetooth and display settings installed"
