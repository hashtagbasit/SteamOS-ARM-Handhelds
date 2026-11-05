# SteamOS boot menu for the Lenovo Legion Y700 Gen 4 (kShimC)

A boot menu with two entries, Android and SteamOS, that runs from slot A's boot
image (boot_a) before either system starts. It is an add-on: `scripts/build-kshimc.sh`
builds a test bundle that works with any SteamOS image of the Gen 4 that has the
dual boot (`tablet-dualboot-install`).

This is not tested on a tablet. What the build checks offline is listed at the
end.

## How it works

- boot_a holds the stock Android boot image. `tablet-bootmenu-install` saves it
  to `/home/.ufs-backup` (with its sha256), then packs it as the Android entry
  with the SteamOS kernel from boot_b as the second entry, the menu program
  (`kShimC.bin`, 4 MiB) in front, and writes that back to boot_a.
- The SteamOS entry runs the same kernel as boot_b with the device tree of that
  kernel (`/opt/steamos-sm8750/*-elden-steamos/dtbs/sm8750-lenovo-elden.dtb`
  on the tablet). The kernel's own command line is built in
  (`root=PARTLABEL=steamos`); the device tree gets the same text in `/chosen`.
- Slot A is made the active slot. Android needs slot A (it starts with the slot
  suffix), so it stays there.
- boot_b is never written. `fastboot set_active b` starts plain SteamOS whatever
  boot_a holds.
- `--restore` writes the saved stock image back and makes slot B active.
- A new kernel in boot_b (a fastboot flash, `tablet-dualboot-install`, a future
  update) leaves the menu's SteamOS entry on the old kernel.
  `steamos-arm-tablet-bootmenu-sync.service` runs `tablet-bootmenu-install
  --sync` at boot: if the kernel in boot_b differs from the one in boot_a, it
  packs boot_a again from the saved stock image. The bundle installs that unit
  itself on images that don't have it.
- The menu never writes to the UFS and keeps no settings: no native UFS
  access, no settings partition, nothing saved between boots. The default entry
  and the timeout are in the packed manifest (`--default`, `--timeout`).

## Files

| File | What |
|---|---|
| `pins.env` | The source and its four dependencies, by commit. Nothing is vendored. |
| `steamos_elden_defconfig` | Runtime config: keys, framebuffer, rotation 270, Android and Linux entries, power and advanced actions; no storage, no settings. |
| `patches/` | Changes to the source, applied by `build-kshimc.sh` in order (see below). |
| `check-font-glyphs.py`, `menu-required-text` | The menu font is a subset; every character of the menu text must be in it. |
| `tester-README.txt` | The text shipped with the bundle. |

The patches are scripts, not diffs: they find the old wording in the tree and
replace it, so the repository never has to quote it. `0001` sets the entry
names and descriptions (SteamOS, English and Chinese) and the credit line, and
adjusts the host tests. `0002` renames the device-tree properties the menu
reads from the Linux entry (`boot-stage`, `root-medium`) to the `kshim,`
prefix; `tablet-bootmenu-pack` writes the same names.

## Building

In the build VM, with docker:

    scripts/build-kshimc.sh [/work/kshimc-gen4]

It builds a container image once, fetches the sources at the commits in
`pins.env`, patches, builds the runtime and the aarch64 packer tools, runs
the host tests, the manifest tests in QEMU and the packer tests, renders the
menu, and writes the bundle with `SHA256SUMS`.
`scripts/test-bootmenu-install.sh BUNDLE KERNEL_OUT` then runs the install tool
on files.

## License

`kShimC.bin` is built from GPL-3.0-only source, so the bundle is GPL-3.0-only:
the corresponding source is the pinned commit plus the files in `patches/` and
`steamos_elden_defconfig` here. The packer tools are GPL-3.0-or-later, the AVB
tool is under the AOSP permission notice, the menu font under the SIL Open
Font License. The license texts are in the bundle (`licenses/`). The install
scripts in `steamos-overlay/usr/lib/steamos-arm/` are part of this repository.
