#!/usr/bin/env bash
# Read-only check that a kernel tree's patch series still applies to its base.
#
#   kernel-patch-check.sh plan    choose the kernel trees to check from the diff
#   kernel-patch-check.sh check <name>
#                                 apply the full series of external-and-mods/kernel-<name>
#
# `check` follows external-and-mods/kernel-common/build.sh (prepare_source):
# the same source archive, the same patch directories in the same order, the
# same skip list and the same `patch` invocation. It never builds anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODS="$ROOT/external-and-mods"
# Where the base distribution's patch directories are cloned from.
BASE_REPO_URL="${BASE_REPO_URL:-https://github.com/ROCKNIX/distribution.git}"

# Port directories a kernel recipe applies, as build.sh resolves them.
port_dirs_of() {
  local name="$1"
  (
    set -euo pipefail
    # shellcheck disable=SC1090
    source "$MODS/kernel-$name/soc.env"
    echo "${PORT_DIRS:-kernel-$name}"
  )
}

plan() {
  local base="${BASE:-}" head="${HEAD:-}" changed="" all=0
  if [[ "$base" =~ ^[0-9a-f]{40}$ && ! "$base" =~ ^0+$ && "$head" =~ ^[0-9a-f]{40}$ ]] \
    && git -C "$ROOT" cat-file -e "$base" 2>/dev/null; then
    changed="$(git -C "$ROOT" diff --name-only "$base" "$head")"
  else
    all=1
  fi
  # A change to the check itself re-tests every recipe.
  if grep -qE '^\.github/(workflows/kernel-patches\.yml|scripts/kernel-patch-check\.sh)$' <<<"$changed"; then
    all=1
  fi

  local dirs="" d
  if ((all)); then
    for d in "$MODS"/kernel-*/patches; do
      [[ -d "$d" ]] && dirs+="$(basename "$(dirname "$d")") "
    done
  else
    dirs="$(sed -nE 's#^external-and-mods/(kernel-[A-Za-z0-9._-]+)/patches/.*#\1#p' <<<"$changed" | sort -u | tr '\n' ' ')"
  fi

  local selected="" covered=" "
  local f name pd dir
  for f in "$MODS"/kernel-*/soc.env; do
    [[ -f "$f" ]] || continue
    name="$(basename "$(dirname "$f")")"
    name="${name#kernel-}"
    [[ "$name" =~ ^[a-z0-9]+$ ]] || continue
    if ! pd="$(port_dirs_of "$name" 2>/dev/null)"; then
      echo "::notice::kernel-$name: soc.env could not be read, skipped."
      continue
    fi
    for dir in $dirs; do
      if [[ " $pd " == *" $dir "* ]]; then
        covered+="$dir "
        [[ " $selected " == *" $name "* ]] || selected+="$name "
      fi
    done
  done

  for dir in $dirs; do
    [[ "$covered" == *" $dir "* ]] \
      || echo "::notice::$dir: no kernel recipe applies these patches with its default settings, so there is no base source to test against. Skipped."
  done

  local json="[" n=0
  for name in $selected; do
    json+="\"$name\","
    n=$((n + 1))
  done
  json="${json%,}]"
  {
    echo "trees=$json"
    echo "any=$([[ $n -gt 0 ]] && echo true || echo false)"
  } >>"${GITHUB_OUTPUT:-/dev/stdout}"
  echo "Kernel recipes to check: ${selected:-none}"
}

