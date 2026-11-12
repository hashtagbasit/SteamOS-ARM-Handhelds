# Credits

**Zaviya** (formerly known as Unofficial SteamOS ARM Port) is based on SteamOS for ARM and runs on
Snapdragon 8 Elite, 8 Gen 3, 8 Gen 2 and 865 handhelds and on Lenovo Legion tablets. Some of its groundwork (the image builder and a few scripts) came
from MaSi's **SteamOS-ARM-SM8550**, so everything MaSi credits below still applies.

## This project

| Source | URL | Used for |
|--------|-----|-------------|
| **MaSi / SteamOS-ARM-SM8550** | https://github.com/MaSieS4Fun/SteamOS-ARM-SM8550 | The whole base: image builder, SteamOS ARM overlay, Box64/Decky setup, scripts |
| **ROCKNIX SM8650** | https://github.com/ROCKNIX/distribution | Kernel recipe (20260901, Linux 7.2.8), Pocket FIT panel/touch/MCU patches, DPU inline rotation and QSEED detail enhancer (tiopex), device tree, firmware, audio UCM |
| **ROCKNIX SM8550** | https://github.com/ROCKNIX/distribution | Kernel recipe, patches and device trees for all 13 SM8550 handhelds, firmware, audio UCM, controller event maps |
| **OpenABL** | https://github.com/OpenHandheldCollective/OpenABL | Bootloader menu bundled on every image (ROCKNIX ABL's successor, same developers), its flash scripts |
| **OpenABL Android Installer** (Open Handheld Collective) | https://github.com/OpenHandheldCollective/OpenABL-Android-Installer | Zaviya Installer (`android-installer/`) learns its bootloader backup and slot checks from it (GPL-2.0). The code is written new. It bundles OpenABL 1.2 and a static `zstd` (BSD-3-Clause), see `android-installer/LICENSES/` |
| **ROCKNIX ABL** | https://github.com/ROCKNIX/abl | Bootloader with device model selection (bundled up to 1.4) |
| **ROCKNIX MangoHud patches** | https://github.com/ROCKNIX/distribution/tree/next/projects/ROCKNIX/packages/apps/mangohud/patches | Qualcomm GPU, battery and RAM support for Steam's performance overlay (`external-and-mods/MangoHud-qualcomm/`) |
| **ArmadaOS** | https://github.com/armada-os/armada | Reference for SM8550 device quirks: IRQ affinity for the Adreno 740, AYANEO Pocket button codes, Thor/DS panel and backlight layout. Kernel patches used on 8 Gen 2 and 8 Gen 3: the s2idle series (PCIe suspend OPP and memory floor, RPMh suspend states for regulators, AudioReach graphs across suspend, tsens, geni, ICE and UFS fixes), PCIe iommu-map cell count, fan while charging in s2idle, wcd939x jack resume, and the SM8650 AYANEO base wake and codec-rail fixes. Userland: the SDDM-in-UTC fix for Switch to Desktop on first boot, and the AYN Thor Lite key phys_path fix. On the SM8250 (865) images: the CPU DDR votes made active-only for s2idle (gennro, kettlelinux), the s2idle fixes shared with 8 Elite (geni IRQ mask and CX votes, endpoint-only PCIe D3cold veto, UFS lane clocks, DSI PHY iface clock, tsens), and the MANGMI Pocket Max headphone WirePlumber rule and codec power rule |
| **kettlelinux** | https://github.com/kettlelinux/kettlelinux | Its Retroid Pocket 5 notes on what keeps the SM8250 (865) out of CX collapse in s2idle, which guided the 865 sleep work |
| **bylaws** | https://github.com/bylaws/linux | arm64 unaligned atomics emulation (via ArmadaOS) |
| **GUF296** | https://github.com/GUF296/tb321fu-linux | Lenovo Legion Y700 Gen 3 (TB321FU) bring-up: device tree, Novatek NT36523 panel and touch, AW882xx speakers, AW86937 haptics, Type-C, battery and audio fixes (`external-and-mods/kernel-tb321fu/`) |
| **enij90** | https://github.com/enij90/armada-tb321fu | Linux 7.2 ports of the TB321FU panel (with the BOE panel and 144/165 Hz) and speaker routing, display fixes, and TB321FU hardware notes |
| **h0cheung** | https://github.com/h0cheung/tb322fc-linux | Linux 7.2.8 tree for the Lenovo Legion Y700 Gen 4 (elden): SM8750 platform and board support, panel, touch, speakers and haptics (`external-and-mods/kernel-elden/`). Also the MangoApp frametime field order patch (MangoHud 0009) and the Legion G9 2026 InputPlumber profile for the Gen 4 with its firmware double-Home mapped to Quick Access (`external-and-mods/elden/rootfs/`) |
| **kShimC** by sunflower2333 (Y700 Gen 4 configuration by mydanyi) | https://github.com/sunflower2333/kShimC , https://github.com/mydanyi/armadaos-freedom | The boot menu in front of Android and SteamOS on the Lenovo Legion Y700 Gen 4 (`external-and-mods/kshimc/`, `scripts/build-kshimc.sh`): built from the source at a pinned commit with our menu text and a config without any storage access, licensed [GPL-3.0-only](https://www.gnu.org/licenses/gpl-3.0.html), with the MultiBootKernelPatcher packer (Project-Aloha, GPL-3.0-or-later) |
| **lsfg-vk 2.0** by PancakeTAS | https://lsfg-vk.dev | Frame generation layer. The ARM64 build shipped here is compiled from the official source with no code changes; licensed under [CC BY-NC-ND 4.0](sm8650-overlay/usr/share/licenses/lsfg-vk/LICENSE.txt) |
| **lsfg-vk 1.x** by PancakeTAS, fork by xXJSONDeruloXx | https://github.com/xXJSONDeruloXx/lsfg-vk | Older frame generation layer (MIT) in `external-and-mods/lsfg-vk/` |
| **decky-lsfg-vk** | https://github.com/xXJSONDeruloXx/decky-lsfg-vk | Frame generation Decky plugin |
| **Jost** by The Jost Project Authors | https://github.com/indestructible-type , `branding/logo/Jost-OFL.txt` | Font of the Zaviya logo, SIL OFL 1.1, converted to outlines |

