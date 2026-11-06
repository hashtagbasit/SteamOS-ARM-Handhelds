# Zaviya on AYN Odin 3 (SM8750)

This document covers how to install and run Zaviya on the **AYN Odin 3** (Snapdragon 8 Elite / Dragonwing Q8, SM8750 with Adreno 830).

---

## Prerequisites

1. **AYN Odin 3** handheld.
2. **MicroSD Card**: 32 GB or larger (A2 rated recommended for fast I/O).
3. **Flashing tool**: [balenaEtcher](https://etcher.balena.io/), [Rufus](https://rufus.ie/), or `dd` on Linux/macOS.
4. **Bootloader files**: the `openabl` folder on the BOOT drive of the image (it carries OpenABL 1.2). The same bootloader is on the [OpenABL releases](https://github.com/OpenHandheldCollective/OpenABL/releases) page.

---

## Step 1: Bootloader Backup & Flash (One-Time Setup)

The Odin 3 needs OpenABL to boot Linux from the microSD card or internal storage. Android keeps working: set Boot mode to Android, or hold Volume Up at power-on.

You need Android's "run script as root" option (in the device's settings). The scripts are plain `dd` lines because those tools run a script line by line and don't show its output.

1. Copy the whole `openabl` folder to the top of the Odin 3's internal storage, so it is `/sdcard/openabl` (not inside Download or another folder). The scripts only look there.
2. Run `backup_abl.sh` as root. It saves your current ABL as `abl_a.img` and `abl_b.img` in that folder:
   ```bash
   su
   sh /sdcard/openabl/backup_abl.sh
   ```
   > [!IMPORTANT]
   > Check that both `abl_a.img` and `abl_b.img` are there and not 0 bytes. Copy them to a PC and keep them!
3. Run `flash_abl.sh` as root. It writes OpenABL to both slots:
   ```bash
   sh /sdcard/openabl/flash_abl.sh
   ```
4. Restart holding **Volume Down** to open the menu (Volume to move, Power to select). Set **Device model**, set **Boot mode** to **Linux** (not UEFI, the image has no UEFI loader and the screen stays black), then **Start**.

To go back to the ABL you had, put `abl_a.img` and `abl_b.img` back in `/sdcard/openabl` and run `restore_backup_abl.sh` as root.

### Via Fastboot from PC

If your device's bootloader is unlocked:
```bash
adb reboot bootloader
fastboot flash abl_a openabl/abl_signed-SM8750.elf
fastboot flash abl_b openabl/abl_signed-SM8750.elf
fastboot reboot
```

---

## Step 2: Flash the Zaviya Image to MicroSD

1. Insert your microSD card into your computer.
2. Flash `sm8750-work/steamos-odin3.img` using BalenaEtcher or terminal `dd`:
   ```bash
   sudo dd if=sm8750-work/steamos-odin3.img of=/dev/sdX bs=4M status=progress conv=fsync
   ```
   *(Replace `/dev/sdX` with your actual microSD card device path).*

---

## Step 3: Booting Zaviya

1. Insert the flashed microSD card into your Odin 3.
2. Power on the device while holding **Volume Down** until the bootloader menu appears.
3. Use the Volume keys to navigate:
   * **Boot Mode:** Switch to **Linux**
4. Press the **Power** button (or START) to boot.

> [!IMPORTANT]
> **Boot Time & Initial Black Screen ("Gotcha"):**
> On every cold boot, Zaviya launches Gamescope immediately while Steam takes ~2 to 2.5 minutes in the background to initialize its daemons, query the Adreno 830 GPU topology via Turnip, and start `steamwebhelper`. **The screen will remain black for up to 2.5 minutes before the SteamOS logo splash and Sign-In UI appear.** Do not panic or force power-off during this period!
> 
> **Idle Screen Blackout:**
> If left inactive on the login screen for a couple of minutes, Steam's built-in screensaver automatically blanks the display to protect the AMOLED screen. Tap any button on the gamepad (like **A** or the **D-pad**) or touch the screen to wake it back up immediately.

---

## What to Expect in Zaviya

* **Game Mode:** Steam's Gamepad UI will launch. Log in with your Steam account.
* **Controller:** The built-in controller is mapped via InputPlumber as a native Steam Deck controller (`deck-uhid`). Analog sticks, triggers, D-pad, and face buttons work in Steam Input.
* **Display:** 1080x1920 AMOLED panel running at 60 Hz or 120 Hz with dynamic frame limiting.
* **Graphics:** Accelerated Vulkan via Mesa Freedreno Turnip (Adreno 830).
* **Audio:** ALSA UCM profiles route audio to the internal stereo speakers and headphone jack.
* **Fan & Power Management:** Dynamic temperature-based fan control via `odin3d` with CPU governor scaling (`schedutil` by default) and GPU devfreq tuning.
* **Desktop Mode:** Switch to desktop mode via Steam Menu -> Power -> Switch to Desktop to access KDE Plasma 6.

---

## Fan Control & Platform Management (`odin3ctl`)

The Odin 3 runs `odin3d`, a background daemon that monitors all CPU and GPU thermal sensors and dynamically adjusts fan speed along customizable curves. It also manages CPU frequency scaling (`schedutil` governor prevents high idle heat) and GPU devfreq ranges.

You can inspect or control the daemon at any time from a terminal or SSH using `odin3ctl`:

```bash
# View live status: temperatures, fan speed, active profile, and clocks
odin3ctl status

# Live terminal monitor (updates every second)
odin3ctl monitor

# Switch performance and fan profiles (silent, balanced, turbo)
odin3ctl profile silent
odin3ctl profile balanced
odin3ctl profile turbo

# Set a manual fixed fan percentage (e.g. 50%)
odin3ctl fan fixed 50

# Return to automatic temperature-based curve mode
odin3ctl fan auto

# Toggle temporary full-speed fan boost
odin3ctl fan boost

# Control stick ring RGB LEDs (e.g. hex color or off)
odin3ctl rgb ff3c00
odin3ctl rgb off
```

> [!TIP]
> **Thermal Runaway Protection:**
> Even if a manual fixed fan speed or silent profile is chosen, `odin3d` includes a hardware safety override: if the hottest SoC sensor reaches **88°C**, the fan immediately ramps to **100% (PWM 255)** until temperature drops safely below 78°C.

### Sudo Password
The default user is `steamos`. It has no password by default. To set one for `sudo` commands:
1. Switch to Desktop Mode.
2. Open **Konsole**.
3. Type `passwd` and enter your desired password.
