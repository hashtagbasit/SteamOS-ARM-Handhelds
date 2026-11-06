# The two bootloader partitions, found by exact name and checked.
BYNAME_DIRS="/dev/block/by-name /dev/block/bootdevice/by-name"
slot_dev() {
  for d in $BYNAME_DIRS; do
    if [ -e "$d/abl_$1" ]; then echo "$d/abl_$1"; return 0; fi
  done
  return 0
}
SA=$(slot_dev a)
SB=$(slot_dev b)
[ -n "$SA" ] && [ -n "$SB" ] || fail "The bootloader partitions weren't found."
RA=$(readlink -f "$SA"); RB=$(readlink -f "$SB")
[ "$RA" != "$RB" ] || fail "The two bootloader partitions are the same."
case $RA in /dev/block/*) ;; *) fail "Unexpected bootloader partition." ;; esac
case $RB in /dev/block/*) ;; *) fail "Unexpected bootloader partition." ;; esac
[ -b "$RA" ] && [ -b "$RB" ] || fail "The bootloader partitions aren't block devices."
ZA=$(blockdev --getsize64 "$RA" 2>/dev/null || :)
ZB=$(blockdev --getsize64 "$RB" 2>/dev/null || :)
for z in "$ZA" "$ZB"; do
  case $z in ''|*[!0-9]*) fail "Couldn't read a partition size." ;; esac
  [ "$z" -gt 0 ] && [ "$z" -le 16777216 ] || fail "A bootloader partition has an odd size."
done
# sha of the first N bytes of a file or partition.
shan() { head -c "$2" "$1" | sha256sum | cut -d' ' -f1; }
part() { if [ "$1" = a ]; then echo "$RA"; else echo "$RB"; fi; }
psize() { if [ "$1" = a ]; then echo "$ZA"; else echo "$ZB"; fi; }
# Write the non-active slot first, the active one last.
slot_order() { case $(getprop ro.boot.slot_suffix) in _b) echo "a b" ;; *) echo "b a" ;; esac; }
