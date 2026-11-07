# konkr-android

Files layered over Lepton's Android image (the Android layer, Steam app
3029110) for `konkr-apk` apps. Installed to `/usr/share/konkr-android`;
`konkr-apk` hands the dirs to Lepton, which bind-mounts every file over the
Android rootfs. Steam's own Android games keep the stock image.

## payload/common

| File | Why |
| --- | --- |
| `system/product/priv-app/Phonesky` | Play Store (from MindTheGapps 14: the 11 build has no arm64 libs) |
| `system/product/priv-app/PrebuiltGmsCore`, `system/system_ext/priv-app/GoogleServicesFramework`, permission/sysconfig XMLs | Play services (MindTheGapps 11) |
| `system/product/app/SimpleKeyboard` | Lepton ships no keyboard (Simple Keyboard, F-Droid) |
| `system/etc/permissions/android.software.freeform_window_management.xml` | empty: Waydroid opens every app as a freeform window, whose caption bar crashes apps like Instagram |
| `system/usr/keylayout/Vendor_28de_Product_11ff.kl` | Steam's virtual pad as an Xbox 360 pad; Generic.kl maps the triggers to the right stick |

Binaries come from `./build-payload.sh`; the text files are in git.

## payload/lepton-&lt;version&gt;

Lepton comments services out of `SystemServer`. Normal apps and Play
services crash without some of them, so `framework/restore-services.py`
starts clipboard, restrictions, biometric + auth, NSD, cross-profile apps and
hardware properties again (smali edit of `services.jar`). Everything compiled
against the old jar must be rebuilt too, or zygote re-dexopts system_server
before installd is up and dies: `framework/compile-odex.sh` does that inside
Android with its own dex2oat.

This is tied to one Lepton Android image (`images/version.txt`); `konkr-apk`
only uses the dir matching the installed one. After Steam updates it, run
`framework/build-framework.sh` with the device on the network and Android
running, then rebuild the image.

## What konkr-apk does at run time

Not files, but part of the same fixes (see `sm8650-overlay/usr/bin/konkr-apk`):

- one shared Android (`konkr-android.service`) with its data kept, every
  installed app a Steam title with its icon
- binder in the kernel (`kernel-sm8650/steamos.config`)
- unlimited stack rlimit for the container: legacy mmap layout below 2^47,
  or LuaJIT (many Unity games) can't start on our 52-bit VA kernel
- the host's `/dev/input` mounted, Steam's current virtual pad linked in
- touch keyboard selected, "setup complete" set (else Android ignores Home)
- gamescope patches: Android window gets the Steam title's app id, is
  reported to Steam, gets real touch (not click emulation)
