#!/bin/bash
# Fetch the pinned OpenABL release and copy the four signed ELFs into the app's assets.
# Every file is checked against the pinned hashes. Same pins as scripts/stage-openabl.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$here/app/src/main/assets/openabl"
URL=https://github.com/OpenHandheldCollective/OpenABL/releases/download/v1.2/openabl-v1.2.tar.gz
TARBALL_SHA256=28cb97d1b387f28ddba28ed57fdc7d8b1c2ac2cdcd26af9c672620d41abddd4f
want() {
  case $1 in
    SM8250) echo 628dbff74f5b570b897c14725f2c36ff2ca5fe018998e2c248a3d15d906ccef9 ;;
    SM8550) echo 2a2808d12f2d494ddd2c39093bbffa90bc43402050be1a87baf6a4c37c830163 ;;
    SM8650) echo 303e389b1e3909074b42415276872c3fc0dcc997200918b4d055fd264b0736dc ;;
    SM8750) echo 0dba7b90d1a36e13977c00fec87f4f5ccc8f49b98864ad495a1ed04d35e33c3a ;;
  esac
}
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/abl.tgz" "$URL"
[[ "$(sha "$tmp/abl.tgz")" == "$TARBALL_SHA256" ]] || { echo "tarball hash mismatch" >&2; exit 1; }
tar -xzf "$tmp/abl.tgz" -C "$tmp"
mkdir -p "$out"
for soc in SM8250 SM8550 SM8650 SM8750; do
  f="$tmp/openabl-v1.2/$soc/abl_signed-$soc.elf"
  [[ "$(sha "$f")" == "$(want $soc)" ]] || { echo "$soc hash mismatch" >&2; exit 1; }
  install -m0644 "$f" "$out/abl_signed-$soc.elf"
done
echo "OpenABL 1.2 ELFs copied to $out"
