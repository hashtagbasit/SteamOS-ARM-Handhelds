#!/bin/bash
# Lenovo Legion Y700 Gen 3 (TB321FU) support in the 8 Gen 3 rootfs.
#
#   install-tb321fu.sh ROOTFS
#
# Firmware and the audio profile, kept out of what the Pocket FIT and Pocket
# S2 use from the same rootfs:
#  - the tablet's own files go to its own paths (qcom/sm8650/lenovo/tb321fu,
#    qca/hmtnv20_Kirby_*, the Qualcomm/sm8650/TB321FU UCM)
#  - its Wi-Fi firmware and board data replace the shared WCN7850 files, so
#    they go to /usr/lib/firmware/steamos-arm/tb321fu, which only the
#    tablet's cmdline puts first in the search (firmware_class.path)
#  - settings no other device should get are installed by units gated on
#    its device tree
# Downloads are cached in ${CACHE:-/work/cache/tb321fu-boot}.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/../external-and-mods/tb321fu-boot/release.env"
R="${1:?rootfs}"
CACHE="${CACHE:-/work/cache/tb321fu-boot}"
log() { echo "[tb321fu] $*"; }
die() { echo "[tb321fu] ERROR: $*" >&2; exit 1; }
mkdir -p "$CACHE"

fetch() {  # fetch URL FILE [SHA256]
  [[ -s "$CACHE/$2" ]] || { curl -fsSL --retry 3 -o "$CACHE/$2.part" "$1"; mv -f "$CACHE/$2.part" "$CACHE/$2"; }
  [[ -z "${3:-}" ]] || echo "$3  $CACHE/$2" | sha256sum -c --quiet || die "hash mismatch: $2"
}

# Firmware: unpack, check the pinned SHA256SUMS, then every file against it.
fetch "$TB321FU_FW_URL" "tb321fu-firmware-$(basename "$TB321FU_FW_URL")"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
tar -C "$W" -xzf "$CACHE/tb321fu-firmware-$(basename "$TB321FU_FW_URL")"
FW="$(echo "$W"/firmware-lenovo-tb321fu-*)"
echo "$TB321FU_FW_SUMS_SHA256  $FW/SHA256SUMS" | sha256sum -c --quiet || die "firmware SHA256SUMS changed"
(cd "$FW" && sha256sum -c --quiet SHA256SUMS) || die "firmware files don't match SHA256SUMS"

F="$R/usr/lib/firmware"
mkdir -p "$F/qcom/sm8650/lenovo" "$F/steamos-arm/tb321fu/ath12k/WCN7850"
rm -rf "$F/qcom/sm8650/lenovo/tb321fu"
cp -a "$FW/usr/lib/firmware/qcom/sm8650/lenovo/tb321fu" "$F/qcom/sm8650/lenovo/"
cp -a "$FW/usr/lib/firmware/qcom/sm8650/Lenovo-Y700-TB321FU-tplg.bin" "$F/qcom/sm8650/"
cp -a "$FW/usr/lib/firmware/aw882xx_acf.bin" "$FW/usr/lib/firmware/haptic_click.bin" \
  "$FW/usr/lib/firmware/haptic_ram.bin" "$F/"
rm -rf "$F/steamos-arm/tb321fu/ath12k/WCN7850/hw2.0"
cp -a "$FW/usr/lib/firmware/updates/ath12k/WCN7850/hw2.0" "$F/steamos-arm/tb321fu/ath12k/WCN7850/"

# GUF296's packages: Bluetooth NVM, CSOT touch firmware.
fetch "$TB321FU_DEBS_URL" tb321fu-debs.tar.gz "$TB321FU_DEBS_SHA256"
mkdir -p "$W/debs" "$W/ov"
tar -C "$W/debs" -xzf "$CACHE/tb321fu-debs.tar.gz"
deb="$(echo "$W"/debs/y700-daily-rootfs-overlay_*_arm64.deb)"
[[ -f "$deb" ]] || die "no rootfs overlay package in the device packages"
(cd "$W/debs" && ar x "$deb" data.tar.xz)
tar -C "$W/ov" -xJf "$W/debs/data.tar.xz" ./usr/lib/firmware
O="$W/ov/usr/lib/firmware"
cp -a "$O/qca/hmtnv20_Kirby_prc.bin" "$O/qca/hmtnv20_Kirby_row.bin" "$F/qca/"
# The Kirby NVM only loads after the patch it was released with
# (BTFW.HAMILTON.2.0.1-00355); with the newer shared hmtbtfw20.tlv the
# controller rejects it (-52) and Bluetooth never comes up. The pair goes
# to the tablet's own firmware path, searched first only on the tablet.
mkdir -p "$F/steamos-arm/tb321fu/qca"
cp -a "$O/qca/hmtbtfw20.tlv" "$O/qca/hmtnv20_Kirby_prc.bin" "$O/qca/hmtnv20_Kirby_row.bin" \
  "$F/steamos-arm/tb321fu/qca/"
