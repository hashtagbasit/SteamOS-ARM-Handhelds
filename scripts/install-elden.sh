#!/bin/bash
# Lenovo Legion Y700 Gen 4 (elden) support in the 8 Elite rootfs.
#
#   install-elden.sh ROOTFS
#
# The firmware manifest (copied out of the tablet's Android by
# tablet-firmware, at install and on boot while anything is missing), the
# compiled audio topology and the UCM profile, all under the tablet's own
# names so the Odin 3 and Pocket FIT Elite are untouched. The firmware dir
# goes first in the tablet's firmware search (firmware_class.path in its
# cmdline), since its device tree asks for qcom/sm8750/... like the others.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../external-and-mods/elden/release.env"
R="${1:?rootfs}"
CACHE="${CACHE:-/work/cache/elden}"
die() { echo "[elden] ERROR: $*" >&2; exit 1; }
mkdir -p "$CACHE"
[[ -s "$CACHE/elden-src.tar.gz" ]] || { curl -fsSL --retry 3 -o "$CACHE/elden-src.tar.gz.part" "$ELDEN_SRC_URL"; mv -f "$CACHE/elden-src.tar.gz.part" "$CACHE/elden-src.tar.gz"; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
tar -C "$W" -xzf "$CACHE/elden-src.tar.gz"
S="$(echo "$W"/tb322fc-linux-*)"
[[ -f "$S/firmware.json" ]] || die "no firmware.json in the pinned source"

install -Dm0644 "$S/firmware.json" "$R/usr/share/steamos-arm/tablets/elden-firmware.json"

# Topology, compiled with the rootfs's own alsatplg, checked against the
# tablet-validated build.
tplg="$R/usr/lib/firmware/qcom/sm8750/Lenovo-Y700-Gen4-tplg.bin"
mkdir -p "$(dirname "$tplg")"
cp "$S/inputs/audio/Lenovo-Y700-Gen4.conf" "$R/tmp/elden-tplg.conf"
chroot "$R" alsatplg -c /tmp/elden-tplg.conf -o /tmp/elden-tplg.bin >/dev/null || die "alsatplg failed"
mv "$R/tmp/elden-tplg.bin" "$tplg"; rm -f "$R/tmp/elden-tplg.conf"
echo "$ELDEN_TPLG_SHA256  $tplg" | sha256sum -c --quiet || die "topology differs from the validated one"

U="$R/usr/share/alsa/ucm2"
rm -rf "$U/Qualcomm/sm8750/Lenovo-Y700-Gen4"
mkdir -p "$U/Qualcomm/sm8750" "$U/conf.d/sm8750"
cp -a "$S/rootfs/audio/ucm2/Qualcomm/sm8750/Lenovo-Y700-Gen4" "$U/Qualcomm/sm8750/"
cp -a "$S/rootfs/audio/ucm2/conf.d/sm8750/Lenovo-Y700-Gen4.conf" "$U/conf.d/sm8750/"
# Tell the ABL each boot worked, or it gives up on the slot after 7.
O="${HERE}/../steamos-overlay"
install -Dm0755 "$O/usr/lib/steamos-arm/tablet-boot-ok" "$R/usr/lib/steamos-arm/tablet-boot-ok"
install -Dm0644 "$O/usr/lib/systemd/system/steamos-arm-tablet-boot-ok.service" "$R/usr/lib/systemd/system/steamos-arm-tablet-boot-ok.service"
mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants"
ln -sfn ../steamos-arm-tablet-boot-ok.service "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tablet-boot-ok.service"
# Touch reports the portrait panel's coordinates, and it is on SPI, which
# gamescope doesn't tie to a display (only I2C and USB), so it never rotates
# it. Game Mode turns the panel right (GAMESCOPE_ORIENTATION on the 8 Elite):
# rotate touch to match in libinput, and undo that in Plasma, where KWin
# maps touch to the output itself.
install -Dm0644 /dev/stdin "$R/usr/lib/udev/rules.d/90-steamos-arm-elden-touch.rules" <<'RULES'
# Lenovo Legion Y700 Gen 4: the touch panel reports portrait coordinates, Game Mode runs landscape.
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NVTCapacitiveTouchScreen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 1 0 -1 0 1"
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NVTCapacitivePen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 1 0 -1 0 1"
# Screen flipped 180 degrees (Handheld Control, /etc/steamos-arm/flip-screen): the other landscape.
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NVTCapacitiveTouchScreen", TEST=="/etc/steamos-arm/flip-screen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 -1 1 1 0 0"
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NVTCapacitivePen", TEST=="/etc/steamos-arm/flip-screen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 -1 1 1 0 0"
RULES
mkdir -p "$R/etc/xdg"
grep -qs 'NVTCapacitiveTouchScreen' "$R/etc/xdg/kcminputrc" || cat >> "$R/etc/xdg/kcminputrc" <<'KCM'
# Lenovo Legion Y700 Gen 4 touch: udev rotates it for gamescope, KWin rotates it itself.
[Libinput][0][0][NVTCapacitiveTouchScreen]
CalibrationMatrix=1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1

[Libinput][0][0][NVTCapacitivePen]
CalibrationMatrix=1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1
KCM
# The cameras have no working driver here (/dev/video* fail with ENOMEM) and
# WirePlumber's v4l2 hook never completes on them, which stalls its event
# queue: PipeWire stops answering from boot, so Steam's menus have no sound,
# games freeze until it does, the volume keys do nothing and Desktop Mode's
# settings hang. Same as the Gen 3. A profile can't be scoped to a device, so
# a unit gated on the tablet puts the override into /etc.
install -Dm0644 /dev/stdin "$R/usr/share/steamos-arm/elden/52-elden.conf" <<'CONF'
# Lenovo Legion Y700 Gen 4 (steamos-arm-elden-setup.service): the cameras
# stall WirePlumber, and Game Mode has no xdg-desktop-portal.
wireplumber.profiles = {
  main = {
    monitor.v4l2 = disabled
    monitor.libcamera = disabled
    support.portal-permissionstore = disabled
  }
}
CONF
install -Dm0644 /dev/stdin "$R/usr/lib/systemd/system/steamos-arm-elden-setup.service" <<'UNIT'
[Unit]
Description=Lenovo Legion Y700 Gen 4: audio server and Wi-Fi settings for this tablet
ConditionFirmware=device-tree-compatible(lenovo,elden)
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target display-manager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/install -Dm0644 /usr/share/steamos-arm/elden/52-elden.conf /etc/wireplumber/wireplumber.conf.d/52-elden.conf
# Wi-Fi through iwd: some home networks never connected with wpa_supplicant
# (Gen 4 testers; turning off "Force WPA Supplicant" in Steam fixed it). Same
# file Steam's switch writes, so that switch still works, and only when
# nothing chose a backend yet.
ExecStart=/bin/sh -c 'f=/etc/NetworkManager/conf.d/99-valve-wifi-backend.conf; [ -e "$f" ] || printf "[device]\\nwifi.backend=iwd\\n" > "$f"'

[Install]
WantedBy=sysinit.target
UNIT
mkdir -p "$R/usr/lib/systemd/system/sysinit.target.wants"
ln -sfn ../steamos-arm-elden-setup.service "$R/usr/lib/systemd/system/sysinit.target.wants/steamos-arm-elden-setup.service"

# Speakers: their UCM device has no hardware volume, so PipeWire's software
# curve made 15-25 % silent (testers), and at +8 dB still everything under
# 15 % (test 9). Same chain as the Pocket FIT's, at +14 dB
# into x42's peak limiter (true-peak ceiling -1 dBFS), so quiet settings are
# audible and full scale still doesn't clip. Speaker sink only, by card name.
[[ -f "$R/usr/lib/lv2/dpl.lv2/manifest.ttl" ]] || die "dpl.lv2 (the speaker limiter) missing from the rootfs"
install -Dm0644 /dev/stdin "$R/usr/share/wireplumber/wireplumber.conf.d/56-elden-speaker.conf" <<'CONF'
# Lenovo Legion Y700 Gen 4 speakers: +14 dB into a peak limiter (install-elden.sh).
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_output.*Speaker.*" alsa.card_name = "Lenovo-Y700-Gen4" } ]
    actions = {
      update-props = {
        audioconvert.filter-graph.0 = {
          nodes = [
            { type = lv2 name = lim plugin = "http://gareus.org/oss/lv2/dpl#stereo"
              control = { "gain" = 14.0 "threshold" = -1.0 "release" = 0.01 "truepeak" = 1 } }
          ]
          inputs = [ "lim:inL" "lim:inR" ]
          outputs = [ "lim:outL" "lim:outR" ]
        }
      }
    }
  }
]
CONF

