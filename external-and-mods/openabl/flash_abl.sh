#!/system/bin/sh

{ getprop ro.soc.model; getprop ro.board.platform; } | grep -qxE '@ABL_MATCH@' && dd if="/sdcard/openabl/abl_signed-@SOC@.elf" of="/dev/block/by-name/abl_a" bs=1M
{ getprop ro.soc.model; getprop ro.board.platform; } | grep -qxE '@ABL_MATCH@' && dd if="/sdcard/openabl/abl_signed-@SOC@.elf" of="/dev/block/by-name/abl_b" bs=1M
