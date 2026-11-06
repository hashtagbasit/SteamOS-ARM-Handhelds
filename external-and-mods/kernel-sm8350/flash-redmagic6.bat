@echo off
rem Zaviya for the REDMAGIC 6 (NX669J): install from fastboot mode.
rem
rem Hold Power + Volume Down to reach fastboot, bootloader unlocked.
rem This ERASES Android and everything on the phone (userdata).
rem Test boot on slot b first (Android and userdata untouched), see
rem docs\redmagic6.md. Back to Android: flash Nubia's full OTA.
setlocal
cd /d "%~dp0"

where fastboot >nul 2>nul || (echo fastboot not found, install Android platform-tools & exit /b 1)
fastboot getvar unlocked 2>&1 | findstr /c:"unlocked: yes" >nul || (echo no device in fastboot mode, or the bootloader is locked & exit /b 1)

set /p answer=This erases Android and everything on the phone. Type YES to continue:
if not "%answer%"=="YES" exit /b 1

rem The boot images are not signed with Nubia's keys: vbmeta.img is Nubia's
rem with verification disabled (flags 3).
fastboot flash vbmeta_a vbmeta.img || exit /b 1
fastboot flash vbmeta_b vbmeta.img || exit /b 1
rem With a valid dtbo, ABL overlays Nubia's board dtbo and the hypervisor's
rem overlays onto the DTB, which fails on a mainline tree.
fastboot erase dtbo_a || exit /b 1
fastboot erase dtbo_b || exit /b 1
rem Nubia's ABL only starts its own layout: kernel in boot, DTB + initramfs
rem in vendor_boot. Use vendor_boot-debug.img instead for a USB debug shell.
fastboot flash boot_a boot.img || exit /b 1
fastboot flash boot_b boot.img || exit /b 1
fastboot flash vendor_boot_a vendor_boot.img || exit /b 1
fastboot flash vendor_boot_b vendor_boot.img || exit /b 1
fastboot flash userdata userdata.img || exit /b 1
fastboot --set-active=a
fastboot reboot
echo Done. The first boot takes a few minutes (the filesystem grows to the whole partition).