# Charge to 100 % (the battery firmware keeps Android's battery-care limit).
O="${HERE}/../steamos-overlay"
install -Dm0755 "$O/usr/lib/steamos-arm/tablet-charge-full" "$R/usr/lib/steamos-arm/tablet-charge-full"
install -Dm0644 "$O/usr/lib/systemd/system/steamos-arm-tablet-charge-full.service" "$R/usr/lib/systemd/system/steamos-arm-tablet-charge-full.service"
ln -sfn ../steamos-arm-tablet-charge-full.service "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tablet-charge-full.service"
# The firmware copy from Android (split firmware joined now).
install -Dm0755 "$O/usr/lib/steamos-arm/tablet-firmware" "$R/usr/lib/steamos-arm/tablet-firmware"
install -Dm0755 "$O/usr/lib/steamos-arm/tablet-firmware-boot" "$R/usr/lib/steamos-arm/tablet-firmware-boot"
# Both Lenovo tablets: start dark and charge when the charger started the
# tablet, keep the brightness across restarts, and put on screen why the
# session didn't start when it doesn't.
for f in tablet-charger-hold tablet-backlight tablet-boot-watch; do
  install -Dm0755 "$O/usr/lib/steamos-arm/$f" "$R/usr/lib/steamos-arm/$f"
