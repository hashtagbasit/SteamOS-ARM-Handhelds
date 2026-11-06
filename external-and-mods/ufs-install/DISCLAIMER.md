# DISCLAIMER — USE AT YOUR OWN RISK

**Read this entire document before running any script in this folder.**

## What these tools do

The scripts in **external-and-mods/ufs-install** repartition the **internal UFS** storage on Qualcomm SM8650 handhelds (KONKR Pocket FIT, AYANEO Pocket S2), SM8550 handhelds (AYN Odin 2, Odin 2 Mini, Odin 2 Portal), and SM8750 handhelds (AYN Odin 3; KONKR Pocket FIT Elite untested) to install **Zaviya** alongside **Android**, using **OpenABL** with a dual-boot layout of **three Linux partitions** (boot + `STORAGE` + `HOME`).

This is **not** a supported manufacturer procedure. It is an **experimental community tool**.

## Data loss

Running `install-to-internal.sh` (unless using `--resume` / `--deploy-only` on **existing** Zaviya 3-partition layouts only):

- **Wipes Android `userdata`** — all apps, photos, game saves, accounts, and settings on internal Android storage are **permanently erased** (equivalent to repartition + factory reset).
- **May destroy other data** on internal UFS if the partition table is modified incorrectly.
- **Does not automatically back up** your microSD Linux system before copying it to UFS.

**Back up anything important before proceeding.**

## Boot failure risk

After installation or a failed attempt:

- **Android may not boot** until you perform a **factory data reset** from recovery (expected after userdata wipe).
- **Linux may not boot** from microSD or from internal UFS if the kernel, partitions, or cmdline are wrong (black screen, hang, etc.).
- **Both systems can fail** at the same time, leaving the device unusable without recovery steps (recovery mode, SD boot, ABL “UNINSTALL CFW”, EDL flash, etc.).

## Requirements (your responsibility)

- **OpenABL** already installed and working.
- Boot **Zaviya from the microSD card** (not from UFS) when running the installer.
- A **`/boot/KERNEL`** from this project's SD image whose initramfs understands `root=PARTLABEL=` (the installer checks this).
- Correct **ABL device profile** (“Set the Device” → your exact model).

## No warranty

THE SOFTWARE IS PROVIDED **"AS IS"**, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, OR NON-INFRINGEMENT.

## Limitation of liability

IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT, OR OTHERWISE, ARISING FROM, OUT OF, OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE, INCLUDING BUT NOT LIMITED TO:

- Loss of data
- Bricked or unbootable devices
- Loss of Android or Linux functionality
- Hardware damage (including UFS wear or corruption in edge cases)

## Your acceptance

By running these scripts, **you confirm that**:

1. You understand the risks above.
2. You have backed up data you care about.
3. You accept **full responsibility** for the outcome.
4. You will not hold the authors liable for any damage or data loss.

If you do not agree, **do not run the installer**.

## Other UFS layouts

These scripts target the **Zaviya three-partition layout** (boot + `STORAGE` + `HOME`). They will **refuse** an old two-partition boot + `STORAGE` install. Use ABL **UNINSTALL CFW** (and remove a leftover `HOME` if needed) before a fresh install.

## License

Scripts are licensed under **GPL-2.0-or-later** (see [LICENSE](LICENSE)). The disclaimer above is additional safety information and does not replace the license terms.
