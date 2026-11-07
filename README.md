<p align="center">
  <a href="https://steamos-arm-port.github.io/zaviya/">
    <img src=".github/assets/logo.svg" alt="Zaviya" width="112">
  </a>
</p>

<h1 align="center">Zaviya</h1>

<p align="center"><strong>for ARM handhelds</strong></p>

<p align="center">
  SteamOS for ARM set up for handhelds and tablets: Game Mode, the KDE desktop, PC games through FEX and Proton, and Android apps.
</p>

<p align="center">Formerly known as Unofficial SteamOS ARM Port.</p>

<p align="center">
  <a href="https://github.com/hashtagbasit/Zaviya/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/hashtagbasit/Zaviya?include_prereleases&style=flat&color=7c5cf0&label=release"></a>
  <a href="https://github.com/hashtagbasit/Zaviya/releases"><img alt="Total downloads" src="https://img.shields.io/github/downloads/hashtagbasit/Zaviya/total?style=flat&color=7c5cf0&label=downloads"></a>
  <a href="https://steamos-arm-port.github.io/zaviya/"><img alt="Documentation" src="https://img.shields.io/badge/docs-website-18181a?style=flat"></a>
  <a href="LICENSE"><img alt="GPL-2.0 license" src="https://img.shields.io/badge/license-GPL--2.0-18181a?style=flat"></a>
  <a href="https://discord.gg/EP53nZYvg"><img alt="Discord" src="https://img.shields.io/badge/chat-Discord-5865F2?style=flat&amp;logo=discord&amp;logoColor=white"></a>
</p>

<p align="center">
  <a href="https://steamos-arm-port.github.io/zaviya/getting-started/install/"><strong>Install it</strong></a>
  ·
  <a href="https://steamos-arm-port.github.io/zaviya/devices/">Supported devices</a>
  ·
  <a href="https://steamos-arm-port.github.io/zaviya/downloads/">Downloads</a>
  ·
  <a href="https://steamos-arm-port.github.io/zaviya/help/known-issues/">Known issues</a>
</p>

