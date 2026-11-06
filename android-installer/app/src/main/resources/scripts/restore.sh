# Writes the saved bootloader copies back to both partitions.
BK=@BACKUP_DIR@

status checking
for f in abl_a.img abl_b.img SHA256SUMS info.txt; do
  [ -s "$BK/$f" ] || fail "The saved copy has no $f."
done
grep -qxF "soc=$(getprop ro.soc.model)" "$BK/info.txt" || fail "The saved copy is from another chip."
(cd "$BK" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || fail "The saved copy doesn't match its checksums."
for s in a b; do
  grep -q " abl_$s.img\$" "$BK/SHA256SUMS" || fail "The checksums don't list abl_$s.img."
  [ "$(wc -c < "$BK/abl_$s.img" | tr -d ' ')" = "$(psize $s)" ] || fail "The saved copy of abl_$s doesn't fit its partition."
done
for s in $(slot_order); do
  status working 0 0 "Restoring abl_$s"
  dd if="$BK/abl_$s.img" of="$(part $s)" bs=4096 conv=notrunc 2>/dev/null || fail "Couldn't write abl_$s."
  sync || fail "The partition didn't finish saving."
  [ "$(sha256sum < "$(part $s)" | cut -d' ' -f1)" = "$(sha "$BK/abl_$s.img")" ] || fail "abl_$s didn't read back right."
  put "slot_$s" ok
done
status done 0 0 "Both slots are restored"