check() {
  local name="${1:-}"
  [[ "$name" =~ ^[a-z0-9]+$ ]] || { echo "usage: $0 check <name>" >&2; exit 2; }
  [[ -f "$MODS/kernel-$name/soc.env" ]] || { echo "no kernel-$name/soc.env" >&2; exit 2; }

  # shellcheck disable=SC1090
  source "$MODS/kernel-$name/soc.env"
  local port_dirs
  read -ra port_dirs <<<"${PORT_DIRS:-kernel-$name}"

  local work cache src base_dir
  work="${WORK:-$(mktemp -d)}"
  cache="$work/cache"
  src="$work/linux-src"
  base_dir="$work/base"
  mkdir -p "$cache"

  # Source archive: the recipe's own, else the release from kernel.org.
  local url tarball
  if [[ -n "${KSRC_URL:-}" ]]; then
    url="$KSRC_URL"
  else
    url="https://cdn.kernel.org/pub/linux/kernel/v${KVER%%.*}.x/linux-${KVER}.tar.xz"
  fi
  tarball="$cache/${url##*/}"
  if [[ ! -s "$tarball" ]]; then
    echo "download $url"
    curl -fL --retry 3 -o "$tarball.part" "$url"
    mv -f "$tarball.part" "$tarball"
  fi
  if [[ -n "${KSRC_SHA256:-}" ]]; then
    echo "${KSRC_SHA256}  ${tarball}" | sha256sum -c --quiet \
      || { echo "::error::source hash mismatch: ${tarball##*/}"; exit 1; }
  fi

  # Base patch directories at the pinned release, only those directories.
  local -a base_paths=()
  local d
  for d in ${PATCH_DIRS:-}; do base_paths+=("$d"); done
  # A recipe without PATCH_DIRS is mainline plus its own patches only.
  if [[ ${#base_paths[@]} -gt 0 && ! -d "$base_dir/.git" ]]; then
    git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$ROCKNIX_REF" \
      "$BASE_REPO_URL" "$base_dir"
    git -C "$base_dir" sparse-checkout set "${base_paths[@]}"
    git -C "$base_dir" checkout --quiet
  fi

  echo "extract ${tarball##*/}"
  local x
  x="$(mktemp -d "$work/ksrc.XXXXXX")"
  tar -C "$x" -xf "$tarball"
  if [[ -n "${KSRC_URL:-}" ]]; then
    [[ "$(find "$x" -mindepth 1 -maxdepth 1 | wc -l)" == 1 ]] \
      || { echo "::error::${tarball##*/} has more than one top folder"; exit 1; }
    mv "$x"/* "$src"
    rmdir "$x"
  else
    mv "$x"/linux-* "$src"
    rmdir "$x"
  fi

  local -a dirs
  read -ra dirs <<<"${PATCH_DIRS:-}"
  local pd pdir p count=0
  for pd in "${port_dirs[@]}"; do dirs+=("@port:$pd"); done
  for d in "${dirs[@]}"; do
    if [[ "$d" == @port:* ]]; then
      pdir="$MODS/${d#@port:}/patches"
    else
      pdir="$base_dir/$d"
    fi
    [[ -d "$pdir" ]] || { echo "skip missing patch dir $d"; continue; }
    for p in "$pdir"/*.patch; do
      [[ -e "$p" ]] || continue
      case "$(basename "$p")" in
        9900-i915-10bit-hack.patch) continue ;;  # x86 only
      esac
      if [[ " ${PATCH_SKIP:-} " == *" $(basename "$p") "* ]]; then
        echo "skip $(basename "$p") (PATCH_SKIP)"; continue
      fi
      echo "patch $(basename "$d")/$(basename "$p")"
      if ! patch -d "$src" -p1 -N --no-backup-if-mismatch -s <"$p"; then
        echo "::error::kernel-$name: patch failed: $(basename "$d")/$(basename "$p")"
        exit 1
      fi
      count=$((count + 1))
    done
  done
  echo "kernel-$name: $count patches applied to ${KSRC_URL:+$KSRC_URL }linux-${KVER}"
  [[ -n "${KEEP_WORK:-}" ]] || rm -rf "$work"
}

case "${1:-}" in
  plan) plan ;;
  check) check "${2:-}" ;;
  *) echo "usage: $0 plan | check <name>" >&2; exit 2 ;;
esac
