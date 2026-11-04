#!/bin/bash
# Tester tool for the AYANEO Pocket S (SM8550): the two buttons by the right
# stick and LC/RC give no evdev events, so find out what the pad sends on its
# hidraw nodes. Run on the device as root (Desktop Mode, Konsole):
#
#   sudo bash ayaneo-hidraw-capture.sh
#
# It stops InputPlumber (which grabs the pad), saves the HID report
# descriptor of every AYANEO node, then records each node 3 times: nothing
# pressed (6 s), then the two right-stick buttons (10 s), then LC and RC
# (10 s). Send the whole /tmp/ayaneo-hid folder (it is also tarred to
# /tmp/ayaneo-hid.tar.gz).
set -u
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0"; exit 1; }
out=/tmp/ayaneo-hid
rm -rf "$out"; mkdir -p "$out"
systemctl stop inputplumber 2>/dev/null
trap 'systemctl start inputplumber 2>/dev/null' EXIT

nodes=()
for h in /sys/class/hidraw/hidraw*; do
  [[ -e $h ]] || continue
  n=$(basename "$h")
  uevent=$(cat "$h/device/uevent" 2>/dev/null)
  grep -qiE 'HID_ID=0003:0000(4001|1C4F):' <<<"$uevent" || continue
  nodes+=("$n")
  { echo "== $n"; echo "$uevent"; echo; echo "-- report descriptor"; xxd "$h/device/report_descriptor"; } >"$out/$n.info"
  cat "$h/device/report_descriptor" >"$out/$n.rdesc"
done
if ((${#nodes[@]} == 0)); then
  echo "no AYANEO hidraw node found (4001:0428 / 1c4f:0002); sending the list below instead"
  ls -l /dev/hidraw* /sys/class/hidraw/ >"$out/none.txt" 2>&1
  cat /proc/bus/input/devices >>"$out/none.txt"
  exit 1
fi
cat /proc/bus/input/devices >"$out/proc-bus-input-devices.txt"
echo "nodes: ${nodes[*]}"

rec() { # rec <label> <seconds>
  local label=$1 secs=$2 n
  echo ">>> $label for $secs s: START NOW"
  for n in "${nodes[@]}"; do
    timeout "$secs" cat "/dev/$n" >"$out/$n.$label.bin" 2>/dev/null &
  done
  wait
  for n in "${nodes[@]}"; do xxd -c 32 "$out/$n.$label.bin" >"$out/$n.$label.hex"; done
  echo "<<< done"
}
rec idle 6
rec stick-buttons 10
rec lc-rc 10
for n in "${nodes[@]}"; do wc -c "$out/$n".*.bin; done
tar -C /tmp -czf /tmp/ayaneo-hid.tar.gz ayaneo-hid
echo "send /tmp/ayaneo-hid.tar.gz"