> [!WARNING]
> This is an unofficial community project.
> Installing it means flashing the OpenABL bootloader, and getting that
> wrong can leave your device unable to boot or lose your data. Back up first
> and follow the [install guide](https://steamos-arm-port.github.io/zaviya/getting-started/install/)
> step by step.

## About

The ARM build of SteamOS I start from is made for a VR headset, so out of the box a lot
of it gets in the way on a handheld: services that keep crashing, the UI stuck
on the slow cores, the GPU not clocking up, standby that drains the battery. I
turned off what a handheld doesn't need and fixed the rest, the long version
is in [HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

What you get:

- Game Mode and Desktop Mode, with the controller showing up as a Steam Deck pad
- x86 PC games through FEX and ARM64 Proton, plus Epic, GOG and Amazon through Heroic
- Android apps with the Play Store, and Restart into Android from Zaviya Control
- Updates from Settings > System, no reflashing
- Install to internal storage next to Android, or keep it on a microSD card
- Game Mode on an external monitor or dock, sound included
- Lossless Scaling frame gen (lsfg-vk 2.0 and Classic 1.x), Decky and the performance overlay
- Steam Remote Play with hardware decoding, plus optional PyroWave
- Zaviya Loadout, which installs emulators and apps picked for your SoC
- Sleep that lasts, quiet fan curves, and a clean power off before the battery runs flat
- A dashboard with themes on the bottom screen of the AYN Thor and AYANEO Pocket DS

## Quick start

1. Flash the OpenABL bootloader for your SoC (older versions of it work too), the [ABL guide](https://steamos-arm-port.github.io/zaviya/getting-started/abl/) walks you through it. Back up your stock ABL first.
2. Download the image for your SoC from [Releases](https://github.com/hashtagbasit/Zaviya/releases/latest), open the `.001` part with 7-Zip and flash the `.img` inside to a microSD card (32 GB+) with balenaEtcher or Rufus.
3. Boot the card from the ABL menu and pick your device. First boot takes a couple of minutes.

Already on it? Go to Settings > System > Check for updates.

## Devices

### Handhelds

| SoC | Devices | Status |
|---|---|---|
| Snapdragon 8 Elite | AYN Odin 3, KONKR Pocket FIT Elite | Stable |
| Snapdragon 8 Gen 3 | KONKR Pocket FIT, AYANEO Pocket S2 / S2 Pro | Stable |
| Snapdragon 8 Gen 2 | AYN Odin 2 / Mini / Portal / Thor, AYANEO Pocket ACE / DMG / DS / EVO / S 1K / S 2K, Retroid Pocket 6 / Nova | Stable |
| Snapdragon 865 | Retroid Pocket 5 / Flip 2 / Mini / Mini V2, AYN Thor Lite, MANGMI Air Y Pro / Pocket Max, AYANEO Pocket MICRO 2 | Beta |

There's one image per SoC, you pick your device in the ABL menu and it sets
itself up. I only own a Pocket FIT, the rest is tested by the community, so if
you have one of the others please
[let me know how it runs](https://github.com/hashtagbasit/Zaviya/issues).

### Phones & tablets

| Device | SoC | Status |
|---|---|---|
| Lenovo Legion Y700 Gen 3 (TB321FU) | Snapdragon 8 Gen 3 | In testing |
| Lenovo Legion Y700 Gen 4 (TB322FC) | Snapdragon 8 Elite | In testing |
| Lenovo Legion Y700 Gen 5 (TB323FU) | Snapdragon 8 Elite Gen 5 | In testing |
| REDMAGIC 6 (NX669J) | Snapdragon 888 | Build it yourself ([guide](docs/redmagic6.md)) |

The Gen 3 and Gen 4 install to internal storage next to Android, and the
Gen 4 can also run from a microSD card. The Gen 5 runs from a microSD card
and is switched on from Android, it's in early testing with a few testers
right now. Tablet builds go out in the Discord first, so if you have one and
want to help, come say hi on [Discord](https://discord.gg/EP53nZYvg) and see the
[Lenovo page](https://steamos-arm-port.github.io/zaviya/devices/lenovo/).

## Documentation

Everything lives on the [website](https://steamos-arm-port.github.io/zaviya/).

| I want to… | Guide |
|---|---|
| Install it | [Flash to a microSD card](https://steamos-arm-port.github.io/zaviya/getting-started/install/) |
| Check my device | [Supported devices](https://steamos-arm-port.github.io/zaviya/devices/) |
| Move it to internal storage | [Internal storage](https://steamos-arm-port.github.io/zaviya/getting-started/internal-storage/) |
| Update | [Updates](https://steamos-arm-port.github.io/zaviya/using/updates/) |
| Get help | [FAQ](https://steamos-arm-port.github.io/zaviya/help/faq/) · [Troubleshooting](https://steamos-arm-port.github.io/zaviya/help/troubleshooting/) |
| Report a bug | [GitHub issues](https://github.com/hashtagbasit/Zaviya/issues) |

## Building

The images are built from this repo on an ARM64 Linux machine, see
[docs/building.md](docs/building.md). Issues and pull requests are welcome,
and for help with installing come say hi on [Discord](https://discord.gg/EP53nZYvg).

## Supporting the project

<p align="left">
  <a href="https://ko-fi.com/aimalb"><img src="https://img.shields.io/badge/Ko--fi-Buy%20me%20a%20coffee-ff5e5b?style=for-the-badge&logo=kofi&logoColor=white" alt="Ko-fi"></a>
  <a href="https://paypal.me/Basit2000"><img src="https://img.shields.io/badge/PayPal-Basit2000-00457c?style=for-the-badge&logo=paypal&logoColor=white" alt="PayPal"></a>
</p>

Any amount raised will be used to buy devices to support and boost development, a star helps too!

Have a device you'd like to see supported? Sending one over for long term
development is the fastest way to get it there, message me on
[Discord](https://discord.gg/EP53nZYvg).

## Credits

The kernels and device support build on other people's work, and the fixes go
back and forth with other ARM handheld projects. Thanks to everyone who
contributed code, and to the testers in the Discord who send logs for devices I
don't own. The full list of projects and people is in [CREDITS.md](CREDITS.md).

## License

My scripts and overlays are GPL-2.0, everything in `external-and-mods/` keeps
its own license. See [LICENSE](LICENSE).

SteamOS and Steam are trademarks of their owner. This project isn't affiliated with or endorsed by them.
