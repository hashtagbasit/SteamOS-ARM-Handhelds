#!/usr/bin/env bash
# Install Plasma work extras into a SteamOS Frame rootfs.
#
# Frame 0.6 extra.db carries Plasma 6.6.2, KF 6.23.0 and Qt 6.10.2, including
# plasma-nm, networkmanager-qt and modemmanager-qt. It has no kscreen or
# bluedevil (scripts/build-kde-extras-in-rootfs.sh) and no ark, kcalc,
# gwenview, okular or filelight (scripts/build-kde-gear-26.04.2.sh).
# kate comes from deckard-arch-hotfixes (built for this KF6).
# Arch Linux ARM extra is only a source for small tools. Its KDE and Plasma
# packages are built for a newer Qt than the Frame has, so a package whose
# binaries need a Qt version newer than the rootfs's is refused.
#
# Usage: install-plasma-extras.sh [rootfs]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
R="${1:-${ROOT}/rootfs}"
R="$(cd "$R" && pwd)"
DB="$R/usr/lib/holo/pacmandb"
CONF="$R/etc/pacman.conf"

log() { echo "== plasma-extras: $*"; }
warn() { echo "WARN plasma-extras: $*" >&2; }

[[ -d "$R/usr" && -f "$CONF" ]] || { echo "ERROR: bad rootfs $R" >&2; exit 1; }
mkdir -p "$DB/local"

already_installed() {
  local name="$1"
  case "$name" in
    nm-connection-editor)
      [[ -x "$R/usr/bin/nm-connection-editor" ]] && return 0
      return 1
      ;;
    libnma)
      [[ -e "$R/usr/lib/libnma.so" || -e "$R/usr/lib/libnma.so.0" ]] && return 0
      return 1
      ;;
    unarchiver)
      [[ -x "$R/usr/bin/unar" ]] && return 0
      return 1
      ;;
    extra-cmake-modules)
      [[ -f "$R/usr/share/ECM/cmake/ECMConfig.cmake" ]] && return 0
      return 1
      ;;
    kate)
      [[ -x "$R/usr/bin/$name" ]] && return 0
      return 1
      ;;
  esac
  compgen -G "$DB/local/${name}-[0-9]*" >/dev/null 2>&1 \
    || [[ -x "$R/usr/bin/$name" ]]
}

repo_url() {
  local section="$1"
  awk -v sec="[$section]" '
    $0 == sec { insec=1; next }
    /^\[/ { insec=0 }
    insec && $1 == "Server" {
      sub(/^Server[[:space:]]*=[[:space:]]*/, "")
      print
      exit
    }
  ' "$CONF"
}

WORKDIR="$(mktemp -d /tmp/holo-plasma-extras.XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

download_db() {
  local url="$1" dest="$2"
  curl -k -fsSL --max-time 40 "$url" -o "$dest"
}

# name -> "url filename"
declare -A PKG_URL PKG_FILE

index_db() {
  local dbfile="$1" baseurl="$2"
  python3 - "$dbfile" "$baseurl" "$WORKDIR/index.pyout" <<'PY'
import sys, tarfile
db, base, out = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3]
rows = []
with tarfile.open(db, "r:*") as tf:
    for m in tf.getmembers():
        n = m.name.replace("\\", "/").lstrip("./")
        if not n.endswith("/desc"):
            continue
        pkgdir = n.rsplit("/", 1)[0].split("/")[-1]
        if "debug" in pkgdir:
            continue
        text = tf.extractfile(m).read().decode("utf-8", "replace")
        name = fn = ""
        lines = text.splitlines()
        for i, line in enumerate(lines):
            if line.strip() == "%NAME%" and i + 1 < len(lines):
                name = lines[i + 1].strip()
            if line.strip() == "%FILENAME%" and i + 1 < len(lines):
                fn = lines[i + 1].strip()
        if name and fn:
            rows.append(f"{name}\t{base}/{fn}\t{fn}")
with open(out, "w", encoding="utf-8") as fh:
    fh.write("\n".join(rows) + "\n")
PY
  while IFS=$'\t' read -r name url file; do
    [[ -n "$name" ]] || continue
    # First repo wins (SteamOS extra/hotfixes before ALARM).
    [[ -n "${PKG_URL[$name]:-}" ]] && continue
    PKG_URL["$name"]="$url"
    PKG_FILE["$name"]="$file"
  done <"$WORKDIR/index.pyout"
}

