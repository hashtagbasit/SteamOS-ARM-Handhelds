OpenABL @VERSION@ for @SOC@ (@DEVICES@)

The bootloader menu that lets this device start Zaviya from the microSD
card or internal storage, and still start Android.
https://github.com/OpenHandheldCollective/OpenABL
(GPL-3.0, (c) Open Handheld Collective). Only needed once.

You need Android's "run script as root" option (in the device's settings).
The scripts are plain dd lines because those tools
run a script line by line and don't show its output.

1. Copy this whole openabl folder to the top of the device's internal
   storage, so it is /sdcard/openabl (not inside Download or another
   folder). The scripts only look there.
2. Run backup_abl.sh as root. It saves your current ABL as abl_a.img and
   abl_b.img in that folder. Check that both files are there (not 0 bytes),
   copy them to a PC and keep them.
3. Run flash_abl.sh as root. It writes OpenABL to both slots.
4. Restart holding Volume Down to open the menu (Volume to move, Power to
   select). Set Device model, set Boot mode to Linux (not UEFI, the image
   has no UEFI loader and the screen stays black), then Start.
   Retroid Pocket 5 and Flip 2 each come in two panel versions: if the
   screen stays black with the plain model, try the one marked Visionox.

At power-on: nothing held starts the chosen boot mode, Volume Down opens the
menu, Volume Up starts Android when the boot mode is Linux.

To go back to the ABL you had: put abl_a.img and abl_b.img back in
/sdcard/openabl and run restore_backup_abl.sh as root.

Android keeps working with OpenABL: set Boot mode to Android, or hold
Volume Up at power-on.
