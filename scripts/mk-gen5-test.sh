#!/bin/bash
# Lenovo Legion Y700 Gen 5 test package, in the build VM:
#
#   mk-gen5-test.sh BASE_USERDATA.simg OUT_DIR N
#
# BASE_USERDATA is a Legion Y700 Gen 4 system (8 Elite rootfs, same as the
# Gen 5's userspace needs) from mk-tablet-flash-images / the Gen 4 test
# builds. Builds our Gen 5 kernel, turns that system into the Gen 5 one
# (install-baldur.sh) and writes:
#   steamos-gen5-card.img  GPT: steamos-gen5-logs (FAT, 256 MiB: firmware,
#                          the Android image hash, boot logs) + steamos-gen5
#                          (ext4, the system; grows to the card on first boot)
#   Image-gen5             the kernel (the installer packs it into the owner's
#                          own boot image)
#   install-gen5.sh, boot-repack.py, firmware.tsv, switch-to-steamos/
# Env: KO (kernel output; SKIP_KERNEL=1 uses one already built), LAD, M, CPIO,
# ARCHIVE (archive name; default ...-v1.3.0-test<N>.7z) and ARCHIVE_DIR (where
# it goes; default next to OUT_DIR).
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${1:?base userdata.simg}"; O="${2:?out dir}"; N="${3:?test number}"
KO="${KO:-/work/kernel-baldur/kout}"; LAD="${LAD:-/work/kernel-baldur/ladspa}"; M="${M:-/mnt/gen5}"
fail() { echo "CHECK FAILED: $*"; mountpoint -q $M && umount $M; exit 1; }
umount $M 2>/dev/null || true; mkdir -p $M
cd "$SRC"

echo "== kernel $(date +%T)"
cpio="${CPIO:-/work/kernel-elden/initramfs/initrd.cpio}"
grep -aq "microSD dual boot" "$cpio" || fail "initramfs without root=/dev support (rebuild kernel-elden first)"
if [ -z "${SKIP_KERNEL:-}" ]; then
  bash scripts/build-baldur-kernel.sh $KO "$cpio" > /work/kbaldur.log 2>&1 || { tail -40 /work/kbaldur.log; fail "kernel"; }
fi
kr=$(basename "$(ls -d $KO/modules/*)")
grep -aq "root=PARTLABEL=steamos-gen5" $KO/boot/Image || fail "cmdline"

echo "== speaker filter plugins $(date +%T)"
rm -rf $LAD; mkdir -p $LAD
docker run --rm -v $LAD:/out ubuntu:24.04 bash -c '
  set -e; apt-get -qq update >/dev/null; cd /tmp && apt-get -qq download swh-plugins >/dev/null
  dpkg-deb -x swh-plugins_*.deb x; cp x/usr/lib/ladspa/sc4_1882.so x/usr/lib/ladspa/fast_lookahead_limiter_1913.so /out/'
[ -s $LAD/sc4_1882.so ] && [ -s $LAD/fast_lookahead_limiter_1913.so ] || fail "ladspa"

echo "== system $(date +%T)"
# CHECKS_ONLY=1: the system in $O/fs.img is already done, start at the checks.
if [ -z "${CHECKS_ONLY:-}" ]; then
rm -rf "$O"; mkdir -p "$O"
simg2img "$BASE" "$O/fs.img"
mount -o loop "$O/fs.img" $M
R=$M
bash scripts/install-baldur.sh $R $KO $LAD
# What changed for the tablets since the base was built.
OV=steamos-overlay
install -m0755 $OV/usr/lib/steamos/gamescope-session $R/usr/lib/steamos/gamescope-session
install -m0755 $OV/usr/bin/steamos-session-select $R/usr/bin/steamos-session-select
install -m0755 sm8750-overlay/usr/lib/odin3/odin3d $R/usr/lib/odin3/odin3d
install -m0644 $OV/usr/lib/systemd/system/steamos-arm-tablet-sd-grow.service $OV/usr/lib/systemd/system/steamos-arm-tablet-charge-full.service $R/usr/lib/systemd/system/
# All eight cores for Steam, games and services (issue #63) and Discover
# without its PackageKit backend (issue #64), as in apply-overlays-sm8750.sh.
for f in usr/lib/systemd/user.conf.d/60-sm8550-cpu-affinity.conf \
         usr/lib/systemd/system.conf.d/60-sm8550-cpu-affinity.conf \
         usr/lib/systemd/user/steam.service.d/70-sm8550-cpu-affinity.conf; do
  install -Dm0644 sm8550-image-overlay/$f $R/$f
