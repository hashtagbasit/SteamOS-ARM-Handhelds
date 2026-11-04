#!/bin/bash
# stage-openabl.sh BOOT_DIR SOC
# Put OpenABL for SOC (sm8250, sm8550, sm8650, sm8750) and its flash/backup/
# restore scripts into BOOT_DIR/openabl/, from the release pinned
# in external-and-mods/openabl/release.env. The download is cached in
# $STEAMOS_WORK/cache and every file is checked against the pinned hashes.
set -euo pipefail
BOOT=$1
soc=${2^^}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/external-and-mods/openabl"
. "$SRC/release.env"
die() { echo "stage-openabl: $*" >&2; exit 1; }

case $soc in
  SM8250) platform=kona;      models="SM8250";          devices="Retroid Pocket 5 / Flip 2 / Mini / Mini V2, AYN Thor Lite, MANGMI Air Y Pro / Pocket Max, AYANEO Pocket MICRO 2" ;;
  SM8550) platform=kalama;    models="SM8550 QCS8550";  devices="AYN Odin 2 / Mini / Portal / Thor, AYANEO Pocket ACE / DMG / DS / EVO / S 1K / S 2K, Retroid Pocket 6 / Nova" ;;
  SM8650) platform=pineapple; models="SM8650";          devices="KONKR Pocket FIT, AYANEO Pocket S2" ;;
  SM8750) platform=sun;       models="SM8750 CQ8725S";  devices="AYN Odin 3, KONKR Pocket FIT Elite" ;;
  *) die "unknown SoC $2" ;;
esac
want_var=ABL_SHA256_$soc
want=${!want_var}

cache=${STEAMOS_WORK:-/work}/cache
mkdir -p "$cache"
tarball=$cache/$(basename "$ABL_URL")
if [[ ! -s $tarball ]] || [[ "$(sha256sum "$tarball" | cut -d' ' -f1)" != "$ABL_TARBALL_SHA256" ]]; then
  curl -fsSL -o "$tarball.part" "$ABL_URL" || die "download failed: $ABL_URL"
  mv "$tarball.part" "$tarball"
fi
[[ "$(sha256sum "$tarball" | cut -d' ' -f1)" == "$ABL_TARBALL_SHA256" ]] || die "release tarball hash mismatch"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tar -xzf "$tarball" -C "$tmp"
elf="$tmp/openabl-v$ABL_VERSION/$soc/abl_signed-$soc.elf"
[[ -f $elf ]] || die "abl_signed-$soc.elf not in the release"
[[ "$(sha256sum "$elf" | cut -d' ' -f1)" == "$want" ]] || die "abl_signed-$soc.elf hash mismatch"

# Flat, like ROCKNIX's own image. The scripts are ROCKNIX's: plain dd lines
# with the literal /sdcard/openabl path. The vendor "run script as root"
# tools (AYN's at least) run them line by line, show no output, and loops,
# tests and $(...) there wrote nothing (#69).
out=$BOOT/openabl
rm -rf "$out"
mkdir -p "$out"
install -m0644 "$elf" "$out/abl_signed-$soc.elf"
echo "$want  abl_signed-$soc.elf" > "$out/abl_signed-$soc.elf.sha256"
bytes=$(stat -c %s "$elf")
fill() { sed -e "s|@ABL_SHA@|$want|g" -e "s|@ABL_BYTES@|$bytes|g" -e "s/@ABL_MATCH@/${models// /|}|$platform/g" -e "s|@SOC@|$soc|g" -e "s|@PLATFORM@|$platform|g" -e "s|@MODELS@|$models|g" \
             -e "s|@VERSION@|$ABL_VERSION|g" -e "s|@DEVICES@|$devices|g"; }
for s in flash_abl backup_abl restore_backup_abl; do
  fill < "$SRC/$s.sh" > "$out/$s.sh"
done
fill < "$SRC/README.txt" | sed 's/$/\r/' > "$out/README.txt"
grep -q '@' "$out"/*.sh && die "unfilled placeholder in the scripts"
echo "OpenABL $ABL_VERSION for $soc staged in $out"