cp -a "$O/qcom/sm8650/lenovo/tb321fu/novatek_ts_csot_fw.bin" \
  "$O/qcom/sm8650/lenovo/tb321fu/novatek_ts_csot_mp.bin" "$F/qcom/sm8650/lenovo/tb321fu/"

# Audio profile: from the tree the kernel is built from (same commit), whose
# controls it uses (aw882xx_rx_switch, aw_dev_N_switch, ...). GUF296's
# profile was written for his kernel's controls and routes nothing on this one.
fetch "$TB321FU_PORT_URL" tb321fu-port.tar.gz
mkdir -p "$W/port"
tar -C "$W/port" -xzf "$CACHE/tb321fu-port.tar.gz" --strip-components=1 --wildcards '*/system_files/usr/share/alsa/ucm2/*'
A="$W/port/system_files/usr/share/alsa/ucm2"
[[ -f "$A/Qualcomm/sm8650/TB321FU/HiFi.conf" ]] || die "no TB321FU audio profile in the kernel's source tree"
U="$R/usr/share/alsa/ucm2"
rm -rf "$U/LenovoY700TB321" "$U/Qualcomm/sm8650/TB321FU"
rm -f "$U/conf.d/snd_soc_sc8280xp/Lenovo-Y700-TB321FU.conf" "$U/conf.d/snd_soc_sc8280xp/Lenovo-QRD-2.0.conf"
mkdir -p "$U/Qualcomm/sm8650" "$U/conf.d/sm8650"
cp -a "$A/Qualcomm/sm8650/TB321FU" "$U/Qualcomm/sm8650/"
# Our HiFi verb over the tree's: speakers on PCM 0 through Secondary TDM,
# the route heard on a tablet (the tree's PCM 1 route stayed silent).
install -m0644 "${HERE}/../external-and-mods/tb321fu-boot/ucm/HiFi.conf" "$U/Qualcomm/sm8650/TB321FU/HiFi.conf"
# Some Lenovo firmware names the card Lenovo-QRD-2.0.
for n in Lenovo-Y700-TB321FU Lenovo-QRD-2.0; do
  install -m0644 "$A/conf.d/sm8650/$n.conf" "$U/conf.d/sm8650/$n.conf"
done
for f in /codecs/wcd939x/init.conf /codecs/wcd939x/HeadphoneEnableSeq.conf \
         /codecs/qcom-lpass/rx-macro/HeadphoneEnableSeq.conf /codecs/qcom-lpass/tx-macro/SoundwireMic0EnableSeq.conf \
         /lib/card-init.conf /lib/ctl-remap.conf; do
  [[ -f "$U$f" ]] || die "the rootfs's alsa-ucm-conf has no $f, which the profile includes"
done

