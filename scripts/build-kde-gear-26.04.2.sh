#!/usr/bin/env bash
# Build one KDE Gear 26.04.2 app against the Frame's Qt 6.10 / KF 6.23 (not
# Arch Linux ARM's Gear 26.08, which needs Qt 6.12).
# Usage: build-kde-gear-26.04.2.sh <rootfs> <ark|kcalc|filelight|gwenview|okular>
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

R="${1:-}"
NAME="${2:-}"
[[ -n "$R" && -d "$R/usr" && -n "$NAME" ]] || {
  echo "Usage: $0 <rootfs> <ark|kcalc|filelight|gwenview|okular>" >&2
  exit 1
}
R="$(cd "$R" && pwd)"
# 26.04.2 wants Poppler >= 24.08; Frame 0.6 has 26.02.0.
VER="26.04.2"
SRC_TGZ="/tmp/kde-gear-src/${NAME}-${VER}.tar.xz"
SRC_DIR="/tmp/kde-gear-src/${NAME}-${VER}"
BUILD="/tmp/kde-gear-build/${NAME}-${VER}"

mkdir -p /tmp/kde-gear-src /tmp/kde-gear-build
if [[ ! -f "$SRC_DIR/CMakeLists.txt" ]]; then
  if [[ ! -f "$SRC_TGZ" ]]; then
    curl -fsSL --max-time 180 -o "$SRC_TGZ" \
      "https://download.kde.org/stable/release-service/${VER}/src/${NAME}-${VER}.tar.xz"
  fi
  tar -xJf "$SRC_TGZ" -C /tmp/kde-gear-src
fi
command -v bwrap >/dev/null 2>&1 || { echo "ERROR: bwrap required" >&2; exit 1; }

# Frame 0.6 ships ECM 6.23.0; Gear 26.04 needs >= 6.5 (cmake-only, build time).
ecm_version() {
  sed -n 's/^set(PACKAGE_VERSION "\([0-9.]*\)").*/\1/p' \
    "$R/usr/share/ECM/cmake/ECMConfigVersion.cmake" 2>/dev/null | head -1
}
ecm_too_old() {
  local v; v="$(ecm_version)"
  [[ -z "$v" ]] && return 0
  [[ "$(printf '%s\n6.5.0\n' "$v" | sort -V | head -1)" != "6.5.0" ]]
}
if [[ ! -f "$R/usr/share/ECM/cmake/ECMConfig.cmake" ]] || ecm_too_old; then
  rm -rf "$R/usr/share/ECM"
  echo "ERROR: extra-cmake-modules missing in rootfs" >&2
  exit 1
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"

run() {
  bwrap --bind "$R" / \
    --bind /tmp /tmp --dev /dev --proc /proc --tmpfs /run \
    --unshare-pid --die-with-parent --chdir /tmp \
    "$@"
}

# Okular needs KF6 ThreadWeaver (not in the stripped Frame extra).
if [[ "$NAME" == okular && ! -f "$R/usr/lib/cmake/KF6ThreadWeaver/KF6ThreadWeaverConfig.cmake" ]]; then
  TW_VER="6.23.0"
  TW_SRC="/tmp/kf6-src/threadweaver-${TW_VER}"
  TW_BUILD="/tmp/kf6-build/threadweaver-${TW_VER}"
  mkdir -p /tmp/kf6-src /tmp/kf6-build
  if [[ ! -f "$TW_SRC/CMakeLists.txt" ]]; then
    curl -fsSL --max-time 120 -o "/tmp/kf6-src/threadweaver-${TW_VER}.tar.xz" \
      "https://download.kde.org/stable/frameworks/6.23/threadweaver-${TW_VER}.tar.xz"
    tar -xJf "/tmp/kf6-src/threadweaver-${TW_VER}.tar.xz" -C /tmp/kf6-src
  fi
  rm -rf "$TW_BUILD"
  mkdir -p "$TW_BUILD"
  echo "==> cmake threadweaver ${TW_VER} (okular dep)"
  retry_cfg run /usr/bin/cmake -S "$TW_SRC" -B "$TW_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_TESTING=OFF
  run /usr/bin/cmake --build "$TW_BUILD" -j"$(nproc)"
  run /usr/bin/cmake --install "$TW_BUILD"
fi

CMAKE_EXTRA=()
# Annotation tools need kImageAnnotator (not on Frame). Viewer still works.
[[ "$NAME" == gwenview ]] && CMAKE_EXTRA+=(-DGWENVIEW_IMAGEANNOTATOR=OFF)
# Docs, PS, DjVu, Mobipocket and audio/video (Phonon) are optional; PDF stays required.
[[ "$NAME" == okular ]] && CMAKE_EXTRA+=(
  -DFORCE_NOT_REQUIRED_DEPENDENCIES="KF6DocTools;LibSpectre;DjVuLibre;QMobipocket6;Phonon4Qt6"
)

echo "==> cmake ${NAME} ${VER}"
retry_cfg run /usr/bin/cmake -S "$SRC_DIR" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_TESTING=OFF \
  -DBUILD_DOC=OFF \
  "${CMAKE_EXTRA[@]}"
run /usr/bin/cmake --build "$BUILD" -j"$(nproc)"
# Remove incompatible ALARM leftovers that this build does not produce.
case "$NAME" in
  ark) rm -f "$R/usr/lib/libkerfuffle.so.26.08.1" ;;
  gwenview)
    rm -f "$R/usr/bin/gwenview_importer" "$R/usr/share/applications/org.kde.gwenview_importer.desktop" \
      "$R/usr/share/solid/actions/gwenview_importer.desktop" "$R/usr/share/solid/actions/gwenview_importer_camera.desktop"
    ;;
  okular)
    rm -rf "$R/usr/lib/qt6/plugins/okular_generators"
    rm -f "$R/usr/lib/libOkular6Core.so.4" "$R/usr/lib/libOkular6Core.so.4.0.0"
    ;;
esac
run /usr/bin/cmake --install "$BUILD"
# Qt's own version symbols: the newest one libQt6Core exports, and the newest
# the app asks for.
qt_have="$(strings "$R/usr/lib/libQt6Core.so.6" | grep -oE '^Qt_6\.[0-9]+$' | sort -V | tail -1)"
qt_need="$(strings "$R/usr/bin/${NAME}" | grep -oE '^Qt_6\.[0-9]+$' | sort -V | tail -1)"
if [[ -n "$qt_need" && "$(printf '%s\n%s\n' "$qt_have" "$qt_need" | sort -V | tail -1)" != "$qt_have" ]]; then
  echo "ERROR: ${NAME} needs ${qt_need}, the rootfs Qt has ${qt_have}" >&2
  exit 1
fi
echo "OK: ${NAME} ${VER} installed into $R"
