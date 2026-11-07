# Android apps (experimental)

Android apps run through Lepton (the Android layer the Steam Frame uses), with the Google Play Store built in. There's a Google Play Store title in your library after first login.

Everything you install, from the Play Store or as an `.apk`/`.apkm`/`.xapk`/`.apks` (open it in Dolphin or drop it in `~/Android/Inbox`), shows up as its own Steam title with its icon. The first launch downloads Lepton through Steam.

Apps run fullscreen with the touchscreen, the controller (as an Xbox pad) and a touch keyboard. Back/Home sit at the bottom left of Android's nav bar, Recents at the bottom right. Leave with Steam > Exit Game.

```
konkr-apk install Xbox.apkm   # same as opening it in Dolphin
konkr-apk list
konkr-apk remove com.gamepass
```

Games with anti-cheat that blocks emulators won't run, and a few apps may still crash. How it works is in [external-and-mods/konkr-android](../external-and-mods/konkr-android/README.md).