# The ADSP takes at most 65280-byte buffers in 2-8 periods for this card;
# PipeWire's default request fails (EINVAL) and nothing plays. The Pocket
# FIT's rules in /etc (53-konkr-audio, 54-konkr-quantum) match every
# platform-sound card and sort after a 5x name: they set 960-frame periods
# and ask for a "HiFi (Headphones, Speaker)" profile this card doesn't have
# (speakers and headphones share PCM 0 and exclude each other, and the mics
# are part of every profile). This file sorts after them and is matched by
# the card name, so no other device sees it. Headphones first: their profile
# is only available with something in the jack.
rm -f "$R/usr/share/wireplumber/wireplumber.conf.d/51-lenovo-tb321fu-alsa.conf"
install -Dm0644 /dev/stdin "$R/usr/share/wireplumber/wireplumber.conf.d/90-lenovo-tb321fu-alsa.conf" <<'CONF'
# Lenovo Legion Y700 Gen 3: its own profile order and the buffer sizes the
# ADSP accepts for its card (after the Pocket FIT's 53/54 rules).
monitor.alsa.rules = [
  {
    matches = [
      { alsa.card_name = "Lenovo-Y700-TB321FU" } { alsa.card_name = "Lenovo-QRD-2.0" }
      { api.alsa.card.name = "Lenovo-Y700-TB321FU" } { api.alsa.card.name = "Lenovo-QRD-2.0" }
    ]
    actions = {
      update-props = {
        api.acp.auto-profile = true
        api.acp.auto-port = true
        device.profile = "pro-audio"
        api.alsa.period-size = 1024
        api.alsa.period-num = 4
        api.alsa.headroom = 0
        api.alsa.disable-tsched = false
        node.force-quantum = 1024
      }
    }
  }
]
device.profile.priority.rules = [
  {
    matches = [
      { alsa.card_name = "Lenovo-Y700-TB321FU" } { alsa.card_name = "Lenovo-QRD-2.0" }
      { api.alsa.card.name = "Lenovo-Y700-TB321FU" } { api.alsa.card.name = "Lenovo-QRD-2.0" }
    ]
    actions = {
      update-props = {
        priorities = [
          "pro-audio"
        ]
      }
    }
  }
]
CONF

# The card's HiFi profiles never opened under PipeWire on test 6 (the sink
# was auto_null, no sound or mic), while the same routes set with alsaucm and
# played through pro-audio work (a tester's script, confirmed by others). So
# play through pro-audio and let a user service set the routes: the speakers,
# or the headphones while something is in the jack, plus the microphones.
install -Dm0755 /dev/stdin "$R/usr/lib/steamos-arm/tb321fu-audio" <<'SH'
#!/bin/bash
# Lenovo Legion Y700 Gen 3 sound (steamos-arm-tb321fu-audio.service, per user).
CARD=LenovoY700TB321
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-arm/tb321fu-audio"
sink() { pactl list short sinks 2>/dev/null | awk '/platform-sound\.pro-output-0/ {print $2; exit}'; }
jack() { amixer -c "$CARD" cget "iface=CARD,name='Headphone Jack'" 2>/dev/null | grep -q ': values=on'; }
dp() { amixer -c "$CARD" cget "iface=CARD,name='DP0 Jack'" 2>/dev/null | grep -q ': values=on'; }
mode() { if dp; then echo dp; elif jack; then echo hp; else echo spk; fi; }
route() {  # DisplayPort, headphones or speakers, and the microphone that goes with them
  if dp; then
    alsaucm -c "hw:$CARD" set _verb HiFi set _enadev DisplayPort set _enadev Mic1 >/dev/null 2>&1
  elif jack; then
    alsaucm -c "hw:$CARD" set _verb HiFi set _enadev Headphones set _enadev Headset >/dev/null 2>&1
  else
    alsaucm -c "hw:$CARD" set _verb HiFi set _enadev Speaker set _enadev Mic1 >/dev/null 2>&1
  fi
}
start() {
  for _ in $(seq 30); do pactl list short cards 2>/dev/null | grep -q platform-sound && break; sleep 1; done
  route
  # Open the PCMs again after the routes are set.
  pactl set-card-profile alsa_card.platform-sound off 2>/dev/null
  pactl set-card-profile alsa_card.platform-sound pro-audio 2>/dev/null || return 1
  for _ in $(seq 10); do [ -n "$(sink)" ] && break; sleep 0.5; done
  s="$(sink)"; [ -n "$s" ] || return 1
  pactl set-default-sink "$s"
  src="$(pactl list short sources 2>/dev/null | awk '/platform-sound\.pro-input-2/ {print $2; exit}')"
  [ -n "$src" ] && pactl set-default-source "$src"
  # First start only: a sane volume. After that, PipeWire keeps the user's.
  # The microphone starts at 80 %: at 100 % speech peaks reach 0 dBFS.
  if [ ! -e "$STATE" ]; then
    pactl set-sink-volume "$s" 40%; pactl set-sink-mute "$s" 0
    [ -n "$src" ] && pactl set-source-volume "$src" 80%
    mkdir -p "${STATE%/*}"; : >"$STATE"
  fi
}
start || exit 1
last="$(mode)"
while sleep 1; do
  now="$(mode)"
  if [ "$now" != "$last" ]; then
    route
    # The DP driver holds the display commit that goes back to the panel
    # until the DP audio stream is closed: close the sink now when the
    # display goes, not after PipeWire's idle timeout (the panel stayed black
    # for 5 s).
    if [ "$last" = dp ]; then
      pactl suspend-sink "$(sink)" 1 2>/dev/null; pactl suspend-sink "$(sink)" 0 2>/dev/null
    fi
    last="$now"
  fi
  # The card came back (PipeWire or WirePlumber restarted): set it up again.
  [ -n "$(sink)" ] || { sleep 2; start; }
