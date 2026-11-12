# Sleep on the Snapdragon 865 (SM8250)

Notes from tracking down the battery drain asleep on a Retroid Pocket Flip 2
(Visionox panel), 2026-10-23. The kernel fixes below are in
`external-and-mods/kernel-sm8250/patches` (0017-0029) and
`dts/sm8250-retroidpocket-common.dtsi.append`. With them, s2idle is the
default sleep mode on the Retroid 865 boards (RP5, Flip 2, Mini, Mini V2;
tested on the Flip 2). The other 865 handhelds stay on standby. The SoC still
does not reach deep sleep, so there is more to gain.

## Where it stands

| | Standby | s2idle, before | s2idle, with these fixes |
|---|---|---|---|
| Drain asleep, overnight | 1.9 %/h (12.5 h, 82 → 58 %), 2.3 %/h (11.1 h) | | 1.3 %/h (12.6 h, 67 → 51 %) |
| Drain asleep, short | | ~1.5 %/h (0.67 h) | ~1.9 %/h (2.6 h at 28 → 23 %) |
| DDR while asleep | | 768 MHz | 300 MHz |
| `cxsd` / `aosd` / `ddr` counters | 0 | 0 | 0 |

The battery reports whole percent only, so short sleeps and low charge give
rough figures; the overnight ones are the ones to compare. 1.3 %/h is still
~50 mA, what an 865 draws with its CPUs off but CX, XO and DDR still up.

s2idle itself works: it enters and wakes cleanly, and the controls, Wi-Fi and
USB-C audio come back. It can be tried with `konkrctl sleep s2idle`
(`konkrctl sleep standby` goes back).

## What the fixes do

Each of these was found and checked on the device with the `rpmh_send_msg`
and `clk_prepare`/`clk_unprepare` trace events (see *How to look* below).
After all of them, APPS hands RPMh a sleep set with every BCM vote at 0 and
the XO vote (`xo.lvl`) at 0.

| Patch | What held the SoC up |
|---|---|
| 0017, 0018 | Open GENI UARTs (gamepad MCU, Bluetooth, debug console) kept their CX level and bus votes in the sleep set |
| 0023 | The same UARTs never runtime-suspended across system sleep (the PM core holds a runtime reference), so their SE clocks kept gpll0 and the XO prepared |
| 0019 | The PCIe root port vetoed D3cold, so the Wi-Fi link, its clocks (XO-fed aux clocks) and votes stayed up; now `PCIe Gen.2 x1 link up` shows on every resume |
| 0020 | The QCE crypto engine votes 393600 kBps to DDR at probe and never drops it; the path is now active-only |
| 0021, 0024 | UFS leaks: the lane clocks gained a reference every resume, and `core_clk_unipro` (`keep_link_active`) stayed prepared after every unbind, holding gpll0 and the XO |
| 0022 | The DSI PHY keeps `disp_cc_mdss_ahb_clk` prepared through sleep |
| 0025 | Going to sleep warm, the tsens lower-threshold IRQ stormed and woke s2idle at once |
| 0027-0029 | Not a drain, but s2idle broke plugging: the PMIC's cable, VBUS and CC IRQs aren't wakeup sources and their edges are lost asleep. A charger pulled asleep left the battery at "Full" and the Type-C port as a sink, so USB-C headsets got no power. The fuel gauge now asks the charger each time, and the charger and Type-C drivers read the cable again on resume |
| camcc (DT) | No camera on these handhelds, but the camera clock controller's critical `cam_cc_gdsc_clk` was a standing XO vote and its `required-opps` held MMCX |

`konkr-sleep` also knew only the 8 Elite's Wi-Fi modules (`ath12k`), so on
the 865 Wi-Fi (`ath11k_pci`) was never unloaded, in standby or in s2idle. It
now picks the `ath11k` modules on `qcom,sm8250`.

## Tried and dropped: the audio votes

