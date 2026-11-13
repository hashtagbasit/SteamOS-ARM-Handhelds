# Zaviya Installer

An Android app that puts Zaviya on a microSD card from the handheld itself, with no PC.
Zaviya is based on SteamOS for ARM and built for handhelds.

The app is in beta. The APK is attached to the
[v1.5 release](https://github.com/hashtagbasit/Zaviya/releases/tag/v1.5) as
`zaviya-installer-0.1.0-beta.apk`. Please report problems in the
[issues](https://github.com/hashtagbasit/Zaviya/issues) with the device model.

The app walks through six steps. Each waits for you.

1. Checks the chip: SM8650, SM8550, SM8750 or SM8250. Any other chip stops here.
2. Finds the microSD card, checks it is a card (not built-in storage) and 32 GB or bigger.
3. Finds the newest image for the chip, downloads it (resumes if interrupted), checks its SHA-256.
4. Writes the image to the card as root, unpacking the zstd stream on the fly, then reads the card back and compares a hash.
5. Saves the handheld's own bootloader (both slots) to `/sdcard/zaviya-abl-backup/`, then flashes the bundled OpenABL 1.2 for the detected chip to both slots and reads them back. A Restore button writes the saved copy back.
6. Shows how to start it.

The download and its hash check run under a foreground service, so you can switch to other apps. Closing the app from recents stops it; the next download picks up from what was saved.

Not in this version: internal storage install, repair tools, self-update.

## Build

```
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
./gradlew assembleDebug        # app/build/outputs/apk/debug/app-debug.apk
./gradlew testDebugUnitTest    # logic tests, script tests, and the screen renders
```

minSdk 30, arm64-v8a only. The unit tests also render every screen on the JVM into `design/screens/`.

## Where images come from

The app first reads `latest.json` from the download server
(`Config.MANIFEST_URL`, https://downloads.zaviyaos.workers.dev/latest.json). It
lists the release tag, the `SHA256SUMS` address and, per chip, the image name,
address and size. The image is checked against its line in `SHA256SUMS` after
the download.

If the manifest can't be fetched or has no usable entry for the chip, the app
falls back to the GitHub releases list. There it looks for
`zaviya-<soc>-<version>.img.zst`, as one file or split into `.001`, `.002` and
so on (GitHub files must be under 2 GiB), and joins the parts. If no release
has a complete image for the chip, the app says so.

## Root

In order: `/product/bin/xsu`, the vendor root service, plain `su`. If none works, the app saves
`zaviya-<job>.sh` in Downloads and asks you to run it from the settings tool that runs scripts as root.
Every script moves to `/data/local/tmp`, detaches, holds a wake lock, and reports through a status file the app polls.

## Bundled files

- OpenABL 1.2 ELFs (`app/src/main/assets/openabl/`), the same files and hashes as `scripts/stage-openabl.sh`.
  `tools/fetch-openabl.sh` fetches and checks them. The build refuses any file that does not match its pinned hash.
  Newer OpenABL releases do not start Zaviya images, so the version stays pinned.
- `zstd` 1.5.7, static arm64, built from the official source tarball (SHA-256 `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`)
  with `make zstd-release LDFLAGS=-static CFLAGS=-O3` on aarch64 and stripped. It sits in
  `app/src/main/jniLibs/arm64-v8a/libzstd_bin.so` (SHA-256 `6093f74a7655da08df047b56628d4c690c4b917ce77578ab28dfb6ff0c83a770`).
  License: BSD-3-Clause (dual-licensed with GPL-2.0), see `LICENSES/`.
- Jost Light and Regular (SIL OFL 1.1), static instances cut from the variable font.

## License

GPL-2.0, like the rest of the project (see `../LICENSE`). Third-party licenses are in `LICENSES/`.