done
SH
install -Dm0644 /dev/stdin "$R/usr/lib/systemd/user/steamos-arm-tb321fu-audio.service" <<'UNIT'
[Unit]
Description=Lenovo Legion Y700 Gen 3: speaker, headphone and microphone routes
ConditionFirmware=device-tree-compatible(lenovo,tb321fu)
After=wireplumber.service pipewire-pulse.service
Wants=wireplumber.service pipewire-pulse.service

[Service]
ExecStart=/usr/lib/steamos-arm/tb321fu-audio
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
UNIT
mkdir -p "$R/usr/lib/systemd/user/default.target.wants"
ln -sfn ../steamos-arm-tb321fu-audio.service "$R/usr/lib/systemd/user/default.target.wants/steamos-arm-tb321fu-audio.service"
# Quiet settings were inaudible (25 % on test 5): +6 dB into x42's peak
# limiter on the card's output. Speakers and headphones share it, hence less
# than the Pocket FIT's +8.
install -Dm0644 /dev/stdin "$R/usr/share/wireplumber/wireplumber.conf.d/91-lenovo-tb321fu-speaker.conf" <<'CONF'
# Lenovo Legion Y700 Gen 3 output: +6 dB into a peak limiter (install-tb321fu.sh).
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_output.platform-sound.pro-output-0.*" alsa.card_name = "Lenovo-Y700-TB321FU" } ]
    actions = {
      update-props = {
        audioconvert.filter-graph.0 = {
          nodes = [
            { type = lv2 name = lim plugin = "http://gareus.org/oss/lv2/dpl#stereo"
              control = { "gain" = 6.0 "threshold" = -1.0 "release" = 0.01 "truepeak" = 1 } }
          ]
          inputs = [ "lim:inL" "lim:inR" ]
          outputs = [ "lim:outL" "lim:outR" ]
        }
      }
    }
  }
]
CONF

# Desktop Mode: the panel's two halves are 800 px wide, so the DPU's inline
# rotator takes the rotation and leaves a line at the seam; KWin rotates in
# the compositor instead (Game Mode already uses gamescope's shader).
install -Dm0755 /dev/stdin "$R/etc/xdg/plasma-workspace/env/steamos-arm-tablet-kwin.sh" <<'ENV'
#!/bin/sh
# Lenovo Legion Y700 Gen 3: rotate in the compositor (see install-tb321fu.sh).
if tr '\0' '\n' </sys/firmware/devicetree/base/compatible 2>/dev/null | grep -qx 'lenovo,tb321fu'; then
  export KWIN_ENABLE_HW_ROTATION=0
fi
ENV

# Touch and pen report the panel's native portrait coordinates. gamescope only
# rotates touch for I2C (internal) or USB (external) devices and these are on
# SPI, so it maps them unrotated: taps land in the wrong place in Game Mode.
# Rotate them in libinput (the matrix for DT rotation 90, "right-up").
install -Dm0644 /dev/stdin "$R/usr/lib/udev/rules.d/90-steamos-arm-tb321fu-touch.rules" <<'RULES'
# Lenovo Legion Y700 Gen 3: the touch panel reports portrait coordinates, the session runs landscape.
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NVTCapacitiveTouchScreen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 1 0 -1 0 1"
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NVTCapacitivePen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 1 0 -1 0 1"
# Screen flipped 180 degrees (Handheld Control, /etc/steamos-arm/flip-screen): the other landscape.
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NVTCapacitiveTouchScreen", TEST=="/etc/steamos-arm/flip-screen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 -1 1 1 0 0"
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NVTCapacitivePen", TEST=="/etc/steamos-arm/flip-screen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 -1 1 1 0 0"
RULES
# KWin already maps touch to the rotated output, so Desktop Mode undoes the
# udev matrix. Appended: other devices' groups in the file stay as they are.
mkdir -p "$R/etc/xdg"
grep -qs 'NVTCapacitiveTouchScreen' "$R/etc/xdg/kcminputrc" || cat >> "$R/etc/xdg/kcminputrc" <<'KCM'
# Lenovo Legion Y700 Gen 3 touch: udev rotates it for gamescope, KWin rotates it itself.
[Libinput][0][0][NVTCapacitiveTouchScreen]
CalibrationMatrix=1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1

