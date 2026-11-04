#!/bin/bash
# Lenovo Legion Y700 Gen 5 (TB323FU, board "baldur") support in a copy of the
# 8 Elite rootfs: our kernel's modules, the board's platform files, our
# switching between Android and SteamOS, and the Game Mode setup for this panel.
#
#   install-baldur.sh ROOTFS KERNEL_OUT LADSPA_DIR
#
# KERNEL_OUT is build-baldur-kernel.sh's output; LADSPA_DIR holds the
# swh-plugins sc4 and fast lookahead limiter (aarch64) for the speaker filter.
# The platform files (udev, audio/UCM, the speaker protection filter, DSP
# start, Bluetooth/Wi-Fi addresses, USB-C port routing, watchdog) come from
# github.com/joonhoekim/tb323fu-linux userspace/platform (MIT; UCM BSD-3),
# pinned with the kernel in external-and-mods/kernel-baldur/release.env.
# The tablet's firmware is not here: the installer copies it out of the
# tablet's own Android (gen5-firstboot puts it in place).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
source "$ROOT/external-and-mods/kernel-baldur/release.env"
R="$(readlink -f "${1:?rootfs}")"; KO="$(readlink -f "${2:?kernel out}")"; LADSPA="$(readlink -f "${3:?ladspa dir}")"
CACHE="${CACHE:-/work/kernel-baldur/cache}"
OV="$ROOT/steamos-overlay"
die() { echo "[baldur] ERROR: $*" >&2; exit 1; }
log() { echo "[baldur] $*"; }
mask() { for u in "$@"; do rm -f "$R/etc/systemd/system/$u"; ln -sfn /dev/null "$R/etc/systemd/system/$u"; done; }