done
rm -f $R/usr/lib/qt6/plugins/discover/packagekit-backend.so
# Brightness kept across restarts, a report on screen when the session never
# starts, and sleep statistics in the journal (as on the Gen 3 and Gen 4).
for f in tablet-backlight tablet-boot-watch; do
  install -Dm0755 $OV/usr/lib/steamos-arm/$f $R/usr/lib/steamos-arm/$f
done
install -Dm0755 $OV/usr/lib/systemd/system-sleep/steamos-arm-sleep-stats $R/usr/lib/systemd/system-sleep/steamos-arm-sleep-stats
# Asleep or awake, power off before the battery runs flat: a sleeping
# handheld at 0 % browns out and can boot-loop on the charger.
install -Dm0755 "$OV/usr/lib/systemd/system-sleep/steamos-arm-low-battery" "$R/usr/lib/systemd/system-sleep/steamos-arm-low-battery"
sed -i -e 's/^PercentageCritical=.*/PercentageCritical=6/' -e 's/^PercentageAction=.*/PercentageAction=4/' \
  -e 's/^CriticalPowerAction=.*/CriticalPowerAction=PowerOff/' "$R/etc/UPower/UPower.conf"
# Started by its charger while off: stay dark and charge (the bootloader's
# androidboot.mode=charger, read from bootconfig).
install -Dm0755 $OV/usr/lib/steamos-arm/tablet-charger-hold $R/usr/lib/steamos-arm/tablet-charger-hold
for u in steamos-arm-tablet-backlight steamos-arm-tablet-boot-watch steamos-arm-tablet-charger; do
  install -Dm0644 $OV/usr/lib/systemd/system/$u.service $R/usr/lib/systemd/system/$u.service
  ln -sfn ../$u.service $R/usr/lib/systemd/system/multi-user.target.wants/$u.service
done
# Return to Gaming Mode saves Game Mode as the default and ignores a second tap (BUGS S28).
install -m0644 $OV/etc/skel/Desktop/Return.desktop $R/etc/skel/Desktop/Return.desktop
install -m0644 $OV/etc/skel/Desktop/Return.desktop $R/usr/share/applications/steamos-gamemode.desktop
install -Dm0755 $OV/etc/skel/Desktop/Return.desktop $R/home/steamos/Desktop/Return.desktop
chown -R 1000:1000 $R/home/steamos/Desktop
# zram, swappiness, TEO, remote play buffer, backlight untag (the 8 Elite
# base never had them).
for f in usr/lib/systemd/zram-generator.conf.d/60-steamos-arm-zram.conf \
         usr/lib/tmpfiles.d/steamos-arm-cpuidle-teo.conf \
         usr/lib/sysctl.d/60-steamos-arm-net-rmem.conf \
         usr/lib/sysctl.d/61-steamos-arm-zram.conf \
         usr/lib/udev/rules.d/99-zz-steamos-arm-backlight-untag.rules; do
  install -Dm0644 $OV/$f $R/$f
