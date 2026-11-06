# Saves both bootloader partitions and (in flash mode) writes OpenABL to both.
MODE=@MODE@
ELF_SRC=@ELF@
ELF_SHA=@ELF_SHA@
ELF_BYTES=@ELF_BYTES@
BK=@BACKUP_DIR@
STAMP=@STAMP@
W=/data/local/tmp

status checking
ELF=$W/zaviya-abl.elf
if [ "$MODE" = flash ]; then
  cp "$ELF_SRC" "$ELF" || fail "Couldn't read the boot menu file."
  [ "$(wc -c < "$ELF" | tr -d ' ')" = "$ELF_BYTES" ] || fail "The boot menu file is the wrong size."
  [ "$(sha "$ELF")" = "$ELF_SHA" ] || fail "The boot menu file doesn't match its hash."
  [ "$(head -c 4 "$ELF" | tail -c 3)" = ELF ] || fail "The boot menu file isn't an ELF file."
  [ "$ELF_BYTES" -le "$ZA" ] && [ "$ELF_BYTES" -le "$ZB" ] || fail "The boot menu file is larger than the partition."
fi

backup_ok() { # both files there, not empty, and listed in SHA256SUMS
  [ -s "$BK/abl_a.img" ] && [ -s "$BK/abl_b.img" ] && [ -s "$BK/SHA256SUMS" ] || return 1
  (cd "$BK" && sha256sum -c SHA256SUMS >/dev/null 2>&1)
}
# A saved copy is kept when each partition is still what was saved, or is already OpenABL.
keep_backup() {
  backup_ok || return 1
  for s in a b; do
    cur=$(sha256sum < "$(part $s)" | cut -d' ' -f1)
    [ "$cur" = "$(sha "$BK/abl_$s.img")" ] && continue
    [ "$MODE" = flash ] && [ "$(shan "$(part $s)" "$ELF_BYTES")" = "$ELF_SHA" ] && continue
    return 1
  done
  return 0
}
make_backup() {
  if [ -e "$BK" ]; then
    mkdir -p "$BK/older-$STAMP" || fail "Couldn't set aside the older copy."
    for f in abl_a.img abl_b.img SHA256SUMS info.txt; do
      if [ -e "$BK/$f" ]; then mv "$BK/$f" "$BK/older-$STAMP/$f" || fail "Couldn't set aside the older copy."; fi
    done
  fi
  mkdir -p "$BK" || fail "Couldn't make the backup folder."
  for s in a b; do
    status working 0 0 "Saving abl_$s"
    dd if="$(part $s)" of="$BK/abl_$s.img" bs=4096 2>/dev/null || fail "Couldn't save abl_$s."
  done
  sync || fail "The copy didn't finish saving."
  status working 0 0 "Checking the copy"
  for s in a b; do
    [ -s "$BK/abl_$s.img" ] || fail "The saved copy of abl_$s is empty."
    [ "$(sha "$BK/abl_$s.img")" = "$(sha256sum < "$(part $s)" | cut -d' ' -f1)" ] || fail "The saved copy of abl_$s doesn't match the partition."
  done
  (cd "$BK" && sha256sum abl_a.img abl_b.img > SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null 2>&1) || fail "The copy's checksums don't check."
  {
    echo "soc=$(getprop ro.soc.model)"
    echo "platform=$(getprop ro.board.platform)"
    echo "device=$(getprop ro.product.manufacturer) $(getprop ro.product.model)"
    echo "slot=$(getprop ro.boot.slot_suffix)"
    echo "saved=$STAMP"
  } > "$BK/info.txt" || fail "Couldn't write the copy's notes."
}
if keep_backup; then
  put backup kept
else
  make_backup
  put backup new
fi
# Hand the folder to the media owner so Files can show it.
chown -R 1023:1023 "$BK" 2>/dev/null || :
chmod -R u=rwX,g=rwX,o= "$BK" 2>/dev/null || :
restorecon -R "$BK" 2>/dev/null || :
put backup_a "$(wc -c < "$BK/abl_a.img" | tr -d ' ')"
put backup_b "$(wc -c < "$BK/abl_b.img" | tr -d ' ')"

if [ "$MODE" = backup ]; then
  status done 0 0 "Copy saved"
  exit 0
fi

write_slot() { # slot; writes the boot menu, reads it back, once more if it differs
  ws_dev=$(part $1)
  ws_n=0
  while [ $ws_n -lt 2 ]; do
    ws_n=$((ws_n + 1))
    status working 0 0 "Writing abl_$1"
    dd if="$ELF" of="$ws_dev" bs=4096 conv=notrunc 2>/dev/null || continue
    sync || continue
    [ "$(shan "$ws_dev" "$ELF_BYTES")" = "$ELF_SHA" ] && return 0
  done
  return 1
}
put_back() { # slot; writes the saved copy back
  dd if="$BK/abl_$1.img" of="$(part $1)" bs=4096 conv=notrunc 2>/dev/null || return 1
  sync || return 1
  [ "$(sha256sum < "$(part $1)" | cut -d' ' -f1)" = "$(sha "$BK/abl_$1.img")" ]
}
for s in $(slot_order); do
  if write_slot $s; then
    put "slot_$s" ok
    continue
  fi
  put "slot_$s" failed
  if put_back $s; then
    fail "abl_$s didn't read back right. The saved copy is back in place."
  fi
  fail "abl_$s didn't read back right, and the saved copy didn't go back. Restore it from the app."
done
rm -f "$ELF"
status done 0 0 "Both slots hold the boot menu"
