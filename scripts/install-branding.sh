#!/usr/bin/env bash
# Boot animation, Steam movies and the name's art, on every image. Called by
# each apply-overlays script.
#   install-branding.sh <rootfs>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="${1:?rootfs}"
OVL="${ROOT}/steamos-overlay"
B="${ROOT}/branding"
[[ "$(uname -m)" == aarch64 ]] || { echo "install-branding: needs an aarch64 build host" >&2; exit 1; }

gcc -std=gnu11 -O2 -static "$B/splash/zaviya-splash.c" -lm -o "$R/usr/lib/steamos-arm/zaviya-splash"
chmod 0755 "$R/usr/lib/steamos-arm/zaviya-splash"
install -D -m0644 "$OVL/usr/lib/systemd/system/zaviya-splash.service" "$R/usr/lib/systemd/system/zaviya-splash.service"
install -D -m0644 "$OVL/usr/lib/systemd/system/sddm.service.d/20-zaviya-splash.conf" \
  "$R/usr/lib/systemd/system/sddm.service.d/20-zaviya-splash.conf"
mkdir -p "$R/usr/lib/systemd/system/sysinit.target.wants"
ln -sfn ../zaviya-splash.service "$R/usr/lib/systemd/system/sysinit.target.wants/zaviya-splash.service"

# Frames for the bootloader's boot logo, kernel-efi-sync puts them on BOOT.
rm -rf "$R/usr/share/zaviya/logo"
install -d "$R/usr/share/zaviya/logo" "$R/usr/share/zaviya/movies"
"$R/usr/lib/steamos-arm/zaviya-splash" --intro "$R/usr/share/zaviya/logo"
install -m0644 "$B"/movies/*.webm "$R/usr/share/zaviya/movies/"
echo "branding installed"
