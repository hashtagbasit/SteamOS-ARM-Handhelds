#!/usr/bin/env bash
# Build the KDE pieces the Frame rootfs leaves out, inside that rootfs (its
# Qt, KDE Frameworks and Plasma, so they match exactly):
#
#   bluez-qt + bluedevil  Bluetooth in Desktop Mode (tray applet, System
#                         Settings page, pairing wizard, file transfer)
#   kscreen               Display settings: scale, orientation, resolution,
#                         refresh rate, plus the OSD and the kded module
#
# The stock aarch64 repos don't carry them (Frame 0.6 ships libkscreen 6.6.2 but
# not kscreen, bluedevil or bluez-qt), so Desktop Mode had no way to pair a
# Bluetooth device and no display settings page on any device. kscreen is
# built against the Frame's own libkscreen, which is not rebuilt here.
#
# Usage: build-kde-extras-in-rootfs.sh <rootfs> [out-dir]
# Leaves <out-dir>/kde-extras.tar (paths relative to /), which
# install-kde-extras.sh unpacks into an image's rootfs.
set -euo pipefail

# CMake randomly misses a package that is there, about one configure in six.
# Repeat with --fresh: a miss stays in the cache and would fail every retry.
retry_cfg() {
  local i
  "$@" && return 0
  for i in 2 3 4 5 6; do
    echo "configure failed, try $i" >&2
    sleep 5
    "$@" --fresh && return 0
  done
  return 1
}

R="$(cd "${1:?rootfs}" && pwd)"
WORKDIR="${STEAMOS_WORK:-/work}"
OUT="${2:-${WORKDIR}/kde-extras-build}"
SRC="${WORKDIR}/kde-extras-src"

# Frameworks and Plasma releases the Frame 0.6 rootfs ships (its CMake config
# files: KF6CoreAddons, LibKWorkspace, KF6Screen).
KF_VER="${KF_VER:-6.23.0}"
PLASMA_VER="${PLASMA_VER:-6.6.2}"
KDE_MIRROR="${KDE_MIRROR:-https://download.kde.org/stable}"

log() { printf '==> [kde-extras] %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v bwrap >/dev/null || die "bwrap required (apt install bubblewrap)"
[[ -x "$R/usr/bin/cmake" && -x "$R/usr/bin/g++" && -d "$R/usr/share/ECM" ]] \
  || die "rootfs needs cmake, g++ and extra-cmake-modules"

fetch() {  # fetch NAME URL
  local name=$1 url=$2
  [[ -d "$SRC/$name" ]] && return 0
  mkdir -p "$SRC"
  log "fetching $name"
  curl -fsSL --retry 3 -o "$SRC/$name.tar.xz" "$url"
  tar -C "$SRC" -xJf "$SRC/$name.tar.xz"
  rm -f "$SRC/$name.tar.xz"
}

fetch "bluez-qt-${KF_VER}" "${KDE_MIRROR}/frameworks/${KF_VER%.*}/bluez-qt-${KF_VER}.tar.xz"
fetch "bluedevil-${PLASMA_VER}" "${KDE_MIRROR}/plasma/${PLASMA_VER}/bluedevil-${PLASMA_VER}.tar.xz"
fetch "kscreen-${PLASMA_VER}" "${KDE_MIRROR}/plasma/${PLASMA_VER}/kscreen-${PLASMA_VER}.tar.xz"

rm -rf "$OUT"
mkdir -p "$OUT/stage" "$OUT/build"

run() {
  bwrap --bind "$R" / \
    --bind "$SRC" /src \
    --bind "$OUT" /out \
    --dev /dev --proc /proc --tmpfs /run --tmpfs /tmp \
    --unshare-pid --die-with-parent \
    --setenv PATH /usr/bin \
    --setenv CMAKE_PREFIX_PATH /out/stage/usr \
    "$@"
}

build() {  # build SOURCE-DIR [cmake args...]
  local s=$1; shift
  log "building $s"
  # No KDocTools in the rootfs, and the handbooks aren't needed.
  sed -i -e 's/\bDocTools\b//' -e '/add_subdirectory *( *doc/d' -e '/kdoctools_install/d' \
    "$SRC/$s/CMakeLists.txt"
  retry_cfg run cmake -S "/src/$s" -B "/out/build/$s" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBEXECDIR=lib -DBUILD_TESTING=OFF -DBUILD_QCH=OFF "$@"
  run ninja -C "/out/build/$s"
  run env DESTDIR=/out/stage ninja -C "/out/build/$s" install
}

build "bluez-qt-${KF_VER}"
# bluedevil links bluez-qt from the stage, not from the rootfs.
build "bluedevil-${PLASMA_VER}" -DKF6BluezQt_DIR="/out/stage/usr/lib/cmake/KF6BluezQt"
build "kscreen-${PLASMA_VER}"

# Nothing a running system needs from the headers or CMake files.
rm -rf "$OUT/stage/usr/include" "$OUT/stage/usr/lib/cmake" "$OUT/stage/usr/lib/pkgconfig" \
  "$OUT/stage/usr/mkspecs" "$OUT/stage/usr/lib/qt6/mkspecs"
[[ -n "$(find "$OUT/stage" -name 'libKF6BluezQt.so.6*' -print -quit)" ]] || die "no bluez-qt library"
[[ -n "$(find "$OUT/stage" -name 'kcm_bluetooth.so' -print -quit)" ]] || die "no Bluetooth settings page"
[[ -n "$(find "$OUT/stage" -name 'kcm_kscreen.so' -print -quit)" ]] || die "no display settings page"
# The Frame's libkscreen has to stay the only one.
[[ -z "$(find "$OUT/stage" -name 'libKF6Screen*' -print -quit)" ]] || die "stage carries a libkscreen"
if find "$OUT/stage" -type f -name '*.so*' -exec strings {} + | grep -q 'GLIBC_2\.4[4-9]'; then
  die "built against a newer glibc than the Frame"
fi
tar -C "$OUT/stage" --owner=0 --group=0 -cf "$OUT/kde-extras.tar" .
log "OK: $OUT/kde-extras.tar ($(tar -tf "$OUT/kde-extras.tar" | grep -vc '/$') files)"