The LPASS RX/TX/VA/WSA macros and the LPI pin controller hold
`LPASS_HW_MACRO`/`LPASS_HW_DCODEC` votes in the ADSP for as long as they are
bound. The Odin 3's macro patch (drop the votes in runtime suspend) and
kettlelinux 1460, 1461 and 1464 (force the macros, SoundWire masters and LPI
pin controller into runtime suspend for system sleep) do release them, as the
clock trace shows. On the 865 they break the speakers, though: the udev rule
keeps the WSA881x amps runtime-active, and when the WSA SoundWire master is
forced down and back up under them, the bus clashes on resume
(`qcom_swrm_irq_handler: SWR bus clsh detected`, `wsa881x ... Parity error
detected`). The speakers then hiss or go silent until a reboot. It didn't let
the ADSP sleep either, so all four are out. Doing this safely would mean
suspending the WSA881x amps first, or not forcing the master that feeds them.

## What is still open

1. **The ADSP never slept after boot: found, patch 0026.** Its
   `qcom_stats/adsp` entry stopped the moment the LPASS macros bound (7.2 s
   into boot; the stats count SoC ticks from power-on, ~5 s before the
   kernel). Blacklisting modules boot by boot narrowed it to `va_macro`
   alone. The ADSP answers an LPASS core vote with a client handle that the
   devote has to send back; mainline q6afe never stored it, so every devote
   failed (`cmd = 0x100f6 returned error = 0x1` in dmesg) and every
   `LPASS_HW_MACRO`/`DCODEC` vote stayed held. That is why releasing the votes
   on the Linux side made no difference. With 0026, the Odin 3 macro patch
   (votes held only while a macro is runtime-active) and the SoundWire codecs
   allowed to runtime-suspend (`70-sm8250-handhelds.rules` pins them on), the
   ADSP sleeps, also through s2idle, and the speakers still work. It saves
   only ~2 mA by itself (quiet standby, 199 vs 201 mA) and the deep sleep
   counters stay at 0, so only 0026 is in the tree for now.