done
install -Dm0755 "$O/usr/lib/systemd/system-sleep/steamos-arm-sleep-stats" "$R/usr/lib/systemd/system-sleep/steamos-arm-sleep-stats"
# Dual boot with ZUXOS: switch slots (Handheld Control's Restart into ZUXOS),
# and move SteamOS from the microSD card to internal storage next to ZUXOS.
# The boot menu (ZUXOS / SteamOS on slot A) comes from a separate add-on bundle
# (scripts/build-kshimc.sh); its sync service keeps the menu's SteamOS kernel
# the one in boot_b.
for f in tablet-slot tablet-dualboot-install tablet-bootmenu-install tablet-bootmenu-pack; do
  install -Dm0755 "$O/usr/lib/steamos-arm/$f" "$R/usr/lib/steamos-arm/$f"
done
install -Dm0644 "$O/usr/lib/systemd/system/steamos-arm-tablet-bootmenu-sync.service" "$R/usr/lib/systemd/system/steamos-arm-tablet-bootmenu-sync.service"
ln -sfn ../steamos-arm-tablet-bootmenu-sync.service "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tablet-bootmenu-sync.service"
# Asleep or awake, power off before the battery runs flat: a sleeping
# handheld at 0 % browns out and can boot-loop on the charger.
install -Dm0755 "$O/usr/lib/systemd/system-sleep/steamos-arm-low-battery" "$R/usr/lib/systemd/system-sleep/steamos-arm-low-battery"
sed -i -e 's/^PercentageCritical=.*/PercentageCritical=6/' -e 's/^PercentageAction=.*/PercentageAction=4/' \
  -e 's/^CriticalPowerAction=.*/CriticalPowerAction=PowerOff/' "$R/etc/UPower/UPower.conf"
for u in steamos-arm-tablet-charger steamos-arm-tablet-backlight steamos-arm-tablet-boot-watch; do
  install -Dm0644 "$O/usr/lib/systemd/system/$u.service" "$R/usr/lib/systemd/system/$u.service"
  ln -sfn ../$u.service "$R/usr/lib/systemd/system/multi-user.target.wants/$u.service"
done
# Legion G9 2026 controller (3537:1136) on the Gen 4: the pad as a Steam Deck
# controller, the tablet's haptics motors for rumble, and the controller's
# firmware double-Home (a KEY_HOMEPAGE pulse) as Quick Access.
E="${HERE}/../external-and-mods/elden/rootfs/usr/share/inputplumber"
install -Dm0644 "$E/devices/05-lenovo-y700-gen4-g9-2026.yaml" "$R/usr/share/inputplumber/devices/05-lenovo-y700-gen4-g9-2026.yaml"
for m in lenovo_legion_g9_2026 y700_g9_consumer; do
  install -Dm0644 "$E/capability_maps/$m.yaml" "$R/usr/share/inputplumber/capability_maps/$m.yaml"
done
echo "[elden] firmware manifest, topology and audio profile installed"