# Kernel modules: only ours (the 8 Elite / Gen 4 ones belong to other kernels).
kr=$(basename "$(ls -d "$KO"/modules/*)")
for d in "$R"/usr/lib/modules/*; do [[ "$(basename "$d")" == "$kr" ]] || rm -rf "$d"; done
cp -a "$KO/modules/$kr" "$R/usr/lib/modules/$kr"
chroot "$R" depmod -a "$kr"
rm -f "$R"/boot/KERNEL*
log "modules $kr"
# The Frame's ath12k option (its VR link's RX reorder timeout) isn't a
# parameter of this ath12k: an empty file of the same name replaces it.
: > "$R/etc/modprobe.d/ath12k.conf"
# Modules this kernel doesn't have: a same-named file in /etc without them,
# so systemd-modules-load doesn't fail.
for f in "$R"/usr/lib/modules-load.d/*.conf; do
  [[ -e "$f" && ! -e "$R/etc/modules-load.d/$(basename "$f")" ]] || continue
  keep=""; drop=""
  for m in $(grep -v '^[#;]' "$f"); do
    if chroot "$R" modprobe -n -q -S "$kr" "$m" 2>/dev/null; then keep+=" $m"; else drop+=" $m"; fi
  done
  [[ -n "$drop" ]] || continue
  mkdir -p "$R/etc/modules-load.d"
  { echo "# Legion Y700 Gen 5: not in kernel $kr:$drop"; for m in $keep; do echo "$m"; done; } > "$R/etc/modules-load.d/$(basename "$f")"
done

# Platform files, from the pinned board project.
port="$CACHE/tb323fu-linux-${BALDUR_PORT_COMMIT}.tar.gz"
[[ -s "$port" ]] || curl -fsSL --retry 3 -o "$port" "$BALDUR_PORT_URL"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
tar -xzf "$port" -C "$W" --strip-components=1
CC=/nonexistent DESTDIR="$R" sh "$W/userspace/platform/install.sh" >/dev/null 2>&1 || die "platform install.sh failed"
# Our own way back to Android and its key chord instead of theirs (they look
# for their own partitions); no kernel trials (the boot image is the owner's).
rm -f "$R/usr/sbin/back-to-android" "$R"/usr/lib/systemd/system/tb323fu-emergency-key.service \
  "$R"/usr/lib/systemd/system/tb323fu-kernel-confirm.service "$R/usr/libexec/tb323fu/tb323fu-emergency-key" \
  "$R/usr/libexec/tb323fu/tb323fu-kernel-confirm"
# Their per-install Wi-Fi MAC .link replaces 99-sm8550-wlan0.link and kept
# the kernel's name wlp1s0; Steam, steamos-manager and our Wi-Fi scripts look
# for wlan0 (test 3: a saved network wasn't joined again after a restart).
# Same fixed MAC, our name.
G="$R/usr/libexec/tb323fu/tb323fu-gen-ids"
grep -q '^NamePolicy=keep kernel database onboard slot path$' "$G" || die "tb323fu-gen-ids changed upstream"
sed -i -e 's/^NamePolicy=keep kernel database onboard slot path$/Name=wlan0/' \
  -e '/^AlternativeNamesPolicy=database onboard slot path$/d' \
  -e 's/so its naming is repeated here to keep the name wlp1s0\./so it names the card wlan0 as SteamOS expects./' "$G"
grep -q '^Name=wlan0$' "$G" || die "wlan0 name not set in tb323fu-gen-ids"
W2="$R/etc/systemd/system"
mkdir -p "$W2/multi-user.target.wants" "$W2/sysinit.target.wants" "$R/etc/systemd/user/default.target.wants"
for u in tb323fu-gen-ids tb323fu-btaddr tb323fu-dsp tb323fu-audio tb323fu-usb-port; do
  [[ -f "$R/usr/lib/systemd/system/$u.service" ]] || die "platform unit $u missing"
  ln -sfn "/usr/lib/systemd/system/$u.service" "$W2/multi-user.target.wants/$u.service"
done
[[ -f "$R/usr/lib/systemd/user/tb323fu-speaker-gain.service" ]] || die "speaker gain unit missing"
ln -sfn /usr/lib/systemd/user/tb323fu-speaker-gain.service "$R/etc/systemd/user/default.target.wants/tb323fu-speaker-gain.service"
# The speaker protection filter's LADSPA plugins (without them the filter,
# and PipeWire with it, fail).
mkdir -p "$R/usr/lib/ladspa"
for f in sc4_1882.so fast_lookahead_limiter_1913.so; do
  [[ -s "$LADSPA/$f" ]] || die "no $LADSPA/$f"
  install -m0644 "$LADSPA/$f" "$R/usr/lib/ladspa/$f"
done
# The audio topology (generated, in the board project).
install -Dm0644 "$W/firmware/audio/LENOVO-TB323FU-tplg.bin" "$R/usr/lib/firmware/qcom/kaanapali/LENOVO-TB323FU-tplg.bin"
# Newer than the board project's (external-and-mods/baldur/rootfs, from
# github.com/mydanyi/armadaos-freedom): USB-C routing that keeps a real host
# (dock, PC) on the controller and doesn't drop a pad on the side port when
# a charger goes in the bottom one, plus a re-check on every role change;
# speaker gain that waits for the sound card and falls back to the safe
# attenuation on any failure; the Legion G9 2026 controller (3537:1136) for
# InputPlumber.
B="$ROOT/external-and-mods/baldur/rootfs"
install -m0755 "$B"/usr/libexec/tb323fu/tb323fu-usb-port "$B"/usr/libexec/tb323fu/tb323fu-speaker-gain "$R/usr/libexec/tb323fu/"
install -Dm0644 "$B/usr/lib/udev/rules.d/71-tb323fu-usb-host.rules" "$R/usr/lib/udev/rules.d/71-tb323fu-usb-host.rules"
install -Dm0644 "$B/usr/lib/systemd/user/tb323fu-speaker-gain.service" "$R/usr/lib/systemd/user/tb323fu-speaker-gain.service"
install -Dm0644 "$B/usr/share/inputplumber/devices/05-lenovo-tb323fu-legion-g9-2026.yaml" "$R/usr/share/inputplumber/devices/05-lenovo-tb323fu-legion-g9-2026.yaml"
install -Dm0644 "$B/usr/share/inputplumber/capability_maps/lenovo_legion_g9_2026.yaml" "$R/usr/share/inputplumber/capability_maps/lenovo_legion_g9_2026.yaml"
# Clock from the PMIC RTC plus a saved offset (it showed Jan 06 until NTP),
# and tb323fu-btaddr started by udev when hci0 appears (its hci0.device wait
# timed out at boot).
install -Dm0755 "$B/usr/lib/steamos-arm/baldur-rtc-offset" "$R/usr/lib/steamos-arm/baldur-rtc-offset"
for u in steamos-arm-baldur-rtc.service steamos-arm-baldur-rtc-save.service steamos-arm-baldur-rtc-save.timer; do
  install -Dm0644 "$B/usr/lib/systemd/system/$u" "$R/usr/lib/systemd/system/$u"
done
ln -sfn ../steamos-arm-baldur-rtc.service "$R/usr/lib/systemd/system/sysinit.target.wants/steamos-arm-baldur-rtc.service" 2>/dev/null \
  || { mkdir -p "$R/usr/lib/systemd/system/sysinit.target.wants"; ln -sfn ../steamos-arm-baldur-rtc.service "$R/usr/lib/systemd/system/sysinit.target.wants/steamos-arm-baldur-rtc.service"; }
mkdir -p "$R/usr/lib/systemd/system/timers.target.wants"
ln -sfn ../steamos-arm-baldur-rtc-save.timer "$R/usr/lib/systemd/system/timers.target.wants/steamos-arm-baldur-rtc-save.timer"
install -Dm0644 "$B/usr/lib/systemd/system/tb323fu-btaddr.service.d/10-steamos-arm.conf" "$R/usr/lib/systemd/system/tb323fu-btaddr.service.d/10-steamos-arm.conf"
install -Dm0644 "$B/usr/lib/udev/rules.d/72-steamos-arm-btaddr.rules" "$R/usr/lib/udev/rules.d/72-steamos-arm-btaddr.rules"
log "platform files"

# Switching, firmware from the card, growing to the card.
for f in gen5-android gen5-emergency-key gen5-firstboot tablet-sd-grow tablet-charge-full; do
  install -Dm0755 "$OV/usr/lib/steamos-arm/$f" "$R/usr/lib/steamos-arm/$f"
done
mkdir -p "$R/usr/lib/systemd/system/sysinit.target.wants" "$R/usr/lib/systemd/system/multi-user.target.wants"
for u in steamos-arm-gen5-firstboot.service; do
  install -Dm0644 "$OV/usr/lib/systemd/system/$u" "$R/usr/lib/systemd/system/$u"
  ln -sfn "../$u" "$R/usr/lib/systemd/system/sysinit.target.wants/$u"
done
for u in steamos-arm-gen5-emergency-key.service steamos-arm-tablet-sd-grow.service steamos-arm-tablet-charge-full.service; do
  install -Dm0644 "$OV/usr/lib/systemd/system/$u" "$R/usr/lib/systemd/system/$u"
  ln -sfn "../$u" "$R/usr/lib/systemd/system/multi-user.target.wants/$u"
done

# What doesn't exist here or must not run: the Frame's and the Odin 3's own
# hardware services, SteamOS's partition-set plumbing (home and EFI by
# partition set, the offload mounts, repart, the grow-home job), and the
# modem (rmtfs starts it, it crashes and resets the whole SoC).
mask sm8750-audio-setup.service deckard-audio-setup.service deckard-fan-control.service \
  deckard-fpga-resume.service deckard-charger.service deckard-power-monitor.service setubootenv.service \
  softapmanager.service steam-video-codec-setup.service steamos-boot.service steamos-sm8550-expand-home.service \
  home.mount efi.mount esp.mount steamos-offload.target systemd-repart.service \
  rmtfs.service tqftpserv.service ModemManager.service
for u in "$R"/usr/lib/systemd/system/steamos-offload.target.wants/*.mount "$R"/etc/systemd/system/steamos-offload.target.wants/*.mount; do
  [[ -e "$u" || -L "$u" ]] && mask "$(basename "$u")"
done
mkdir -p "$R/var/lib/steamos-sm8550"; touch "$R/var/lib/steamos-sm8550/home-expanded"

# System and /home in one partition on the microSD card.
FSTAB='# Lenovo Legion Y700 Gen 5: system and /home on the microSD card
PARTLABEL=steamos-gen5  /  ext4  defaults,noatime,x-systemd.growfs  0 1
'
printf '%s' "$FSTAB" > "$R/etc/fstab"
[[ -d "$R/var/lib/overlays/etc/upper" ]] && printf '%s' "$FSTAB" > "$R/var/lib/overlays/etc/upper/fstab"
echo legion-y700-gen5 > "$R/etc/hostname"

# Game Mode on the portrait panel (1904x3040): gamescope's rotation shader
# turns it right, after the Odin 3's drop-in (99-odin3), and touch, which the
# shader doesn't turn, gets a libinput matrix (measured for "right" on the
# tablet by the board project). Flip screen (Handheld Control) turns both
# the other way; KWin maps touch itself in Desktop Mode.
mkdir -p "$R/etc/systemd/user/gamescope-session.service.d"
printf '[Service]\nEnvironment=GAMESCOPE_ORIENTATION=right\n' > "$R/etc/systemd/user/gamescope-session.service.d/99-zz-gen5.conf"
install -Dm0644 /dev/stdin "$R/usr/lib/udev/rules.d/90-steamos-arm-gen5-touch.rules" <<'RULES'
# Lenovo Legion Y700 Gen 5: Game Mode runs the portrait panel landscape ("right").
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NVTCapacitiveTouchScreen|NVTCapacitivePen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 1 0 -1 0 1"
# Screen flipped 180 degrees (Handheld Control, /etc/steamos-arm/flip-screen): the other landscape.
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="NVTCapacitiveTouchScreen|NVTCapacitivePen", TEST=="/etc/steamos-arm/flip-screen", ENV{LIBINPUT_CALIBRATION_MATRIX}="0 -1 1 1 0 0"
RULES
grep -qs 'Legion Y700 Gen 5' "$R/etc/xdg/kcminputrc" || cat >> "$R/etc/xdg/kcminputrc" <<'KCM'
# Lenovo Legion Y700 Gen 5 touch: udev rotates it for gamescope, KWin rotates it itself.
[Libinput][0][0][NVTCapacitiveTouchScreen]
CalibrationMatrix=1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1

[Libinput][0][0][NVTCapacitivePen]
CalibrationMatrix=1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1
KCM

# Power button: the Frame's steamos-powerbuttond only starts next to SteamVR
# (Requisite=steamvr.service), so the button did nothing in Game Mode.
# Replace it, started with Game Mode (found by the board project).
install -Dm0644 /dev/stdin "$R/etc/systemd/user/steamos-powerbuttond.service" <<'UNIT'
# Legion Y700 Gen 5: replaces the Frame's unit (SteamVR only).
[Unit]
Description=Power Button daemon for SteamOS
PartOf=gamescope-session.target
After=gamescope-session.service

[Service]
ExecStart=/usr/lib/hwsupport/steamos-powerbuttond
Restart=on-failure
Slice=session.slice

[Install]
WantedBy=gamescope-session.target
UNIT
mkdir -p "$R/etc/systemd/user/gamescope-session.target.wants"
ln -sfn ../steamos-powerbuttond.service "$R/etc/systemd/user/gamescope-session.target.wants/steamos-powerbuttond.service"

python3 "$OV/usr/lib/steamos-arm/os-release-version" "$R"
log "done"