2. **The booted ADSP is what keeps CX up.** Disabling nodes in the Flip 2's
   DTB, one boot each, 30 s s2idle: with the GPU, GMU, video, CDSP, SLPI,
   ADSP and sound card all off, `cxsd`, `aosd` and `ddr` count for the first
   time on Linux (DDR self-refresh, 200 MHz). The GPU and GMU off alone, or
   the CDSP and video off alone: still 0. The ADSP and sound card off alone:
   deep sleep, with the GPU and a running CDSP. The ADSP running with every
   audio client off (sound card, macros, SoundWire, LPI pinctrl, codecs) and
   even with its APR node off, so nothing on Linux talks to it: 0, though the
   ADSP itself power-collapses. Stopping it after boot doesn't release it
   either. The Flip 2's own ADSP image from Android's `modem` partition
   (`ADSP.HT.5.3-00632`, here we load the generic `ADSP.HT.5.3.c2-00082`)
   boots and plays sound but blocks the same way. Android runs the same
   firmware and gets there: the Flip 2's stock Android 13 (kernel
   4.19.157) went from 0 to 13 099 `aosd`, 1 092 `cxsd` and 1 094 `ddr`
   in ten minutes with the screen off, the last one 607 s long
   (`/sys/power/system_sleep/stats`, readable over adb without root),
   with the ADSP, CDSP and SLPI all running. So Linux misses something
   the ADSP waits for. Android also runs `tftp_server`, `rmt_storage`,
   `time_daemon`, `adsprpcd` and `adsprpcd_audiopd` (FastRPC on the
   audio PD) and the sensors stack on the SLPI. Linux only announces
   the pd-mapper's service locator over QRTR. Not it: `tqftpserv`
   started before a late ADSP start (and before an SLPI start) got no
   request from either and changed nothing. The audio PD does wait for a
   listener: `hexagonrpcd` attached with `FASTRPC_IOCTL_INIT_CREATE_STATIC`
   "audiopd" (a local `-a` option) gets file requests right away
   (`fluence_voiceplus_module.so.1`, `mmecns_module.so.1` from the `dsp`
   partition). Its buffers come from the remote heap (`rflags` 8,
   `ADSP_MMAP_REMOTE_HEAP_ADDR`), which needs what Android and kodiak
   have and our DT doesn't: an 8 MB `shared-dma-pool` as the fastrpc
   node's `memory-region` plus `qcom,vmids = <QCOM_SCM_VMID_LPASS
   QCOM_SCM_VMID_ADSP_HEAP>`. Without them the maps fail, or the SoC
   hangs. With them the audio PD loads both modules and goes idle, but
   CX still doesn't collapse. The ADSP then also hits its watchdog right
   after resume when the QCA6390 powers back on, and the system wedges
   soon after (hard reset). The SLPI's sensors PD (`hexagonrpcd -s` on
   `/dev/fastrpc-sdsp`, with Android's registry from `persist` = sda6 and
   `etc/sensors` from `vendor_a` in `super`, read-only) reads the whole
   registry and configs. It then asks for an apps-side `sns_registry`
   interface that `hexagonrpcd` doesn't have, and dies with
   `SNS_REG_INIT ... sns_registry_sensor.c:94`. It never sleeps, and
   cxsd stays 0.
   Its proxy votes are released (LCX/LMX off, handover done). Not what it
   waits for: the SLPI's `sleepstate` smp2p entry (Android's DT puts it on
   the SLPI edge only), and the FastRPC userspace Android runs on the ADSP
   (`adsprpcd`; the channel is already in our DT, and `hexagonrpcd` serving
   the `dsp` partition got no request from the ADSP in a minute; running it
   across s2idle hung the resume). The AOP won't say what the ADSP votes:
   the later SoCs' per-DRV DDR vote query (QMP `{class: ddr, res:
   drvs_ddr_votes}`) is accepted but writes nothing to the stats MSG RAM
   (0xc3f0000; aosd/cxsd/ddr records at 0x48/0x68/0x88, DDR stats at 0xb8,
   three unused type 2 entries at 0x1d0-0x1f0).
   The RP5 does get there: [mihaivladan/rp5-ufs-kernel-test](https://github.com/mihaivladan/rp5-ufs-kernel-test)
   reports 99.999 % AOSD/CXSD/DDR with the ADSP running and audio up (the
   RP5's Android ADSP image, a q6afe handle fix like 0026, the 7.3 LPASS
   macro PM-clock conversions, the ADSP started from sysfs after boot, and
   no CDSP, SLPI, venus or QCE in the DT). On the Flip 2 the same set still
   blocks: Android's ADSP, every q6afe clock and LPASS vote at enable count
   0 with the SoundWire codecs, macros and LPI pinctrl runtime-suspended, the
   CDSP, venus, videocc and QCE disabled, and the ADSP started late, all
   0. Their AOP probing also found no readable per-client vote (direct
   ARC/DDR register reads reset the SoC). Their other pieces don't apply
   either. Their RPMh regulator sleep-set patches only act on
   `regulator-state-mem`, which their DT doesn't set. LCX and LMX at 0 in
   both APPS sets (their all-states rpmhpd patch allows that): 0 over two
   hours. The ADSP's `pcie_drv` channel answers Qualcomm's v1 commands
   (ACK, status 0), but binding it, a DISABLE, or an ENABLE handoff of RC0
   before suspend: still 0. The ENABLE just makes the ADSP wake often to
   watch the link. Telling the AOP `{class: image, res: load_state, name:
   adsp, val: off}` with the ADSP still running: 0.
   Earlier, before the above: with the ADSP stopped
   (`echo stop > /sys/class/remoteproc/remoteproc2/state`), or asleep with
   the fixes above, the QCA6390 fully unpowered (Wi-Fi unloaded, Bluetooth
   unbound), the video codec unbound and the AOP's `prevent_*` flags cleared,
   the counters still stayed at 0. The APPS sleep set is clean: every BCM,
   `xo.lvl` and the cx/mx/mmcx levels are 0 at s2idle entry. The SLPI is
   never booted (its firmware is at `qcom/sm8250/flip2/slpi.mdt`, not the
   path the DT names); started by hand it runs but never sleeps, so that
   isn't it either.
3. **Leftover boot-time votes.** The sm8250 power-domain driver does not
   manage `ddr.lvl` (0x30070) or `qphy.lvl` (0x30090) (`sm8250_rpmhpds[]` has
   no `RPMHPD_QPHY`), so whatever the bootloader voted on them stays in the
   APPS DRV through every sleep. `ddr.lvl` at 0 in the sleep set (wake set at
   3) resumes fine but changes nothing. `qphy.lvl` is a dead end: the AOP
   never completes an upward `qphy.lvl` vote from APPS (an active vote of 1
   times out after 10 s, even on a fresh boot with nothing dropped before),
   while a vote of 0 is acked at once because it changes nothing. So APPS
   holds no `qphy.lvl` vote, and the resume hang with 0 in the sleep set came
   from the wake set's 1, which the RSC waits on forever. A timed-out vote
   also leaves the TCS busy until the next reboot.
4. **Stock Android does get there.** On the Flip 2's Android 13
   (`/sys/power/system_sleep/stats` and `/sys/power/rpmh_stats/master_stats`
   are readable over adb without root), one minute asleep gave cxsd 190,
   aosd 1232, ddr 192 and DDR self-refresh (`0xd3`) 192. Android also runs
   the SLPI (it sleeps, island mode too) and takes DDR down to 200 MHz; Linux
   never goes below 300 MHz, not even asleep with every APPS BCM vote at 0,
   so some other DRV still votes DDR. Not the display RSC: with its clocks on,
   both of its TCSes (DRV0 at 0xaf20000, TCS offset 0x1c00) are empty, never
   written. The APPS RSC's DRV1 (0x18210000) is access-protected: reading it
   takes the SoC down. Left: the SLPI (never booted here; started by hand it
   doesn't sleep, perhaps for want of the sensors registry Android hands it)
   and the GPU's RSC.

Measured with the session frozen and the screen off, the board itself is not
the drain: the gamepad MCU, touch, Bluetooth and fan each change the battery
current by less than about 5 mA.

## How to look

All as root, debugfs mounted.

- Sleep counters: `/sys/kernel/debug/qcom_stats/{cxsd,aosd,ddr,adsp,cdsp}` and
  `ddr_stats` (the DDR frequency rows show where DDR sat while asleep).
  They go up the first time the SoC gets there, so a 30 s sleep is enough.
- What APPS leaves voted: enable `rpmh/rpmh_send_msg` in
  `/sys/kernel/tracing`, suspend, and read the `[sleep]` and `[wake]` lines
  written at entry. Map the addresses with `/sys/kernel/debug/cmd-db`
  (`0x50000` MC0, `0x50004` SH0, `0x300a0` `xo.lvl`, ...). A BCM at
  `0x40000000` is valid and 0. No `xo.lvl` write at all means a clock under
  `bi_tcxo` is still prepared.
- Who holds the XO: snapshot `/sys/kernel/debug/clk/clk_summary`, trace
  `clk/clk_prepare` and `clk/clk_unprepare` over a suspend, and walk the
  prepared children of `bi_tcxo` at `machine_suspend` (the events fire on the
  0↔1 transitions only).
- Battery current: `/sys/class/power_supply/battery/current_now` (µA). Awake
  it swings by 100+ mA with Steam running; compare parts in a quiet standby
  (`KONKR_STANDBY_KEEP_WIFI=1 /usr/lib/konkr/konkr-standby`, wake with
  SIGUSR1), in on/off/on/off rounds.

- An ARC vote in the sleep set without a kernel rebuild: a small module that
  looks up the `qcom,sm8250-rpmhpd` device (a child of `apps_rsc`) and calls
  `rpmh_write()` for `RPMH_WAKE_ONLY_STATE` and `RPMH_SLEEP_STATE` with the
  address from `cmd_db_read_addr("ddr.lvl")`. ARC values are level indices
  (the `cmd-db` aux list), not raw levels.
- Which audio part keeps the ADSP up: a `blacklist` file in
  `/etc/modprobe.d` and a reboot, watching `qcom_stats/adsp`'s accumulated
  time while idle. Unloading the audio stack with rmmod wedged the kernel.

## Pitfalls

- Unbinding the UFS host with clock scaling on oopses in the devfreq worker
  (`ufshcd_devfreq_scale`). Turn `clkscale_enable` off first, as
  `konkr-sleep` does.
- The RTC alarm does not wake the 865 from s2idle; the power key does
  (`konkr-sleep` also arms the lid, untested).
- Unloading `ath11k` over SSH cuts the connection: Wi-Fi is the only link.
