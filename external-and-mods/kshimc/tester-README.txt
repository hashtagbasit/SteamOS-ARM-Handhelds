Boot menu for the Lenovo Legion Y700 Gen 4 (TB322FC)
====================================================

What this does
--------------
It adds a boot menu with two entries, Android and SteamOS. The tablet
shows it at every start. SteamOS starts by itself after 8 seconds; the volume
keys pick the other entry and the power key confirms.

You need
--------
- SteamOS installed on the tablet next to Android, in the "steamos" partition
  (the dual boot), and started from it.
- Android still on the tablet, on its original slot A.
- The tablet's bootloader unlocked (it is, if SteamOS runs).
- About 1 GB free for the work files and 100 MB free in /home.

Install
-------
1. Copy this folder to the tablet, for example to /home/deck/kshimc-gen4.
2. Open a terminal there and look first, nothing is written:
       sudo ./tablet-bootmenu-install --dry-run
3. If it ends with "Dry run: nothing changed", install:
       sudo ./tablet-bootmenu-install
   Type YES when it asks. It keeps a copy of the original Android boot image
   in /home/.ufs-backup before it changes anything.
4. Restart. The menu comes up.

How to get back
---------------
If the menu doesn't show or something is wrong:
1. Turn the tablet off, then hold Volume Down + Power until fastboot shows.
2. On the computer:
       fastboot set_active b
       fastboot reboot
   SteamOS starts as it did before.

To remove the menu for good, from SteamOS:
       sudo ./tablet-bootmenu-install --restore
It writes the saved original Android boot image back and makes slot B the
active one again.

Other options
-------------
  --default android     Android starts by itself instead of SteamOS
  --timeout 15          seconds before it starts by itself (1 to 60)
  --status              what is installed

After a SteamOS kernel update the menu is packed again at the next boot by
itself. Android system updates replace the menu: run the install again after
one.

Please report
-------------
- Does the menu show, and is the text readable and the right way up?
- Do the volume keys move the selection and the power key start an entry?
- Do both entries start (SteamOS and Android)?
- After picking SteamOS: do Wi-Fi, sound and the screen work as before?
- Anything on screen that is cut off or garbled, with a photo.