---

## From SteamOS-ARM-SM8550 (MaSi)

**SteamOS-ARM-SM8550** adapts SteamOS for ARM to Qualcomm SM8550
handhelds. This file lists the sources this repository is built from.

Original licenses remain with their authors. Project glue (scripts,
overlays) is **GPL-2.0** — see [`LICENSE`](LICENSE).

If a credit is missing or incorrect, please open an issue or pull request.

---

## Previous project (required credit)

This work is based on **[SteamOS-Ubuntu](https://github.com/MaSieS4Fun/SteamOS-Ubuntu)**
by the same author.

| From SteamOS-Ubuntu | Path here | Notes |
|---------------------|-----------|--------|
| **SM8550 gaming kernel** | `external-and-mods/kernel/` | Same tree as [MaSi-OS Kernel Updater](https://github.com/MaSieS4Fun/MaSi-OS-Kernel-Updater). Kernel-only detail: [`external-and-mods/kernel/CREDITS.md`](external-and-mods/kernel/CREDITS.md). |
| **Decky SM8550-Power** | `external-and-mods/Decky/sm8550/power-managment/` | Energy / power-control plugin (CPU/GPU profiles, fan, thermals). |
| **Decky SM8550-LED** | `external-and-mods/Decky/sm8550/color-leds/` | Controller RGB LED panel. |

Those two Decky plugins were adapted in SteamOS-Ubuntu from
**Hooandee**:

- Power UI: [Hooandee/panel-de-control](https://github.com/Hooandee/panel-de-control)
- LED UI: [Hooandee/decky-colores](https://github.com/Hooandee/decky-colores)

---

## Base system

| Source | URL | Used for |
|--------|-----|-------------|
| **SteamOS for ARM** (Frame / Deckard) | Upstream | Official aarch64 userspace, Plasma, gamescope session, Steam Gamepad UI. Reconstructed at build time; **not** stored in git. |
| **Steam (ARM64)** | Steam client | Game Mode client. Downloaded at image-build time; **not** stored in git. |
| **KDE Plasma / Frameworks** | https://kde.org | Official SteamOS desktop; kscreen and plasma-nm rebuilt to match SteamOS Qt/Plasma. |
| **Arch Linux ARM (Gear extras)** | https://archlinuxarm.org | Selected Plasma extras (Ark, Kate, …) built against SteamOS libraries. |

---

## Kernel and firmware

Inherited from **SteamOS-Ubuntu**. See
[`external-and-mods/kernel/CREDITS.md`](external-and-mods/kernel/CREDITS.md).

| Source | URL | Used for |
|--------|-----|-------------|
| **SteamOS-Ubuntu** | https://github.com/MaSieS4Fun/SteamOS-Ubuntu | Kernel tree, ABL `KERNEL` packaging, firmware staging |
| **MaSi-OS Kernel Updater** | https://github.com/MaSieS4Fun/MaSi-OS-Kernel-Updater | Same SM8550 kernel project |
| **Linux kernel** | https://www.kernel.org | GPL-2.0 vanilla tree |
| **Armbian** | https://github.com/armbian/build | SM8550 patch set and firmware |
| **ROCKNIX** | https://github.com/ROCKNIX/distribution · https://github.com/ROCKNIX/abl | ABL boot model, UFS `ROCKNIX`+`STORAGE`(+`HOME`), suspend patches |
| **Batocera / community DT** | Batocera, LineageOS AYN, Teguh Sobirin, Philippe Simons, thorch-os | Device trees, Thor touch, gyro firmware notes |

---

## Decky Loader and bundled plugins

| Source | URL | Used for |
|--------|-----|-------------|
| **SteamOS-Ubuntu** | https://github.com/MaSieS4Fun/SteamOS-Ubuntu | SM8550-Power and SM8550-LED as shipped here |
| **SteamDeckHomebrew / decky-loader** | https://github.com/SteamDeckHomebrew/decky-loader | PluginLoader (x86_64 via Box64) |
| **Hooandee / panel-de-control** | https://github.com/Hooandee/panel-de-control | Power-plugin design reference |
| **Hooandee / decky-colores** | https://github.com/Hooandee/decky-colores | LED-plugin design reference |
| **xXJSONDeruloXx / decky-lsfg-vk** | https://github.com/xXJSONDeruloXx/decky-lsfg-vk | LSFG Decky UI (when bundled) |

---

## Input, session, and graphics extras

| Source | URL | Used for |
|--------|-----|-------------|
| **ShadowBlip / InputPlumber** | https://github.com/ShadowBlip/InputPlumber | `deck-uhid` + keyboard target (OSK haptics) |
| **gamescope** | https://github.com/ValveSoftware/gamescope | Gaming Mode compositor (MSM / backlight patches in-tree) |
| **Mesa / Freedreno Turnip** | https://gitlab.freedesktop.org/mesa/mesa | Adreno 740 Vulkan (host-provided `.so` at image apply) |
| **MangoHud** | https://github.com/flightlessmango/MangoHud | Performance overlay |
| **lsfg-vk** | https://lsfg-vk.dev | Vulkan frame generation (2.0: CC BY-NC-ND 4.0) |
| **ptitSeb / box64** | https://github.com/ptitSeb/box64 | x86_64 for Decky PluginLoader |
| **thorch-os/thorch** | https://github.com/thorch-os/thorch | AYN Thor dual-screen / touch extras |

---

## Applications bundled by this overlay

| Source | URL | Used for |
|--------|-----|-------------|
| **MESA Easy Manager** | https://github.com/MaSieS4Fun/MESA-Easy-Manager | Turnip / Mesa helper |
| **Proton ARM Easy Manager** | In-tree / inspired by ProtonPlus | ARM Proton helper |
| **Steam ROM Manager** | https://github.com/SteamGridDB/steam-rom-manager | Desktop launcher |
| **Zaviya Installer** | `external-and-mods/ufs-install/` (MaSi-OS UFS lineage) | Internal UFS install: ROCKNIX + STORAGE + HOME |

---

## Design inspiration

| Project | Relationship |
|---------|--------------|
| **SteamOS / Jupiter** | Game Mode, Gamepad UI, official Plasma desktop |
| **SteamOS-Ubuntu** | Kernel, Decky SM8550 plugins, SM8550 handheld bring-up |
| **ROCKNIX** | ABL, UFS partition names, kernel patches |
| **Hooandee** | Decky power and LED plugin design |

---

## Acknowledgements

Thanks to the **SteamOS** developers, the **SteamOS-Ubuntu** testers, **Hooandee**, and
maintainers of **kernel.org**, **Armbian**, **ROCKNIX**, **Batocera**,
**SteamDeckHomebrew**, **ShadowBlip**, **PancakeTAS**, **Flightless Mango**,
**ptitSeb**, **thorch-os**, and everyone who documented ABL / DTB slots
on SM8550 handhelds.
