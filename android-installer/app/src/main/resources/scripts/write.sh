# Writes the image to the microSD card, then reads it back.
ZSTD_SRC=@ZSTD@
IMG=@IMAGE@
IMG_SHA=@IMAGE_SHA@
IMG_BYTES=@IMAGE_BYTES@
SD_NAME=@SD_NAME@
SD_BYTES=@SD_BYTES@
MIN_BYTES=@MIN_BYTES@
W=/data/local/tmp

# Only a whole mmcblk disk, and only the one the app showed.
echo "$SD_NAME" | grep -Eq '^mmcblk[0-9]+$' || fail "That isn't a microSD card."
DEV=$SD_NAME
TARGET=/dev/block/$DEV
[ "$(cat "/sys/block/$DEV/device/type" 2>/dev/null || :)" = SD ] || fail "That isn't a microSD card."
SIZE=$(expr "$(cat "/sys/block/$DEV/size")" '*' 512)
[ "$SIZE" = "$SD_BYTES" ] || fail "This isn't the card the app checked."
num_ge "$SIZE" "$MIN_BYTES" || fail "That card looks too small."
[ -b "$TARGET" ] || fail "The card isn't there."
# Never storage the system runs from.
if grep -E "^/dev/block/$DEV[^ ]* (/|/system|/vendor|/data|/metadata|/mnt/expand/[^ ]*) " /proc/mounts >/dev/null; then
  fail "Android is using this card as its own storage."
fi

# zstd runs from /data/local/tmp.
ZSTD=$W/zaviya-zstd
cp "$ZSTD_SRC" "$ZSTD" || fail "Couldn't set up the unpacker."
chmod 755 "$ZSTD" || fail "Couldn't set up the unpacker."
"$ZSTD" --version >/dev/null 2>&1 || fail "The unpacker doesn't run on this device."

status checking 0 "$IMG_BYTES"
[ -f "$IMG" ] || fail "The download is missing."
[ "$(wc -c < "$IMG" | tr -d ' ')" = "$IMG_BYTES" ] || fail "The download is the wrong size."
(sha "$IMG" > "$W/zaviya-img.sha") &
HP=$!
track $HP "sha256sum" checking "$IMG_BYTES" rchar
wait $HP || fail "Couldn't read the download."
[ "$(cat "$W/zaviya-img.sha")" = "$IMG_SHA" ] || fail "The download is damaged. Download it again."
rm -f "$W/zaviya-img.sha"

# Unpack once to learn the size and the hash of the image itself.
FIFO=$W/zaviya-fifo
rm -f "$FIFO"
mkfifo "$FIFO" || fail "Couldn't prepare the check."
sha256sum < "$FIFO" > "$W/zaviya-raw.sha" &
SHP=$!
("$ZSTD" -dc --long=31 "$IMG" | tee "$FIFO" | wc -c > "$W/zaviya-raw.bytes") &
ZP=$!
track $ZP "$IMG" checking "$IMG_BYTES" rchar
wait $ZP || fail "The image can't be unpacked."
wait $SHP || fail "Couldn't check the image."
rm -f "$FIFO"
RAW_SHA=$(cut -d' ' -f1 "$W/zaviya-raw.sha")
RAW_BYTES=$(tr -d ' \n' < "$W/zaviya-raw.bytes")
rm -f "$W/zaviya-raw.sha" "$W/zaviya-raw.bytes"
[ -n "$RAW_SHA" ] && [ -n "$RAW_BYTES" ] || fail "Couldn't read the image."
num_ge "$SIZE" "$RAW_BYTES" || fail "The card is too small for this image."

status unmounting
CARD_MM=$(cat "/sys/block/$DEV/dev")
for p in /sys/block/$DEV/${DEV}p*; do
  if [ -r "$p/dev" ]; then CARD_MM="$CARD_MM $(cat "$p/dev")"; fi
done
on_card() { case " $CARD_MM " in *" $1 "*) return 0 ;; esac; return 1; }
card_mounts() {
  while read -r _ _ mm _ mp _; do
    if on_card "$mm"; then echo "$mp"; fi
  done < /proc/self/mountinfo
}
# Let Android's storage service unmount it, so apps using it stop first.
for v in $(sm list-volumes public 2>/dev/null | cut -d' ' -f1); do
  if on_card "$(echo "${v#public:}" | tr ',_' '::')"; then sm unmount "$v" 2>/dev/null || :; fi
done
n=0
while [ -n "$(card_mounts)" ] && [ $n -lt 10 ]; do sleep 1; n=$((n + 1)); done
for m in $(card_mounts); do umount "$m" 2>/dev/null || :; done
[ -z "$(card_mounts)" ] || fail "Android is still using the card. Eject it in Settings, then try again."

# Keep little unwritten data in memory, so a slow card can't stall the system.
VM=/proc/sys/vm
OLD_R=$(cat $VM/dirty_ratio); OLD_BR=$(cat $VM/dirty_background_ratio)
OLD_B=$(cat $VM/dirty_bytes); OLD_BB=$(cat $VM/dirty_background_bytes)
restore_vm() {
  if [ "$OLD_B" != 0 ]; then echo "$OLD_B" > $VM/dirty_bytes; else echo "$OLD_R" > $VM/dirty_ratio; fi
  if [ "$OLD_BB" != 0 ]; then echo "$OLD_BB" > $VM/dirty_background_bytes; else echo "$OLD_BR" > $VM/dirty_background_ratio; fi
}
trap 'restore_vm 2>/dev/null || :; cleanup' EXIT
echo 16777216 > $VM/dirty_background_bytes || fail "Couldn't tune memory for writing."
echo 67108864 > $VM/dirty_bytes || fail "Couldn't tune memory for writing."

status writing 0 "$RAW_BYTES"
("$ZSTD" -dc --long=31 "$IMG" | dd of="$TARGET" bs=4194304 2>/dev/null) &
WP=$!
track $WP "of=$TARGET" writing "$RAW_BYTES" wchar
wait $WP || fail "Writing to the card failed. Check the card and try again."
sync || fail "The card didn't finish saving."

status verifying 0 "$RAW_BYTES"
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || :
(head -c "$RAW_BYTES" "$TARGET" | sha256sum | cut -d' ' -f1 > "$W/zaviya-back.sha") &
RP=$!
track $RP "$TARGET" verifying "$RAW_BYTES" rchar
wait $RP || fail "Couldn't read the card back."
[ "$(cat "$W/zaviya-back.sha")" = "$RAW_SHA" ] || fail "The card didn't read back correctly. Try another card."
rm -f "$W/zaviya-back.sha"
put image_sha "$RAW_SHA"
status done "$RAW_BYTES" "$RAW_BYTES" "Written and checked"
