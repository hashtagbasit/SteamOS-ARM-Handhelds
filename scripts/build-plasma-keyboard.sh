#!/usr/bin/env bash
# Build KDE plasma-keyboard 0.1.0 (Qt6 touch keyboard on Qt VirtualKeyboard,
# Wayland input-method-v1) inside the Frame rootfs via bubblewrap so it
# matches its Qt/glibc. Plasma had no touch keyboard: only Steam's (Steam+X),
# which needs the Steam Deck controller layout. KWin shows this one when a
# text field is tapped once it's the Wayland virtual keyboard (kwinrc).
# Later releases need KF6 >= 6.22; the Frame has 6.14. Maliit is Qt5-only.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
R="$(cd "${1:-${ROOT}/rootfs}" && pwd)"
VER=v0.1.0
TOP=/tmp/plasma-keyboard
SRC="$TOP/plasma-keyboard-$VER"
BUILD="$TOP/build"

command -v bwrap >/dev/null 2>&1 || { echo "ERROR: bwrap required" >&2; exit 1; }
mkdir -p "$TOP"
if [[ ! -f "$SRC/CMakeLists.txt" ]]; then
  curl -fsSL --max-time 120 -o "$TOP/src.tar.gz" \
    "https://invent.kde.org/plasma/plasma-keyboard/-/archive/${VER}/plasma-keyboard-${VER}.tar.gz"
  tar -xzf "$TOP/src.tar.gz" -C "$TOP"
fi

# The 8 Elite rootfs has no extra-cmake-modules (the 8 Gen 3 one does).
if [[ ! -f "$R/usr/share/ECM/cmake/ECMConfig.cmake" ]]; then
  echo "==> installing extra-cmake-modules into rootfs"
  ECM_REPO=http://mirror.archlinuxarm.org/aarch64/extra
  curl -fsSL --max-time 60 -o "$TOP/extra.db" "$ECM_REPO/extra.db"
  ECM_FILE="$(tar -xOf "$TOP/extra.db" --wildcards 'extra-cmake-modules-*/desc' \
    | grep -m1 '^extra-cmake-modules-.*\.pkg\.tar')"
  ECM_PKG="$TOP/$ECM_FILE"
  [[ -f "$ECM_PKG" ]] || curl -fsSL --max-time 60 -o "$ECM_PKG" "$ECM_REPO/$ECM_FILE"
  tmp="$(mktemp -d)"
  tar -C "$tmp" -xf "$ECM_PKG"
  mkdir -p "$R/usr/share"
  cp -a "$tmp/usr/share/ECM" "$R/usr/share/"
  rm -rf "$tmp"
  [[ -f "$R/usr/share/ECM/cmake/ECMConfig.cmake" ]] || { echo "ERROR: ECM still missing" >&2; exit 1; }
fi

run_in_rootfs() {
  bwrap --bind "$R" / --bind /tmp /tmp --dev /dev --proc /proc --tmpfs /run \
    --unshare-pid --die-with-parent --chdir /tmp "$@"
}
rm -rf "$BUILD"
retry_cfg run_in_rootfs /usr/bin/cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_TESTING=OFF
run_in_rootfs /usr/bin/cmake --build "$BUILD" -j"$(nproc)"
run_in_rootfs /usr/bin/cmake --install "$BUILD"
ls "$R"/usr/share/applications/*keyboard*.desktop >/dev/null
echo "OK: installed plasma-keyboard ${VER} into $R"
