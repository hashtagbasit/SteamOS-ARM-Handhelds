# The bottom screen (AYN Thor, AYANEO Pocket DS)

On the dual screen devices the game runs on the top screen and the bottom one gets a small dashboard in Game Mode. As far as I know nobody has done this on SteamOS before.

What's on it:

- buttons for Steam, Quick Access, the keyboard and screenshots. They open on the top screen, so you don't have to remember the button combos
- the performance profile (Silent, Balanced, Turbo) and fan boost
- brightness for each screen, volume and mute
- clock, battery, CPU/GPU temps, GPU clock and fan speed
- your own apps. Tap **Add apps**, pick what you want and it runs full screen on the bottom screen

Tap a running app to switch to it, hold it to close it. Swiping up from the bottom edge always gets you back to the dashboard.

Touching the bottom screen doesn't do anything to the game, and Steam's brightness slider controls the top screen.

In Desktop Mode both screens work as one desktop and each touchscreen stays on its own screen.

## Turning it off

Put `"enabled": false` in `~/.config/steamos-arm/bottom-screen.json` and go back to Game Mode.

## How it works

Game Mode's gamescope keeps the top screen and hands the bottom panel over (a DRM lease) to a second, small gamescope, which runs the dashboard. The code is in `dualscreen-overlay/`, the lease part is in our gamescope in `external-and-mods/gamescope/`.
