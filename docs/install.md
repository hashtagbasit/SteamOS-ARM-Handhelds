# Installing

You need a 32GB+ microSD card and a PC.

1. Flash [OpenABL](https://github.com/OpenHandheldCollective/OpenABL/releases) for your chip. The image also carries OpenABL 1.2 in the `openabl` folder on its BOOT drive, with scripts to back up your current ABL and flash the new one. Android still boots from its menu.
2. Download all the `.7z` parts for your chip from [Releases](https://github.com/hashtagbasit/SteamOS-ARM-Port/releases), open the `.001` one with 7-Zip or WinRAR (Keka or The Unarchiver on Mac) and extract it. Flash the `.img` you get to the microSD card with balenaEtcher or Rufus.
3. Hold Volume Down while turning it on, go to Set device model, pick your device, set boot mode to Linux (not UEFI) and hit START. On the Retroid Pocket 5 and Flip 2, if the screen stays black, pick the Visionox entry of the same model (second panel version). On the Pocket S2 Pro, pick AYANEO Pocket S2.

First boot takes a couple of minutes, don't panic. Then sign in to Steam and you're good to go.

On 8 Gen 3, apply the [v1.2.1 hotfix](https://github.com/hashtagbasit/SteamOS-ARM-Port/releases/tag/v1.2.1) after the first boot, it only takes a minute.

## Your password

The Linux user is `steamos` and has no password until you set one: open Konsole in Desktop Mode and run `passwd`. You need it for `sudo`.

## Next

- [Move it to internal storage](internal-storage.md) (8 Gen 3 only for now)
- [Update to newer versions](updating.md) without reflashing