[Libinput][0][0][NVTCapacitivePen]
CalibrationMatrix=1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1
KCM

# The Adreno 750's GMU fails to come back from runtime suspend on this tablet
# (see github.com/enij90/armada-tb321fu): keep it powered until that is understood.
install -Dm0644 /dev/stdin "$R/usr/lib/systemd/system/steamos-arm-tb321fu-gpu-on.service" <<'UNIT'
[Unit]
Description=Lenovo Legion Y700 Gen 3: keep the GPU powered (its GMU doesn't resume)
ConditionFirmware=device-tree-compatible(lenovo,tb321fu)
Before=display-manager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for d in 3d00000.gpu 3d6a000.gmu; do [ -e /sys/bus/platform/devices/$d/power/control ] && echo on > /sys/bus/platform/devices/$d/power/control; done; exit 0'

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$R/usr/lib/systemd/system/multi-user.target.wants"
ln -sfn ../steamos-arm-tb321fu-gpu-on.service "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tb321fu-gpu-on.service"

# "Safely remove" on a USB drive: udisks unmounts it, then powers the port
# off, and that never returns on this tablet's USB controller: the drive
# stays at "Removing..." and the desktop shell hangs waiting for it.
# Unmounting is all a safe removal needs; skip the power-off here.
install -Dm0644 /dev/stdin "$R/usr/lib/udev/rules.d/90-steamos-arm-tb321fu-usb-storage.rules" <<'RULES'
# Lenovo Legion Y700 Gen 3: no USB power-off on safe removal (it hangs).
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="disk", PROGRAM="/usr/bin/grep -aq lenovo,tb321fu /sys/firmware/devicetree/base/compatible", ENV{UDISKS_CAN_POWER_OFF}="0"
# The internal UFS partitions (Android's and the system's own) out of the
# desktop's Disks & Devices list, where one tap mounts them.
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_PATH}=="*ufs*", PROGRAM="/usr/bin/grep -aq lenovo,tb321fu /sys/firmware/devicetree/base/compatible", ENV{UDISKS_IGNORE}="1"
RULES

# The cameras have no working driver on this kernel (/dev/video* fail with
# ENOMEM) and WirePlumber's v4l2 hook never completes on them, which stalls
# its event queue: no stream gets linked, no sound and no microphone. A
# profile can't be scoped to a device, so a unit gated on the tablet puts the
# override into /etc (the other devices sharing this rootfs never get it).
install -Dm0644 /dev/stdin "$R/usr/share/steamos-arm/tb321fu/52-tb321fu.conf" <<'CONF'
# Lenovo Legion Y700 Gen 3 (steamos-arm-tb321fu-setup.service): the cameras
# stall WirePlumber, and Game Mode has no xdg-desktop-portal.
wireplumber.profiles = {
  main = {
    monitor.v4l2 = disabled
    monitor.libcamera = disabled
    support.portal-permissionstore = disabled
  }
}

# DisplayPort over USB-C: on unplug the DP driver holds the display commit that
# switches back to the panel until the DP audio stream is closed, and
# WirePlumber closes an idle sink only after 5 s: the panel stayed black that
# long. Close an idle DisplayPort sink after 0.5 s (a card profile that names
# its sinks; under pro-audio tb321fu-audio closes the sink itself).
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_output.platform-sound.*DisplayPort.*" } ]
    actions = { update-props = { session.suspend-timeout-seconds = 0.5 } }
  }
]
CONF
install -Dm0644 /dev/stdin "$R/usr/lib/systemd/system/steamos-arm-tb321fu-setup.service" <<'UNIT'
[Unit]
Description=Lenovo Legion Y700 Gen 3: audio server settings for this tablet
ConditionFirmware=device-tree-compatible(lenovo,tb321fu)
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target display-manager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/install -Dm0644 /usr/share/steamos-arm/tb321fu/52-tb321fu.conf /etc/wireplumber/wireplumber.conf.d/52-tb321fu.conf

