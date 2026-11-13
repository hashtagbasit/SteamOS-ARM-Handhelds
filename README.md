<img src=".github/assets/logo.svg" alt="Zaviya logo" width="72" align="right">

# Zaviya

**An operating system for ARM handhelds, based on SteamOS for ARM.**

Zaviya runs Game Mode, the Steam client and a KDE Plasma desktop natively on
Snapdragon handhelds. It boots from a microSD card or installs to internal
storage alongside Android, and the OpenABL boot menu selects between them at
power-on.

Formerly known as Unofficial SteamOS ARM Port.

[![Release](https://img.shields.io/github/v/release/hashtagbasit/Zaviya?style=flat-square&label=release&color=C9A24D)](https://zaviyaos.github.io/downloads/)
[![Website](https://img.shields.io/badge/website-zaviyaos.github.io-2b2b2b?style=flat-square)](https://zaviyaos.github.io/)
[![Discord](https://img.shields.io/badge/Discord-join-5865F2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/e2Cn85uQh9)
[![License](https://img.shields.io/badge/license-GPL--2.0-2b2b2b?style=flat-square)](LICENSE)

## Get Zaviya

Images are published on the [Releases page](https://zaviyaos.github.io/downloads/)
of the website. Choose the chip there to get the image, its size and checksum,
the changes for that chip and earlier versions. Since 1.5 each chip has a
single `.img.zst` file, which Raspberry Pi Imager and Rufus 4.7 or newer write
directly.

| Chip | Handhelds | |
|---|---|---|
| Snapdragon 8 Elite | AYN Odin 3, KONKR Pocket FIT Elite | [Download](https://zaviyaos.github.io/downloads/#sm8750) |
| Snapdragon 8 Gen 3 | KONKR Pocket FIT, AYANEO Pocket S2 / S2 Pro | [Download](https://zaviyaos.github.io/downloads/#sm8650) |
| Snapdragon 8 Gen 2 | AYN Odin 2 / Mini / Portal / Thor, AYANEO Pocket ACE / DMG / DS / EVO / S, Retroid Pocket 6 / Nova | [Download](https://zaviyaos.github.io/downloads/#sm8550) |
| Snapdragon 865 | Retroid Pocket 5 / Flip 2 / Mini / Mini V2, AYN Thor Lite, MANGMI Air Y Pro / Pocket Max, AYANEO Pocket MICRO 2 | [Download](https://zaviyaos.github.io/downloads/#sm8250) |

Installation writes the image to a microSD card and replaces the device's
bootloader with OpenABL. Back up the stock bootloader and any data first, and
follow the [install guide](https://zaviyaos.github.io/getting-started/install/).

OpenABL can be flashed from Android with the
[OpenABL Installer](https://github.com/OpenHandheldCollective/OpenABL-Android-Installer/releases/latest)
app by the Open Handheld Collective, which backs up the stock bootloader first.
The [OpenABL guide](https://zaviyaos.github.io/getting-started/abl/) has the
steps for the app and for the scripts included in every image.

### Zaviya Installer for Android (beta)

An Android app that installs Zaviya from the handheld without a PC: it
downloads the image for the chip, writes it to the microSD card, backs up the
stock bootloader and flashes OpenABL.
[Download the APK](https://github.com/hashtagbasit/Zaviya/releases/download/v1.5/zaviya-installer-0.1.0-beta.apk)
from the v1.5 release. It is in beta, so please
[report](https://github.com/hashtagbasit/Zaviya/issues) anything that goes
wrong, with the device model. Source: [`android-installer/`](android-installer/).

## Features

| | |
|---|---|
| **Game Mode and desktop** | Game Mode, the Steam client and KDE Plasma, all native ARM64. |
| **PC games** | x86 games run through FEX with ARM64 Proton. Heroic installs Epic, GOG and Amazon libraries. |
| **Controls** | Built-in controls appear to Steam as a Steam Deck controller. Decky and the performance overlay are preinstalled. |
| **Zaviya Control** | Quick Access plugin for performance profiles, fan curves, charge limit, button remapping, internal storage install, restarting into Android and recording logs for bug reports. |
| **Zaviya Loadout** | Built-in app store that installs emulators and apps chosen for the chip. |
| **Add games from files** | Windows games, console games, Linux apps and Android apps are added to the Steam library with artwork. |
| **Android apps** | Google Play Store included. Each app appears as its own title in the library. |
| **Frame generation** | Lossless Scaling frame generation (lsfg-vk 2.0 and 1.x) with ARM64 builds for native games. |
| **Dual screen** | On the AYN Thor and AYANEO Pocket DS the bottom screen holds a launcher, game tools, a themed dashboard and a trackpad. |
| **Docking and streaming** | Game Mode on an external monitor or dock with sound. Steam Remote Play with hardware decoding and optional PyroWave. |
| **Power** | Sleep on every supported chip, quiet fan curves, the user interface on the fast cores and a clean shutdown before the battery runs out. |
| **Storage** | Runs from microSD or installs to internal storage next to Android, from Desktop Mode or Game Mode. |
| **Updates** | Signed updates through Settings > System, rolled back automatically if interrupted. Releases that change the base system, such as 1.5, are a fresh install. |

## Tablets and phones

| Device | Chip | Status |
|---|---|---|
| Lenovo Legion Y700 Gen 3 (TB321FU) | Snapdragon 8 Gen 3 | Testing |
| Lenovo Legion Y700 Gen 4 (TB322FC) | Snapdragon 8 Elite | Testing |
| Lenovo Legion Y700 Gen 5 (TB323FU) | Snapdragon 8 Elite Gen 5 | Early testing |
| REDMAGIC 6 (NX669J) | Snapdragon 888 | Build from source ([guide](docs/redmagic6.md)) |

Tablet builds are shared on [Discord](https://discord.gg/e2Cn85uQh9). See the
[Lenovo page](https://zaviyaos.github.io/devices/lenovo/) for details.

## Help

- [Install guide](https://zaviyaos.github.io/getting-started/install/) and [supported devices](https://zaviyaos.github.io/devices/)
- [Known issues](https://zaviyaos.github.io/help/known-issues/), [troubleshooting](https://zaviyaos.github.io/help/troubleshooting/) and [FAQ](https://zaviyaos.github.io/help/faq/)
- [Discord](https://discord.gg/e2Cn85uQh9) for installation help
- [GitHub issues](https://github.com/hashtagbasit/Zaviya/issues) for bug reports. Attach the file from **Record logs** in Zaviya Control.

## Development

Images are built from this repository on an ARM64 Linux host; see
[docs/building.md](docs/building.md). The per-chip kernels, firmware and
configuration live in the `sm*-overlay/` folders, shared system files in
`steamos-overlay/`, and patched third-party components in `external-and-mods/`.

Development is done on a KONKR Pocket FIT. Every other device is tested by the
community, so reports and pull requests from other devices are welcome.

## Support the project

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support-ff5e5b?style=for-the-badge&logo=kofi&logoColor=white)](https://ko-fi.com/aimalb)
[![PayPal](https://img.shields.io/badge/PayPal-Basit2000-00457c?style=for-the-badge&logo=paypal&logoColor=white)](https://paypal.me/Basit2000)

Donations fund test devices. Device loans for long-term development can be
arranged on [Discord](https://discord.gg/e2Cn85uQh9). A star on the repository
also helps.

## Credits

Zaviya builds on the work of many kernel, bootloader and tooling projects and
on testers who send logs from their devices. The full list is in
[CREDITS.md](CREDITS.md).

## License

Scripts and overlays are licensed under GPL-2.0. Components in
`external-and-mods/` keep their own licenses. See [LICENSE](LICENSE).

SteamOS and Steam are trademarks of their owner. Zaviya is not affiliated with
or endorsed by them.