done
HC=$(find $M -maxdepth 6 -type d -path "*homebrew/plugins/konkr-control" | head -1)
[ -n "$HC" ] || fail "Handheld Control"
install -m0644 external-and-mods/Decky/sm8650/konkr-control/main.py $HC/main.py
install -m0644 external-and-mods/Decky/sm8650/konkr-control/dist/index.js $HC/dist/index.js
chown -R 1000:1000 $HC
else
mount -o loop "$O/fs.img" $M; R=$M
OV=steamos-overlay
HC=$(find $M -maxdepth 6 -type d -path "*homebrew/plugins/konkr-control" | head -1)
fi
echo "== check"
[ -f $R/usr/lib/modules/$kr/modules.dep ] && ls $R/usr/lib/modules/$kr/extra/*aw882xx* >/dev/null || fail "modules"
[ "$(ls $R/usr/lib/modules)" = "$kr" ] || fail "other kernels' modules left"
grep -q steamos-gen5 $R/etc/fstab || fail "fstab"
for u in steamos-arm-gen5-firstboot steamos-arm-gen5-emergency-key steamos-arm-tablet-sd-grow; do
  ls $R/usr/lib/systemd/system/*.wants/$u.service >/dev/null 2>&1 || fail "$u not enabled"
done
for u in tb323fu-dsp tb323fu-audio tb323fu-gen-ids tb323fu-btaddr tb323fu-usb-port; do
  [ "$(readlink $R/etc/systemd/system/multi-user.target.wants/$u.service)" = /usr/lib/systemd/system/$u.service ] && [ -f $R/usr/lib/systemd/system/$u.service ] || fail "$u not enabled"
done
[ -f $R/usr/share/alsa/ucm2/Lenovo/TB323FU/HiFi.conf ] && [ -f $R/usr/share/pipewire/pipewire.conf.d/60-tb323fu-speakers.conf ] || fail "audio platform files"
[ -f $R/usr/lib/ladspa/sc4_1882.so ] && [ -f $R/usr/lib/firmware/qcom/kaanapali/LENOVO-TB323FU-tplg.bin ] || fail "speaker filter / topology"
[ "$(readlink $R/etc/systemd/system/rmtfs.service)" = /dev/null ] || fail "modem not masked"
grep -q 'GAMESCOPE_ORIENTATION=right' $R/etc/systemd/user/gamescope-session.service.d/99-zz-gen5.conf || fail "orientation"
grep -q baldur $R/usr/bin/steamos-session-select && grep -q baldur $R/usr/lib/steamos/gamescope-session && grep -q gen5 $HC/main.py || fail "tablet integration"
[ -x $R/usr/lib/steamos-arm/gen5-android ] && [ -x $R/usr/lib/hwsupport/steamos-powerbuttond ] || fail "switching / power button"
chroot $R sh -c 'command -v sfdisk && command -v partx && command -v resize2fs && command -v pkexec' >/dev/null || fail "tools"
chroot $R sh -c 'command -v flock && command -v pactl && gpioget --help 2>&1 | grep -q -- --numeric && gpioget --help 2>&1 | grep -q -- --as-is' >/dev/null || fail "USB-C routing / speaker gain tools"
grep -q "CPUAffinity=0-7" $R/usr/lib/systemd/user.conf.d/60-sm8550-cpu-affinity.conf && grep -q "0xff" $R/usr/lib/systemd/user/steam.service.d/70-sm8550-cpu-affinity.conf || fail "cpu affinity"
[ ! -e $R/usr/lib/qt6/plugins/discover/packagekit-backend.so ] || fail "Discover PackageKit backend"
grep -q "lenovo,baldur" $R/usr/lib/systemd/system/steamos-arm-tablet-boot-watch.service && grep -q "lenovo,baldur" $R/usr/lib/systemd/system/steamos-arm-tablet-backlight.service || fail "boot watch / backlight not for Gen 5"
grep -q "lenovo,baldur" $R/usr/lib/systemd/system/steamos-arm-tablet-charger.service && [ -x $R/usr/lib/steamos-arm/tablet-charger-hold ] && [ -L $R/usr/lib/systemd/system/multi-user.target.wants/steamos-arm-tablet-charger.service ] || fail "charger hold not for Gen 5"
grep -q " bootconfig\"" $SRC/external-and-mods/kernel-baldur/steamos.config && grep -aq "steamos-gen5-logs bootconfig" $KO/boot/Image || fail "bootconfig not on the kernel command line"
grep -q "^Name=wlan0$" $R/usr/libexec/tb323fu/tb323fu-gen-ids || fail "Wi-Fi not named wlan0"
grep -q "def rescan" $R/usr/lib/steamos-arm/gen5-emergency-key || fail "emergency key rescans"
grep -q host-reconcile $R/usr/libexec/tb323fu/tb323fu-usb-port && [ -f $R/usr/lib/udev/rules.d/71-tb323fu-usb-host.rules ] || fail "USB-C routing"
grep -q fail_safe $R/usr/libexec/tb323fu/tb323fu-speaker-gain || fail "speaker gain"
[ -f $R/usr/share/inputplumber/devices/05-lenovo-tb323fu-legion-g9-2026.yaml ] && [ -f $R/usr/share/inputplumber/capability_maps/lenovo_legion_g9_2026.yaml ] || fail "G9 2026"
grep -q "compression-algorithm = zstd" $R/usr/lib/systemd/zram-generator.conf.d/60-steamos-arm-zram.conf && grep -q "swappiness = 150" $R/usr/lib/sysctl.d/61-steamos-arm-zram.conf || fail "zram"
grep -q qdbus6 $R/home/steamos/Desktop/Return.desktop && grep -q qdbus6 $R/usr/share/applications/steamos-gamemode.desktop || fail "Return to Gaming Mode"
[ -L $R/etc/systemd/system/multi-user.target.wants/inputplumber.service ] || [ -L $R/usr/lib/systemd/system/multi-user.target.wants/inputplumber.service ] || fail "InputPlumber not enabled"
echo "system checks ok"
sync; umount $M
e2fsck -fy "$O/fs.img" || [ $? -le 1 ]
resize2fs -M "$O/fs.img" >/dev/null
fsb=$(stat -c %s "$O/fs.img")

echo "== card image $(date +%T)"
img="$O/steamos-gen5-card.img"
truncate -s $(( 1048576 + 256*1048576 + fsb + 2*1048576 )) "$img"
sgdisk -o -n 1:2048:+256M -t 1:0700 -c 1:steamos-gen5-logs -n 2:0:+$(( fsb / 1024 ))K -t 2:8300 -c 2:steamos-gen5 "$img" >/dev/null
LP=$(losetup -fP --show "$img")
mkfs.vfat -F 32 -n GEN5LOGS ${LP}p1 >/dev/null
dd if="$O/fs.img" of=${LP}p2 bs=4M conv=sparse status=none
e2fsck -fn ${LP}p2 >/dev/null || { losetup -d $LP; fail "card system partition"; }
losetup -d $LP; rm -f "$O/fs.img"
sgdisk -p "$img" | tail -3

echo "== package $(date +%T)"
cp $KO/boot/Image "$O/Image-gen5"
cp scripts/gen5/install-gen5.sh scripts/gen5/boot-repack.py external-and-mods/baldur/firmware.tsv "$O/"
cp -r external-and-mods/baldur/switch-to-steamos "$O/"
cd "$O"; sha256sum Image-gen5 steamos-gen5-card.img > SHA256SUMS; cat SHA256SUMS
f="${ARCHIVE:-steamos-arm-port-lenovo-legion-y700-gen5-v1.3.0-test$N.7z}"
AD="${ARCHIVE_DIR:-..}"; mkdir -p "$AD"; AD=$(cd "$AD" && pwd)
rm -f "$AD/$f"; 7z a -mx=3 -mmt=8 "$AD/$f" Image-gen5 steamos-gen5-card.img install-gen5.sh boot-repack.py firmware.tsv switch-to-steamos SHA256SUMS >/dev/null
cd "$AD"; sha256sum $f | tee $f.sha256; ls -l $f
echo "==> done $(date +%T)"