[Install]
WantedBy=sysinit.target
UNIT
mkdir -p "$R/usr/lib/systemd/system/sysinit.target.wants"
ln -sfn ../steamos-arm-tb321fu-setup.service "$R/usr/lib/systemd/system/sysinit.target.wants/steamos-arm-tb321fu-setup.service"

# USB-C: the UCSI driver probes while the ADSP is still booting, times out
# ("PPM init failed, stop trying") and leaves no Type-C ports, roles or VBUS.
# Bind it again once the ADSP runs.
install -Dm0755 /dev/stdin "$R/usr/lib/steamos-arm/tb321fu-ucsi-rebind" <<'SH'
#!/bin/bash
for i in $(seq 1 60); do
  [ "$(cat /sys/class/remoteproc/remoteproc0/state 2>/dev/null)" = running ] && break
  sleep 1
done
sleep 8
[ -e /sys/class/typec/port0 ] && exit 0
D=/sys/bus/auxiliary/drivers/ucsi_glink.pmic_glink_ucsi
echo pmic_glink.ucsi.0 > $D/unbind 2>/dev/null || true
sleep 1
echo pmic_glink.ucsi.0 > $D/bind
SH
install -Dm0644 /dev/stdin "$R/usr/lib/systemd/system/steamos-arm-tb321fu-usb.service" <<'UNIT'
[Unit]
Description=Lenovo Legion Y700 Gen 3: bind USB-C (UCSI) again once the ADSP is up
ConditionFirmware=device-tree-compatible(lenovo,tb321fu)
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/steamos-arm/tb321fu-ucsi-rebind

[Install]
WantedBy=multi-user.target
UNIT
ln -sfn ../steamos-arm-tb321fu-usb.service "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tb321fu-usb.service"

# The tablet has one USB controller for its two USB-C ports, muxed by TLMM
# GPIO 58 (pmic-glink's c2-select): left alone the data lines stay on the
# long-side charging port, so a controller or hub on the short-side port
# (the data port) was never seen. Hold the line high to route data there.
# gpioset (libgpiod 2) keeps the line for as long as it runs.
install -Dm0755 /dev/stdin "$R/usr/lib/steamos-arm/tb321fu-usb-data-port" <<'SH'
#!/bin/bash
# Lenovo Legion Y700 Gen 3: route USB data to the short-side USB-C port.
chip=$(gpiodetect | awk '/\[f100000\.pinctrl\]/ { print $1; exit }')
[ -n "$chip" ] || { echo "no TLMM gpiochip" >&2; exit 1; }
# A kernel whose UCSI driver takes c2-select-gpios (the 7.2.8 tablet kernel)
# routes the port itself.
if gpioinfo -c "$chip" 58 | grep -q 'consumer='; then
  echo "GPIO 58 is driven by the kernel" >&2
  exit 0
fi
exec gpioset -c "$chip" 58=1
SH
install -Dm0644 /dev/stdin "$R/usr/lib/systemd/system/steamos-arm-tb321fu-usb-data-port.service" <<'UNIT'
[Unit]
Description=Lenovo Legion Y700 Gen 3: USB data on the short-side USB-C port
ConditionFirmware=device-tree-compatible(lenovo,tb321fu)
StartLimitBurst=3
StartLimitIntervalSec=120

[Service]
ExecStart=/usr/lib/steamos-arm/tb321fu-usb-data-port
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
ln -sfn ../steamos-arm-tb321fu-usb-data-port.service "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tb321fu-usb-data-port.service"

# UCSI sets the controller's role from the long-side connector: a charger or
# a PC there turns it into a device and drops whatever is on the data port.
# Put it back to host whenever something is attached to the short side.
install -Dm0755 /dev/stdin "$R/usr/lib/steamos-arm/tb321fu-usb-host" <<'SH'
#!/bin/bash
# Lenovo Legion Y700 Gen 3: host mode while the short-side port has a partner.
role=/sys/class/usb_role/a600000.usb-role-switch/role
[ -e /sys/class/typec/port1-partner ] || exit 0
sleep 2
[ "$(cat "$role")" = host ] || echo host > "$role"
SH
install -Dm0644 /dev/stdin "$R/usr/lib/systemd/system/steamos-arm-tb321fu-usb-host.service" <<'UNIT'
[Unit]
Description=Lenovo Legion Y700 Gen 3: USB host mode for the short-side USB-C port
ConditionFirmware=device-tree-compatible(lenovo,tb321fu)
After=steamos-arm-tb321fu-usb.service

