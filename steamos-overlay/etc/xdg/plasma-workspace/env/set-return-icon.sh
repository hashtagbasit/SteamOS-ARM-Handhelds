#!/bin/bash
# Always put "Return to Gaming Mode" on the desktop (this is not a Jupiter).
# Icon is the same steamos-gamemode mark used on this handheld's current desktop.
set -eu

dest_icon="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
mkdir -p "$dest_icon"
if [[ -f /usr/share/icons/hicolor/scalable/apps/steamos-gamemode.svg ]]; then
  ln -sfn /usr/share/icons/hicolor/scalable/apps/steamos-gamemode.svg \
    "$dest_icon/steamos-gamemode.svg"
fi

mkdir -p "$HOME/Desktop"
if [[ -f /etc/skel/Desktop/Return.desktop ]]; then
  cp /etc/skel/Desktop/Return.desktop "$HOME/Desktop/Return.desktop"
  chmod 0755 "$HOME/Desktop/Return.desktop"
fi
rm -f "$HOME/Desktop/Decky Loader.desktop" \
      "$HOME/Desktop/install-decky.desktop"

# "Record Logs" is put on the desktop once, so devices that received it through
# an update get the icon too; removing it afterwards sticks.
logs_src="/etc/skel/Desktop/Record Logs.desktop"
logs_mark="${XDG_STATE_HOME:-$HOME/.local/state}/zaviya/record-logs-icon"
if [[ -f "$logs_src" && ! -e "$logs_mark" ]]; then
  cp "$logs_src" "$HOME/Desktop/Record Logs.desktop"
  chmod 0755 "$HOME/Desktop/Record Logs.desktop"
  mkdir -p "$(dirname "$logs_mark")"
  : >"$logs_mark"
fi
