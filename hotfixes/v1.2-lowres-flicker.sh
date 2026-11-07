#!/bin/bash
# v1.2 hotfix: games flicker between full screen and the top-left corner when
# they run below 1080p. Fixed properly in v1.3, this just patches v1.2.
#
# Run in Konsole (Desktop Mode):
#   curl -fsSL https://raw.githubusercontent.com/hashtagbasit/Zaviya/main/hotfixes/v1.2-lowres-flicker.sh | bash
set -euo pipefail

SESSION=/usr/lib/steamos/gamescope-session
BACKUP=$SESSION.before-flicker-fix

if [[ ! -f $SESSION ]]; then
  echo "Can't find $SESSION. Is this Zaviya?" >&2
  exit 1
fi

if ! grep -q -- '^  --force-windows-fullscreen$' "$SESSION"; then
  echo "Already fixed, nothing to do."
  exit 0
fi

if ! sudo -n true 2>/dev/null; then
  echo "This needs your password. If you never set one, press Ctrl+C,"
  echo "run 'passwd' first, then run this again."
fi

sudo cp -n "$SESSION" "$BACKUP"
sudo sed -i '/^  --force-windows-fullscreen$/d' "$SESSION"

if grep -q -- '--force-windows-fullscreen' "$SESSION"; then
  echo "Something went wrong, the original is at $BACKUP" >&2
  exit 1
fi

echo
echo "Done! Switch back to Game Mode and games will scale properly below 1080p."
echo "(Undo: sudo cp $BACKUP $SESSION)"