[Service]
Type=oneshot
ExecStart=/usr/lib/steamos-arm/tb321fu-usb-host

[Install]
WantedBy=multi-user.target
UNIT
ln -sfn ../steamos-arm-tb321fu-usb-host.service "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tb321fu-usb-host.service"
install -Dm0644 /dev/stdin "$R/usr/lib/udev/rules.d/91-steamos-arm-tb321fu-usb-host.rules" <<'RULES'
# Lenovo Legion Y700 Gen 3: put host mode back when a USB-C partner or the role changes.
SUBSYSTEM=="typec", KERNEL=="port[01]-partner", ACTION=="add|remove", PROGRAM="/usr/bin/grep -aq lenovo,tb321fu /sys/firmware/devicetree/base/compatible", TAG+="systemd", ENV{SYSTEMD_WANTS}+="steamos-arm-tb321fu-usb-host.service"
SUBSYSTEM=="usb_role", ACTION=="change", PROGRAM="/usr/bin/grep -aq lenovo,tb321fu /sys/firmware/devicetree/base/compatible", TAG+="systemd", ENV{SYSTEMD_WANTS}+="steamos-arm-tb321fu-usb-host.service"
RULES

# The PMIC RTC keeps counting through power-off but holds no offset to wall
# time (the UEFI variable rtc-pm8xxx reads is missing and SDAM 2 on this PMIC
# is only 128 bytes), so every boot started in the past until NTP synced, and
# systemd-tmpfiles then deleted files made before the sync as 28 days old.
# Keep the offset in /var: set the clock from it early, save it again while
# the clock is synchronised.
# Taken from github.com/enij90/armada-tb321fu (its chrony check replaced by
# systemd-timesyncd's).
install -Dm0755 /dev/stdin "$R/usr/lib/steamos-arm/tb321fu-rtc-offset" <<'SH'
#!/bin/bash
#   restore: set the clock from the RTC counter and the saved offset
#   save:    store the offset, only while the clock is synchronised
set -eu
OFFSET_FILE=/var/lib/tb321fu/rtc-offset
rtc=
for n in /sys/class/rtc/rtc*; do
  case "$(cat "$n/name")" in rtc-pm8xxx*) rtc=$n; break ;; esac
done
[ -n "$rtc" ] || { echo "no rtc-pm8xxx device" >&2; exit 1; }
counter=$(cat "$rtc/since_epoch")
case "${1:-}" in
restore)
  [ -s "$OFFSET_FILE" ] || { echo "no saved offset yet"; exit 0; }
  offset=$(cat "$OFFSET_FILE")
  now=$(date +%s)
  want=$((counter + offset))
  if [ "$want" -gt $((now + 2)) ] || [ "$want" -lt $((now - 2)) ]; then
    date -s "@$want" >/dev/null
    echo "clock set from the RTC: $(date -d "@$want" "+%F %T") (was $(date -d "@$now" "+%F %T"))"
  fi
  ;;
save)
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] \
    || { echo "clock not synchronised, offset not saved"; exit 0; }
  mkdir -p "${OFFSET_FILE%/*}"
  echo $(($(date +%s) - counter)) > "$OFFSET_FILE.new"
  mv -f "$OFFSET_FILE.new" "$OFFSET_FILE"
  ;;
*)
  echo "usage: $0 restore|save" >&2
  exit 2
  ;;
esac
SH
install -Dm0644 /dev/stdin "$R/usr/lib/systemd/system/steamos-arm-tb321fu-rtc.service" <<'UNIT'
[Unit]
Description=Lenovo Legion Y700 Gen 3: set the clock from the PMIC RTC and a saved offset
ConditionFirmware=device-tree-compatible(lenovo,tb321fu)
DefaultDependencies=no
RequiresMountsFor=/var/lib/tb321fu
After=local-fs.target
Before=time-set.target sysinit.target systemd-timesyncd.service
Wants=time-set.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/steamos-arm/tb321fu-rtc-offset restore