log "index repos"
extra_server="$(repo_url extra)"
extra_server="${extra_server//\$repo/extra}"
extra_server="${extra_server//\$arch/aarch64}"
if download_db "${extra_server}/extra.db" "$WORKDIR/extra.db"; then
  index_db "$WORKDIR/extra.db" "$extra_server"
fi

hf_server="$(repo_url deckard-arch-hotfixes)"
if [[ -n "$hf_server" ]] && download_db "${hf_server}/deckard-arch-hotfixes.db" "$WORKDIR/hf.db"; then
  index_db "$WORKDIR/hf.db" "$hf_server"
fi

# Arch Linux ARM: small tools only, see the header.
if download_db "http://mirror.archlinuxarm.org/aarch64/extra/extra.db" "$WORKDIR/alarm.db"; then
  index_db "$WORKDIR/alarm.db" "http://mirror.archlinuxarm.org/aarch64/extra"
fi

# Prefer SteamOS-built kate. Gear apps are built, not installed.
WANT_STEAMOS=(kate extra-cmake-modules)
WANT_OPTIONAL=(p7zip 7zip unrar unzip zip kdialog unarchiver lrzip yyjson fastfetch)

# Newest Qt 6 version symbol (Qt_6.NN) the libQt6Core of the rootfs defines,
# and the newest one the files under a directory ask for.
qt_have="$(strings "$R/usr/lib/libQt6Core.so.6" 2>/dev/null | grep -oE '^Qt_6\.[0-9]+$' | sort -V | tail -1 || true)"
qt_need() {
  find "$1" -type f \( -name '*.so*' -o -perm -111 \) -print0 2>/dev/null \
    | xargs -0 -r strings 2>/dev/null | { grep -oE '^Qt_6\.[0-9]+$' || true; } | sort -V | tail -1
}

install_pkg() {
  local name="$1"
  local url="${PKG_URL[$name]:-}"
  local file="${PKG_FILE[$name]:-}"
  if [[ -z "$url" || -z "$file" ]]; then
    warn "not found: $name"
    return 1
  fi
  # Refuse Plasma 6.7 applets if they came from ALARM.
  case "$name" in
    kscreen|plasma-nm|bluedevil|spectacle|plasma-pa|plasma-desktop|plasma-workspace)
      if [[ "$url" == *archlinuxarm* ]]; then
        warn "skip $name (newer Plasma than the Frame's 6.6.2)"
        return 1
      fi
      ;;
  esac
  log "get $name ($file)"
  if ! curl -k -fsSL --max-time 120 "$url" -o "$WORKDIR/$file"; then
    warn "download failed: $name"
    return 1
  fi
  local dest="$WORKDIR/extract"
  rm -rf "$dest"
  mkdir -p "$dest"
  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -C "$dest" -xf "$WORKDIR/$file"
  else
    tar -C "$dest" -xf "$WORKDIR/$file"
  fi
  # Refuse a package built for a newer Qt than the rootfs has.
  local need; need="$(qt_need "$dest")"
  if [[ -n "$need" && "$(printf '%s\n%s\n' "${qt_have:-Qt_6.0}" "$need" | sort -V | tail -1)" != "${qt_have:-Qt_6.0}" ]]; then
    warn "skip $name ($file needs $need; the rootfs has ${qt_have:-no Qt})"
    return 1
  fi
  for d in usr etc opt; do
    [[ -d "$dest/$d" ]] || continue
    mkdir -p "$R/$d"
    cp -a "$dest/$d/." "$R/$d/"
  done
  if [[ -f "$dest/.PKGINFO" ]]; then
    local pkgver
    pkgver="$(awk -F' = ' '/^pkgname /{n=$2} /^pkgver /{v=$2} END{print n"-"v}' "$dest/.PKGINFO")"
    if [[ -n "$pkgver" ]]; then
      mkdir -p "$DB/local/${pkgver}"
      {
        echo "%NAME%"
        awk -F' = ' '/^pkgname /{print $2}' "$dest/.PKGINFO"
        echo
        echo "%VERSION%"
        awk -F' = ' '/^pkgver /{print $2}' "$dest/.PKGINFO"
        echo
      } >"$DB/local/${pkgver}/desc"
    fi
  fi
  return 0
}

ok=0
fail=0
for name in "${WANT_STEAMOS[@]}" "${WANT_OPTIONAL[@]}"; do
  if already_installed "$name"; then
    log "have $name"
    continue
  fi
  if install_pkg "$name"; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
  fi
done

log "installed $ok new packages, $fail missing"
exit 0
