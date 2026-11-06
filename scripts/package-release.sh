#!/bin/bash
# Turns the zaviya-<soc>-<version>.img.zst images in a folder into release files.
# GitHub refuses release files of 2 GiB or more, so every image is split, in two forms:
#   zaviya-<soc>-<version>.img.zst.NNN  the Android installer joins these
#   zaviya-<soc>-<version>.7z.NNN       for computers, extract the .001
# SHA256SUMS lists all of those, plus each joined .img.zst, which is what the
# installer checks once it has joined the parts.
#
# Usage: scripts/package-release.sh <folder with .img.zst files> <empty output folder>
set -euo pipefail

src="${1:?folder with the .img.zst files}"
out="${2:?output folder}"
PART_BYTES="${PART_BYTES:-1992294400}"

die() { echo "error: $*" >&2; exit 1; }
if command -v sha256sum >/dev/null; then sha() { sha256sum "$@"; }; else sha() { shasum -a 256 "$@"; }; fi
if command -v 7zz >/dev/null; then SZ=7zz; elif command -v 7z >/dev/null; then SZ=7z; else die "7-Zip not found"; fi
command -v zstd >/dev/null || die "zstd not found"

shopt -s nullglob
images=("$src"/zaviya-*.img.zst)
(( ${#images[@]} )) || die "no zaviya-*.img.zst in $src"
mkdir -p "$out"
[[ -z "$(ls -A "$out")" ]] || die "$out is not empty"
out="$(cd "$out" && pwd)"

: >"$out/SHA256SUMS"
for img in "${images[@]}"; do
  name="$(basename "$img")"
  stem="${name%.img.zst}"
  echo "== $stem"
  zstd -tq "$img" || die "$name is damaged"

  size="$(wc -c <"$img" | tr -d ' ')"
  n=1; offset=0
  while (( offset < size )); do
    tail -c +"$((offset + 1))" "$img" | head -c "$PART_BYTES" >"$out/$name.$(printf %03d "$n")" || (( ${PIPESTATUS[1]} == 0 ))
    offset=$(( offset + PART_BYTES )); n=$(( n + 1 ))
  done
  joined="$(cat "$out/$name".[0-9][0-9][0-9] | sha | cut -d' ' -f1)"
  whole="$(sha "$img" | cut -d' ' -f1)"
  [[ "$joined" == "$whole" ]] || die "$name parts don't join back to the image"
  echo "$whole  $name" >>"$out/SHA256SUMS"

  zstd -dcq "$img" | "$SZ" a -mx=3 -mmt=on -v"${PART_BYTES}b" -si"$stem.img" "$out/$stem.7z" >/dev/null
  "$SZ" t "$out/$stem.7z.001" >/dev/null || die "$stem.7z failed its test"
done

cd "$out"
for f in *.[0-9][0-9][0-9]; do sha "$f" >>SHA256SUMS; done
echo "Done: $out"
