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

# The logo as apps and the login screen use it.
install -m0644 "$B/logo/zaviya-logo-tagline-white.svg" "$R/usr/share/zaviya/logo-white.svg"
install -m0644 "$B/logo/Jost-OFL.txt" "$R/usr/share/zaviya/Jost-OFL.txt"
ICONS="$R/usr/share/icons/hicolor/scalable"
install -D -m0644 "$B/icons/zaviya.svg" "$ICONS/apps/zaviya.svg"
install -D -m0644 "$B/icons/zaviya-mark.svg" "$ICONS/apps/zaviya-mark.svg"
install -D -m0644 "$B/icons/zaviya.svg" "$ICONS/apps/steamos-gamemode.svg"
install -D -m0644 "$B/icons/zaviya-mark.svg" "$ICONS/places/distributor-logo-steamdeck.svg"
install -D -m0644 "$B/icons/zaviya-256.png" "$R/usr/share/pixmaps/zaviya.png"

# Wallpaper, replacing the ones with the Deck's logo.
W="$R/usr/share/wallpapers"
rm -f "$W"/Steam\ Deck\ Logo*.jpg "$W/Troll.jpg"
install -D -m0644 "$B/plasma/metadata.json" "$W/Zaviya/metadata.json"
install -D -m0644 "$B/wallpaper/3840x2160.jpg" "$W/Zaviya/contents/images/3840x2160.jpg"
ZW=/usr/share/wallpapers/Zaviya/contents/images/3840x2160.jpg

# New Plasma profiles, then the ones that already exist. Startup screen too.
for lnf in "$R"/usr/share/plasma/look-and-feel/com.valve.*; do
  [[ -d "$lnf/contents" ]] || continue
  sed -i "s|/usr/share/wallpapers/Steam Deck Logo Default.jpg|/usr/share/wallpapers/Zaviya|" \
    "$lnf/contents/plasmoidsetupscripts/org.kde.plasma.folder.js" 2>/dev/null || true
  sed -i 's|distributor-logo-steamdeck|zaviya-mark|' \
    "$lnf/contents/plasmoidsetupscripts/org.kde.plasma.kickoff.js" 2>/dev/null || true
  if [[ -d "$lnf/contents/splash" ]]; then
    rm -rf "$lnf/contents/splash"
    install -D -m0644 "$B/plasma/Splash.qml" "$lnf/contents/splash/Splash.qml"
    install -D -m0644 "$B/logo/zaviya-logo-tagline-white.svg" "$lnf/contents/splash/images/zaviya.svg"
  fi
done
install -D -m0644 "$B/plasma/zaviya-branding.js" \
  "$R/usr/share/plasma/shells/org.kde.plasma.desktop/contents/updates/zaviya-branding.js"

# Login screen.
cat >"$R/usr/share/sddm/themes/breeze/theme.conf.user" <<CONF
[General]
type=image
background=$ZW
showlogo=shown
logo=/usr/share/zaviya/logo-white.svg
CONF
echo "branding installed"
