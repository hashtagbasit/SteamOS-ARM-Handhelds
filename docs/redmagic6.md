# REDMAGIC 6 (Snapdragon 888 / SM8350)

Experimental port to the REDMAGIC 6 (Nubia NX669J), built for the North
American / global model (NX669J-UN firmware). It is a phone, not a handheld
like the other devices here, so a few things work differently:

- **No SD card slot.** Zaviya replaces Android on the internal storage (the
  `userdata` partition). Installing it erases the phone.
- **Nubia's own bootloader** (unlocked) boots it from the `boot` and
  `vendor_boot` partitions. There is no OpenABL and no device menu.
- **No built-in gamepad.** Use a Bluetooth or USB controller. The capacitive
  shoulder triggers show up as their own input devices (4 zones).
- **No release image.** Nubia's firmware cannot be redistributed, so you
  build the kit yourself from Nubia's OTA and a Zaviya release (below).

> [!WARNING]
> Tested on one NX669J-UN only. Game Mode, Wi-Fi, Bluetooth pads, speakers,
> sleep and charging work there, but expect rough edges.

## Build

Everything here runs on an x86_64 or arm64 Linux PC with ~40 GB free on a
Linux filesystem. You need the stock firmware zip for your phone
(`NX669J-update.zip`, Nubia's full OTA for the NX669J-UN).

```bash
export STEAMOS_WORK=/work

# 1. Firmware (DSPs, GPU zap, Wi-Fi/BT, RGB effects) + stock vbmeta/boot/dtbo images
scripts/extract-nx669j-firmware.sh NX669J-update.zip

# 2. Kernel: mainline 7.1.2 + external-and-mods/kernel-sm8350/patches
#    (cross-compiles on x86: aarch64-linux-gnu-gcc)
external-and-mods/kernel-sm8350/build.sh

# 3. The kit, from a release's rootfs (it is the same on every chip)
./make-steamos-sm8350.sh --from-img zaviya-v1.2.img
```

Instead of a release, step 3 can take the rootfs `make-steamos-sm8650.sh`
built (`./make-steamos-sm8350.sh`, default `$STEAMOS_WORK/rootfs`, see
[building.md](building.md)). Either way the source is copied to
`$STEAMOS_WORK/rootfs-sm8350` first and never changed.

The kit lands in `$STEAMOS_WORK/steamos-sm8350-redmagic6/`: `boot.img`,
`vendor_boot.img`, `vendor_boot-debug.img`, `userdata.img`, `vbmeta.img` and
the flash scripts.

## 1. Test boot

Power off, hold **Volume Down + Power** until the fastboot screen, connect USB.

Nubia's bootloader does not start images sent with `fastboot boot` (it
answers OKAY and stays in fastboot), and it only boots its own layout: the
kernel in `boot`, the devicetree and initramfs in `vendor_boot`. So the test
uses slot b and leaves `userdata` alone:

```bash
fastboot flash vbmeta_b vbmeta.img          # verification off (kit's copy)
fastboot erase dtbo_b                       # no overlays: they break a mainline DTB
fastboot flash boot_b boot.img
fastboot flash vendor_boot_b vendor_boot-debug.img
fastboot --set-active=b
fastboot reboot
```

If it comes straight back to fastboot (about 15 s), the bootloader refused
the image. `vendor_boot-debug.img` boots with a verbose console and, when it
finds no Zaviya on `userdata` (expected on this first try), opens a debug
shell over USB:

- a serial port (`/dev/ttyACM0` on Linux, a COM port on Windows): e.g.
  `screen /dev/ttyACM0 115200` or PuTTY
- a USB network interface: set the PC side to `172.16.42.2/24`, then
  `telnet 172.16.42.1`

In there, `dmesg` shows what came up. Useful checks:

```sh
cat /proc/cmdline | tr ' ' '\n' | grep msm_drm   # which panel ABL found
ls /sys/class/block/ | grep sd                    # UFS LUNs
```

Please send that log (or open an issue with it) if something is off. Back to
Android from here: `fastboot --set-active=a` (slot a was not touched).

## 2. Install

This erases Android and everything on the phone.

```bash
./flash-redmagic6.sh              # Linux / macOS
flash-redmagic6.bat               # Windows
```

It flashes `vbmeta` with verification off, erases `dtbo`, writes `boot.img`
and `vendor_boot.img` to both slots and `userdata.img` to `userdata`, then
reboots. The first boot takes a few minutes while the filesystem grows to the
whole partition. Boot logs go to `/var/log/steamos-arm-boot/`, and
`vendor_boot-debug.img` in place of `vendor_boot.img` gives the USB shell
again.

## Back to Android

Flash Nubia's full OTA from the recovery or with a tool that writes all
partitions from `payload.bin`, or put the stock images back from
`$STEAMOS_WORK/nx669j-firmware.stock/`:

```bash
fastboot flash boot_a boot.img && fastboot flash boot_b boot.img
fastboot flash vendor_boot_a vendor_boot.img && fastboot flash vendor_boot_b vendor_boot.img
fastboot flash dtbo_a dtbo.img && fastboot flash dtbo_b dtbo.img
fastboot flash vbmeta_a vbmeta.img && fastboot flash vbmeta_b vbmeta.img
fastboot -w                      # userdata back to empty, Android formats it
```

The `system`/`vendor` partitions are never touched by this port, so that is
enough if Android was installed before.

## How it works

- **Kernel** (`external-and-mods/kernel-sm8350/`): mainline Linux 7.1.2 on the
  arm64 defconfig. The patches add the NX669J devicetree and the drivers the
  phone needs that mainline lacks: the AMOLED panels, the fan MCU, the RGB
  light, the shoulder triggers, the MAX98937 amps and GT9897 touch over I2C.
  Values come from Nubia's stock DT and kernel source
  ([ztemt/NX669J-kernel](https://github.com/ztemt/NX669J-kernel));
  `tools/gen-panel-seq.py` turns the panel init sequences from the stock dtbo
  into C tables.
- **Boot**: Nubia's layout (`mkbootimg-v3.py`): the kernel in a v3 `boot`,
  the DTB, initramfs and cmdline in a v3 `vendor_boot`. With a valid `dtbo`
  the ABL overlays Nubia's board dtbo and the Haven hypervisor's overlays onto
  the DTB (libufdt), which fails on a mainline tree, so `dtbo` is erased; the
  ABL then matches the DTB by msm-id and the board's (unpublished) board-id,
  hence one DTB copy per board-id of the stock dtbo (`soc.env` BOARD_IDS).
  The busybox initramfs is shared with the other chips and mounts
  `PARTLABEL=userdata` (`steamos.root=`, because ABL appends its own `root=`).
- **Display**: 144/120/90/60 Hz are separate modes with their own init
  sequences (command-mode panel), so changing the rate is a full modeset.
  The panel is portrait; the DT `rotation = <270>` makes gamescope run Game
  Mode in landscape, like on the Steam Deck.
- **Userspace**: the shared rootfs plus `sm8350-overlay`
  (`scripts/apply-overlays-sm8350.sh`); the shared scripts that know about
  the phone match the DT model "REDMAGIC 6".