[Install]
WantedBy=sysinit.target
UNIT
ln -sfn ../steamos-arm-tb321fu-rtc.service "$R/usr/lib/systemd/system/sysinit.target.wants/steamos-arm-tb321fu-rtc.service"
install -Dm0644 /dev/stdin "$R/usr/lib/systemd/system/steamos-arm-tb321fu-rtc-save.service" <<'UNIT'
[Unit]
Description=Lenovo Legion Y700 Gen 3: save the PMIC RTC offset
ConditionFirmware=device-tree-compatible(lenovo,tb321fu)
After=time-sync.target

[Service]
Type=oneshot
ExecStart=/usr/lib/steamos-arm/tb321fu-rtc-offset save
UNIT
install -Dm0644 /dev/stdin "$R/usr/lib/systemd/system/steamos-arm-tb321fu-rtc-save.timer" <<'UNIT'
[Unit]
Description=Lenovo Legion Y700 Gen 3: save the PMIC RTC offset after NTP and every 6 hours
ConditionFirmware=device-tree-compatible(lenovo,tb321fu)

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h

[Install]
WantedBy=timers.target
UNIT
mkdir -p "$R/usr/lib/systemd/system/timers.target.wants"
ln -sfn ../steamos-arm-tb321fu-rtc-save.timer "$R/usr/lib/systemd/system/timers.target.wants/steamos-arm-tb321fu-rtc-save.timer"

# Tell the ABL each boot worked, or it gives up on the slot after 7.
O="${HERE}/../steamos-overlay"
install -Dm0755 "$O/usr/lib/steamos-arm/tablet-boot-ok" "$R/usr/lib/steamos-arm/tablet-boot-ok"
install -Dm0644 "$O/usr/lib/systemd/system/steamos-arm-tablet-boot-ok.service" "$R/usr/lib/systemd/system/steamos-arm-tablet-boot-ok.service"
ln -sfn ../steamos-arm-tablet-boot-ok.service "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tablet-boot-ok.service"
# Charge to 100 % (the battery firmware keeps Android's battery-care limit).
O="${HERE}/../steamos-overlay"
install -Dm0755 "$O/usr/lib/steamos-arm/tablet-charge-full" "$R/usr/lib/steamos-arm/tablet-charge-full"
install -Dm0644 "$O/usr/lib/systemd/system/steamos-arm-tablet-charge-full.service" "$R/usr/lib/systemd/system/steamos-arm-tablet-charge-full.service"
ln -sfn ../steamos-arm-tablet-charge-full.service "$R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tablet-charge-full.service"
# Both Lenovo tablets: start dark and charge when the charger started the
# tablet, keep the brightness across restarts, and put on screen why the
# session didn't start when it doesn't.
for f in tablet-charger-hold tablet-backlight tablet-boot-watch; do
  install -Dm0755 "$O/usr/lib/steamos-arm/$f" "$R/usr/lib/steamos-arm/$f"
done
install -Dm0755 "$O/usr/lib/systemd/system-sleep/steamos-arm-sleep-stats" "$R/usr/lib/systemd/system-sleep/steamos-arm-sleep-stats"
# Asleep or awake, power off before the battery runs flat: a sleeping
# handheld at 0 % browns out and can boot-loop on the charger.
install -Dm0755 "$O/usr/lib/systemd/system-sleep/steamos-arm-low-battery" "$R/usr/lib/systemd/system-sleep/steamos-arm-low-battery"
sed -i -e 's/^PercentageCritical=.*/PercentageCritical=6/' -e 's/^PercentageAction=.*/PercentageAction=4/' \
  -e 's/^CriticalPowerAction=.*/CriticalPowerAction=PowerOff/' "$R/etc/UPower/UPower.conf"
for u in steamos-arm-tablet-charger steamos-arm-tablet-backlight steamos-arm-tablet-boot-watch; do
  install -Dm0644 "$O/usr/lib/systemd/system/$u.service" "$R/usr/lib/systemd/system/$u.service"
  ln -sfn ../$u.service "$R/usr/lib/systemd/system/multi-user.target.wants/$u.service"
done
[[ -f "$R/usr/lib/lv2/dpl.lv2/manifest.ttl" ]] || die "dpl.lv2 (the output limiter) missing from the rootfs"
log "firmware and audio profile installed"
