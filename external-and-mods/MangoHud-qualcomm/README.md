# MangoHud for Steam's performance overlay on Qualcomm

Steam's Performance Overlay is drawn by mangoapp. The SteamOS build shows
the GPU at 0 % on these handhelds: it can't match a game's GPU handles on
mainline Qualcomm kernels (the device says `msm_dpu`, the game's handles say
`msm`). This is MangoHud v0.8.4 with:

| Patch | From |
|---|---|
| 0001 Qualcomm GPU support | [ROCKNIX](https://github.com/ROCKNIX/distribution/tree/next/projects/ROCKNIX/packages/apps/mangohud/patches) |
| 0002 Battery name | ROCKNIX |
| 0003 Qualcomm battery power_now | ROCKNIX |
| 0004 RAM name | ROCKNIX |
| 0005 SM8750 battery | ROCKNIX |
| 0006 Adreno on mainline: GPU clock, VRAM, blank instead of fake zeros, no crash on an unreadable process | ours |
| 0007 CPU temperature from a thermal zone that reads (8 Elite) | ours |
| 0008 CPU and GPU temperature from thermal zones on the Lenovo tablets' 7.2.x kernels | ours |
| 0009 mangoapp frametime fields in gamescope's order (app timing, then visible) | see CREDITS.md |

Built inside the SteamOS rootfs (its glibc) by
`scripts/build-mangohud-in-rootfs.sh`; the image build installs the result
over the stock mangoapp when `MANGOHUD_BUILD` points at it.
