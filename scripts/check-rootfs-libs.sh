#!/usr/bin/env bash
# Fail when something we install into the rootfs does not load there: a
# library that is missing, a symbol version (glibc, Qt_6.NN) the rootfs does
# not have, or an undefined symbol. Prebuilt parts made for an older Frame
# release (gamescope, mangoapp, KDE apps) fail this way, and only on the
# device. A small fixed list, not a scan of the whole tree: the Frame's own
# packages have optional plugins with missing libraries by design.
#
# Usage: check-rootfs-libs.sh <rootfs> [--no-gear] [--no-extras]
#   always:      gamescope (+ wsi layer), mangoapp, inputplumber, NetworkManager
#                with its plugins
#   --no-extras  skip kscreen, bluedevil and plasma-keyboard
#   --no-gear    skip ark, kcalc, filelight, gwenview, okular and their plugins
# The files are checked with ldd inside the rootfs (bwrap, or chroot as root),
# so the rootfs's own loader and libraries answer.
set -euo pipefail

R="$(cd "${1:?usage: check-rootfs-libs.sh <rootfs> [--no-gear] [--no-extras]}" && pwd)"
shift
GEAR=1 EXTRAS=1
for a in "$@"; do
  case "$a" in
    --no-gear) GEAR=0 ;;
    --no-extras) EXTRAS=0 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Executables (checked with ldd -r: undefined symbols count) and shared
# objects (plain ldd: their daemon or host supplies some symbols).
exes=() libs=() missing=()
need() {  # need exe|lib REQUIRED(1/0) path-in-rootfs...
  local kind=$1 req=$2 p f; shift 2
  for p in "$@"; do
    f="$R/$p"
    if [[ ! -e "$f" ]]; then
      [[ "$req" == 1 ]] && missing+=("/$p")
      continue
    fi
    if [[ "$kind" == exe ]]; then exes+=("/$p"); else libs+=("/$p"); fi
  done
}
glob() {  # glob exe|lib REQUIRED(1/0) pattern-in-rootfs
  local kind=$1 req=$2 pat=$3 f found=0
  for f in "$R"/$pat; do
    [[ -e "$f" ]] || continue
    found=1
    need "$kind" 0 "${f#"$R"/}"
  done
  [[ "$found" == 1 || "$req" == 0 ]] || missing+=("/$pat")
}

need exe 1 usr/bin/gamescope usr/bin/mangoapp usr/bin/inputplumber usr/bin/NetworkManager
need exe 0 usr/local/bin/gamescope usr/bin/gamescopereaper usr/bin/gamescopestream usr/bin/gamescopectl
need lib 1 usr/lib/libVkLayer_FROG_gamescope_wsi_aarch64.so
need lib 0 usr/local/lib/libVkLayer_FROG_gamescope_wsi_aarch64.so
glob lib 1 'usr/lib/NetworkManager/*/libnm-device-plugin-wifi.so'

if [[ "$EXTRAS" == 1 ]]; then
  K=usr/lib/qt6/plugins
  need lib 1 $K/plasma/kcms/systemsettings/kcm_kscreen.so $K/plasma/applets/org.kde.kscreen.so \
    $K/plasma/kcms/systemsettings/kcm_bluetooth.so $K/kf6/kded/bluedevil.so \
    $K/kf6/kscreen/KSC_KWayland.so usr/lib/libKF6BluezQt.so.6
  need exe 1 usr/bin/plasma-keyboard
fi

if [[ "$GEAR" == 1 ]]; then
  K=usr/lib/qt6/plugins
  need exe 1 usr/bin/ark usr/bin/kcalc usr/bin/filelight usr/bin/gwenview usr/bin/okular
  need lib 1 $K/kf6/parts/arkpart.so $K/kf6/parts/okularpart.so $K/kf6/parts/gvpart.so
  glob lib 1 "$K/kerfuffle/kerfuffle_*.so"
  glob lib 1 "$K/okular_generators/okularGenerator_*.so"
fi

if ((${#missing[@]})); then
  printf 'MISSING: %s\n' "${missing[@]}" >&2
  die "rootfs lacks files this image needs"
fi

if command -v bwrap >/dev/null 2>&1; then
  inroot() { bwrap --bind "$R" / --dev /dev --proc /proc --tmpfs /tmp --unshare-pid --die-with-parent \
               --setenv PATH /usr/bin "$@"; }
elif [[ "$EUID" -eq 0 ]]; then
  inroot() { mount -t proc proc "$R/proc" 2>/dev/null || true; chroot "$R" "$@"; }
else
  die "needs bwrap or root (chroot) to run ldd inside $R"
fi

# One call into the rootfs: prints a line per problem.
report="$(inroot /usr/bin/bash -c '
  for f in "$@"; do
    case "$f" in
      EXE) mode=-r; continue ;;
      LIB) mode=; continue ;;
    esac
    out="$(ldd $mode "$f" 2>&1)" || { echo "$f: ldd failed: $(echo "$out" | head -1)"; continue; }
    echo "$out" | grep -E "not found|undefined symbol|version .* not" | sed "s|^[[:space:]]*|$f: |"
  done' _ EXE "${exes[@]}" LIB "${libs[@]}" || true)"

if [[ -n "$report" ]]; then
  printf '%s\n' "$report" >&2
  die "unresolved libraries or symbol versions in $R (see above): rebuild the part against this rootfs"
fi
echo "check-rootfs-libs: ${#exes[@]} executables and ${#libs[@]} libraries resolve in $R"
