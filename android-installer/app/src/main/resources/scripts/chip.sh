# Wrong chip: stop before touching anything.
CHIP_MODELS=@CHIP_MODELS@
CHIP_PLATFORM=@CHIP_PLATFORM@
check_chip() {
  m=$(getprop ro.soc.model | tr a-z A-Z)
  p=$(getprop ro.board.platform | tr A-Z a-z)
  ok=0
  for x in $CHIP_MODELS; do [ "$m" = "$x" ] && ok=1; done
  [ $ok = 1 ] || fail "This isn't the chip the file is for."
  [ -z "$p" ] || [ "$p" = "$CHIP_PLATFORM" ] || fail "This isn't the chip the file is for."
}
check_chip
