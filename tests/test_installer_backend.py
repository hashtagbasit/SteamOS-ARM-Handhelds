"""Tests for the installer's non-window half (installer_backend, installer_pad,
zaviya-install-start, seed-installer-shortcut). Run:
    python3 -m unittest tests.test_installer_backend
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UFS = ROOT / "external-and-mods" / "ufs-install"
sys.path.insert(0, str(UFS))

import installer_backend as ib  # noqa: E402
import installer_pad as ip  # noqa: E402

ICON = "/usr/share/zaviya-install/art/installer-icon.png"
VDF = ROOT / "external-and-mods" / "NO_Steam" / "no_steam_games" / "shortcuts_vdf.py"
FP = "0123456789abcdef"

GOOD = {
    "MIN_ANDROID_GIB": "16", "MAX_ANDROID_GIB": "202", "RECOMMENDED_ANDROID_GIB": "64",
    "ORIG_ANDROID_GIB": "240", "BOOT_PART_GIB": "2", "ROOT_PART_GIB": "20",
    "DISK_TOTAL_GIB": "256.0", "TABLE_FINGERPRINT": FP, "EXISTING_INSTALL": "0",
    "TABLET": "0", "RUNNING_FROM_SD": "1", "MODE": "fresh",
}

G = "\033[1;32m[ufs]\033[0m "
R = "\033[1;31m[ufs] ERROR:\033[0m "


def rsync(pct):
    return f"\r  {pct * 1000000:>14,} {pct:>3}%   85.00MB/s    0:00:10 (xfr#5, to-chk=10/100)"


def log_upto(stage, pct=None, home="copying /home (games included)", reinstall=False):
    lines = [G + "KONKR Pocket FIT: internal disk /dev/sda (256.0 GiB, 4096-byte sectors)\n"]
    seq = []
    if not reinstall:
        seq.append(("repartition", G + "repartitioning (one write; the old table goes to /boot/ufs-backup first)\n"))
    seq += [("format", G + "formatting\n"),
            ("system", G + "copying the system (a few minutes)\n"),
            ("home", G + home + "\n"),
            ("kernel", G + "installing KERNEL (root=PARTLABEL=STORAGE)\n"),
            ("check", G + "checking the result\n"),
            ("done", "\n" + G + "done. Zaviya is on internal storage.\n")]
    out = "".join(lines)
    for key, line in seq:
        out += line
        if key == stage:
            if pct is not None:
                out += "".join(rsync(p) for p in range(0, pct + 1, 3)) + rsync(pct) + "\n"
            break
    return out


class ParseProbe(unittest.TestCase):
    def test_parse(self):
        d = ib.parse_probe("junk\nA=1\n  B=two words \n=x\nlower=1\nC=\n\x1b[0mD=4\n")
        self.assertEqual(d, {"A": "1", "B": "two words", "C": ""})

    def test_good(self):
        p = ib.Probe.from_keys(GOOD)
        self.assertIsNone(p.error)
        self.assertEqual((p.min_gib, p.max_gib, p.recommended_gib), (16, 202, 64))
        self.assertEqual(p.fingerprint, FP)
        self.assertEqual(p.disk_total_gib, 256)
        self.assertTrue(p.running_from_removable)
        self.assertFalse(p.existing_install)
        self.assertFalse(p.tablet)
        self.assertFalse(p.unsupported)

    def test_flags(self):
        p = ib.Probe.from_keys({**GOOD, "EXISTING_INSTALL": "1", "TABLET": "1", "RUNNING_FROM_SD": "0"})
        self.assertTrue(p.existing_install and p.tablet)
        self.assertFalse(p.running_from_removable)

    def test_errors(self):
        self.assertEqual(ib.Probe.from_keys({"ERROR": "no internal disk"}).error, "no internal disk")
        for k in ("MIN_ANDROID_GIB", "MAX_ANDROID_GIB", "RECOMMENDED_ANDROID_GIB", "ORIG_ANDROID_GIB",
                  "BOOT_PART_GIB", "ROOT_PART_GIB", "DISK_TOTAL_GIB", "TABLE_FINGERPRINT"):
            d = dict(GOOD)
            del d[k]
            self.assertIsNotNone(ib.Probe.from_keys(d).error, k)
        for bad in ("abc", "-4", "", "1.5"):
            self.assertIsNotNone(ib.Probe.from_keys({**GOOD, "MAX_ANDROID_GIB": bad}).error, bad)
        for fp in ("0123456789ABCDEF", "0123456789abcde", "0123456789abcdef0", "zzzzzzzzzzzzzzzz", ""):
            self.assertIsNotNone(ib.Probe.from_keys({**GOOD, "TABLE_FINGERPRINT": fp}).error, fp)
        self.assertIsNotNone(ib.Probe.from_keys({}).error)
        self.assertIsNotNone(ib.Probe.from_keys({**GOOD, "MODE": "occupied", "OCCUPIED": "x"}).error)
        self.assertIsNotNone(ib.Probe.from_keys({**GOOD, "MODE": "toosmall"}).error)

    def test_home(self):
        p = ib.Probe.from_keys(GOOD)
        self.assertEqual(ib.zaviya_home_gib(p, 64), 240 - 64 - 2 - 20)
        self.assertGreaterEqual(ib.zaviya_home_gib(p, p.max_gib), 16)
        self.assertEqual(ib.zaviya_home_gib(p, 10 ** 6), 0)

    def test_home_matches_partition_plan(self):
        spec = importlib.util.spec_from_file_location("up_t", UFS / "ufs-partition.py")
        up = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(up)
        ss, start = 4096, 524288
        last = int(226.2 * up.GIB / ss) - 6
        ud = {"start": start, "size": last + 1 - start}
        t = {"sectorsize": ss, "lastlba": last}
        mx = up.max_android_gib(t, ud, 20)
        avail = (last + 1 - start) * ss / up.GIB
        p = ib.Probe.from_keys({**GOOD, "MAX_ANDROID_GIB": str(mx), "ORIG_ANDROID_GIB": f"{avail:.1f}".split(".")[0],
                                "AVAILABLE_GIB": f"{avail:.1f}"})
        for a in (16, 64, mx):
            real = up.plan(t, ud, a, 20)["home_gib"]
            mine = ib.zaviya_home_gib(p, a)
            self.assertLessEqual(mine, real)
            self.assertLess(real - mine, 1.1)


class DeviceChecks(unittest.TestCase):
    @staticmethod
    def runner(src="/dev/mmcblk0p2", disk="mmcblk0"):
        def run(cmd):
            return {"findmnt": src + "\n", "lsblk": disk + "\n"}[cmd[0]]
        return run

    def test_unsupported(self):
        ok = "qcom,sm8650\0"
        real = lambda p: "/sys/devices/platform/x/mmc_host/mmc0"
        self.assertFalse(ib.install_unsupported(lambda: ok, self.runner(), real))
        self.assertTrue(ib.install_unsupported(lambda: "qcom,sm8250\0", self.runner(), real))
        self.assertTrue(ib.install_unsupported(lambda: "lenovo,baldur\0qcom,sm8750\0", self.runner(), real))
        self.assertTrue(ib.install_unsupported(lambda: ok, self.runner("/dev/sda3", "sda"), real))
        self.assertTrue(ib.install_unsupported(lambda: ok, lambda c: "", real))
        usb = lambda p: "/sys/devices/pci/usb2/2-1/host0/block/sda"
        self.assertFalse(ib.install_unsupported(lambda: ok, self.runner("/dev/sda3", "sda"), usb))

    def test_removable(self):
        real = lambda p: "/sys/devices/x"
        self.assertTrue(ib.running_from_removable_media(self.runner(), real))
        self.assertFalse(ib.running_from_removable_media(self.runner("/dev/sda9", "sda"), real))


class UnitState(unittest.TestCase):
    def test_all(self):
        f = ib.unit_state
        self.assertEqual(f({}), "idle")
        self.assertEqual(f({"LoadState": "not-found", "ActiveState": "inactive"}), "idle")
        self.assertEqual(f({"LoadState": "loaded", "ActiveState": "failed", "SubState": "failed"}), "failed")
        self.assertEqual(f({"LoadState": "loaded", "ActiveState": "active", "SubState": "running"}), "running")
        self.assertEqual(f({"LoadState": "loaded", "ActiveState": "activating", "SubState": "start"}), "running")
        self.assertEqual(f({"LoadState": "loaded", "ActiveState": "active", "SubState": "exited"}), "done")
        self.assertEqual(f({"LoadState": "loaded", "ActiveState": "inactive", "SubState": "dead"}), "idle")
        self.assertEqual(f({"LoadState": "loaded", "ActiveState": "deactivating", "SubState": "stop"}), "idle")


class Progress(unittest.TestCase):
    def test_stages_list(self):
        self.assertEqual([k for k, _ in ib.STAGES],
                         ["repartition", "format", "system", "home", "kernel", "check", "done"])
        self.assertEqual(ib.STAGES[0][1], "Repartitioning internal storage")

    def test_empty(self):
        p = ib.parse_progress("")
        self.assertEqual((p.stage_key, p.percent, p.error, p.done, p.fraction), ("repartition", None, None, False, 0.0))

    def test_each_stage(self):
        for i, (k, _) in enumerate(ib.STAGES):
            p = ib.parse_progress(log_upto(k))
            self.assertEqual((p.stage_key, p.stage_index, p.stage_count), (k, i, 7))
        self.assertTrue(ib.parse_progress(log_upto("done")).done)
        self.assertEqual(ib.parse_progress(log_upto("done")).fraction, 1.0)

    def test_percent_ansi_cr(self):
        p = ib.parse_progress(log_upto("system", 37))
        self.assertEqual((p.stage_key, p.percent), ("system", 37))
        self.assertEqual(ib.parse_progress(log_upto("home", 5)).percent, 5)
        # a new stage forgets the previous stage's 100%
        t = log_upto("system", 100) + G + "copying /home (games included)\n"
        self.assertIsNone(ib.parse_progress(t).percent)

    def test_home_variants(self):
        for line in ("copying /home (games included)", "copying /home without installed games",
                     "copying a fresh /home (Steam client and Decky, no account or personal data)"):
            self.assertEqual(ib.parse_progress(log_upto("home", 10, home=line)).stage_key, "home")

    def test_reinstall(self):
        p = ib.parse_progress(log_upto("format", reinstall=True), reinstall=True)
        self.assertEqual((p.stage_key, p.stage_index, p.stage_count), ("format", 0, 6))
        self.assertEqual(ib.parse_progress("", reinstall=True).stage_key, "format")
        self.assertEqual(ib.parse_progress(log_upto("done", reinstall=True), True).fraction, 1.0)

    def test_error(self):
        t = log_upto("system", 20) + "\n" + R + "rsync died: out of space\n"
        p = ib.parse_progress(t)
        self.assertEqual(p.error, "rsync died: out of space")
        self.assertFalse(p.done)
        # partition tool's own message, when the script exits before its own die()
        self.assertEqual(ib.parse_progress(G + "repartitioning\nERROR: table changed\n").error, "table changed")

    def test_monotonic(self):
        full = log_upto("done")
        # grow the log a few bytes at a time, as the file grows
        last = -1.0
        stages = []
        for k, _ in ib.STAGES:
            for pct in ((None,) if k not in ("system", "home") else (0, 10, 50, 99, 100)):
                stages.append(log_upto(k, pct))
        for t in stages:
            f = ib.parse_progress(t).fraction
            self.assertGreaterEqual(f, last)
            last = f
        last = -1.0
        for n in range(0, len(full), 7):
            f = ib.parse_progress(full[:n]).fraction
            self.assertGreaterEqual(f, last - 1e-9)
            last = f
        self.assertGreater(ib.parse_progress(log_upto("system", 100)).fraction, 0.4)

    def test_last_lines(self):
        t = G + "one\n  a 1%\r  a 50%\r  a 99%\nlast line\n\n"
        self.assertEqual(ib.last_log_lines(t, 8), ["[ufs] one", "  a 99%", "last line"])
        self.assertEqual(ib.last_log_lines(t, 1), ["last line"])
        self.assertEqual(ib.last_log_lines("", 3), [])
        self.assertNotIn("\x1b", "".join(ib.last_log_lines(log_upto("system", 50))))


class FakeMode(unittest.TestCase):
    def setUp(self):
        self.saved = dict(os.environ)
        os.environ["ZAVIYA_INSTALLER_FAKE"] = "1"

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)

    def test_probe_flags(self):
        self.assertTrue(ib.is_fake())
        p = ib.Installer().probe()
        self.assertIsNone(p.error)
        self.assertFalse(p.existing_install or p.tablet or p.unsupported)
        os.environ.update(ZAVIYA_INSTALLER_FAKE_EXISTING="1", ZAVIYA_INSTALLER_FAKE_TABLET="1",
                          ZAVIYA_INSTALLER_FAKE_UNSUPPORTED="1")
        p = ib.Installer().probe()
        self.assertTrue(p.existing_install and p.tablet and p.unsupported)

    def test_run_and_fail(self):
        inst = ib.Installer()
        self.assertEqual(inst.status()[0], "idle")
        self.assertIsNotNone(inst.start(64, "bogus", FP, False))
        self.assertIsNotNone(inst.start(64, "all", "nope", False))
        self.assertIsNone(inst.start(64, "all", FP, False))
        self.assertEqual(inst.status()[0], "running")
        inst._impl.t0 -= 12.5
        st, prog, text = inst.status()
        self.assertEqual((st, prog.stage_key), ("running", "home"))
        inst._impl.t0 -= 30
        st, prog, _ = inst.status()
        self.assertEqual((st, prog.done), ("done", True))
        os.environ["ZAVIYA_INSTALLER_FAKE_FAIL"] = "1"
        inst = ib.Installer()
        inst.start(64, "none", FP, True)
        inst._impl.t0 -= 12
        st, prog, _ = inst.status()
        self.assertEqual(st, "failed")
        self.assertTrue(prog.error)


class PadLogicTests(unittest.TestCase):
    def test_edges_and_repeat(self):
        lg = ip.PadLogic()
        self.assertEqual(lg.update({}, 0.0), [])
        self.assertEqual(lg.update({"down": True}, 1.0), ["down"])
        self.assertEqual(lg.update({"down": True}, 1.34), [])
        self.assertEqual(lg.update({"down": True}, 1.35), ["down"])
        self.assertEqual(lg.update({"down": True}, 1.40), [])
        self.assertEqual(lg.update({"down": True}, 1.48), ["down"])
        self.assertEqual(lg.update({"down": True}, 1.59), [])
        self.assertEqual(lg.update({"down": True}, 1.61), ["down"])
        self.assertEqual(lg.update({}, 1.7), [])
        self.assertEqual(lg.update({"down": True}, 1.8), ["down"])   # a new press starts over
        self.assertEqual(lg.update({"down": True}, 2.0), [])

    def test_stick_deadzone(self):
        lg = ip.PadLogic()
        self.assertEqual(lg.update({"lx": 16000, "ly": -16000}, 0), [])
        self.assertEqual(lg.update({"lx": 16001}, 0.1), ["right"])
        self.assertEqual(lg.update({"lx": 0, "ly": -20000}, 0.2), ["up"])
        self.assertEqual(lg.update({"lx": -32768, "ly": 20000}, 0.3), ["down", "left"])

    def test_dpad_and_stick_together_do_not_double(self):
        lg = ip.PadLogic()
        self.assertEqual(lg.update({"left": True, "lx": -30000}, 0), ["left"])
        self.assertEqual(lg.update({"left": True, "lx": -30000}, 0.1), [])

    def test_opposites_cancel(self):
        self.assertEqual(ip.PadLogic().update({"up": True, "down": True}, 0), [])

    def test_buttons(self):
        lg = ip.PadLogic()
        self.assertEqual(lg.update({"a": True}, 0), ["a_down"])
        self.assertEqual(lg.update({"a": True}, 5), [])          # a does not repeat
        self.assertEqual(lg.update({}, 5.1), ["a_up"])
        self.assertEqual(lg.update({"b": True}, 6), ["b"])
        self.assertEqual(lg.update({"b": True}, 7), [])
        self.assertEqual(lg.update({}, 7.1), [])
        self.assertEqual(lg.update({"l": True}, 8), ["l"])
        self.assertEqual(lg.update({"l": True, "r": True}, 8.4), ["l", "r"])

    def test_pad_inert_without_sdl(self):
        pad = ip.Pad(lambda e: None)
        pad.poll()    # must not raise whether or not SDL exists here
        self.assertIsInstance(pad.available, bool)


@unittest.skipUnless(shutil.which("bash"), "bash needed")
class StartHelper(unittest.TestCase):
    S = str(UFS / "zaviya-install-start")

    def run_(self, *args):
        return subprocess.run(["bash", self.S, "--check", *args], capture_output=True, text=True)

    def test_good(self):
        r = self.run_("--expect", FP, "--home", "essentials", "--android-gb", "64")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("--unit=zaviya-install", r.stdout)
        self.assertIn("--remain-after-exit", r.stdout)
        self.assertIn("StandardOutput=append:/run/zaviya-install.log", r.stdout)
        self.assertIn(str(UFS / "install-to-internal.sh"), r.stdout)
        self.assertIn("--force --expect " + FP + " --home essentials --android-gb 64", r.stdout)
        r = self.run_("--expect", FP, "--home", "all", "--resume")
        self.assertEqual(r.returncode, 0)
        self.assertTrue(r.stdout.strip().endswith("--resume"))

    def test_bad(self):
        cases = [
            ("--expect", "0123456789ABCDEF", "--home", "all", "--resume"),
            ("--expect", "short", "--home", "all", "--resume"),
            ("--home", "all", "--resume"),
            ("--expect", FP, "--home", "everything", "--resume"),
            ("--expect", FP, "--resume"),
            ("--expect", FP, "--home", "all"),
            ("--expect", FP, "--home", "all", "--android-gb", "0"),
            ("--expect", FP, "--home", "all", "--android-gb", "-5"),
            ("--expect", FP, "--home", "all", "--android-gb", "6x"),
            ("--expect", FP, "--home", "all", "--android-gb", "64", "--resume"),
            ("--expect", FP, "--home", "all", "--resume", "--extra"),
            ("--expect",),
        ]
        for args in cases:
            r = self.run_(*args)
            self.assertEqual(r.returncode, 2, args)
            self.assertTrue(r.stderr.strip(), args)
            self.assertEqual(r.stdout, "", args)

    def test_env_does_not_redirect(self):
        env = dict(os.environ, HERE="/tmp/evil", UNIT="x", LOG="/tmp/x", LD_PRELOAD="/tmp/x.so")
        r = subprocess.run(["bash", self.S, "--check", "--expect", FP, "--home", "none", "--resume"],
                           capture_output=True, text=True, env=env)
        self.assertIn(str(UFS / "install-to-internal.sh"), r.stdout)
        self.assertNotIn("/tmp/evil", r.stdout)


class Seeder(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.cfg = self.tmp / "userdata" / "1234" / "config"
        self.cfg.mkdir(parents=True)
        (self.tmp / "userdata" / "0" / "config").mkdir(parents=True)
        spec = importlib.util.spec_from_file_location("vdf_t", VDF)
        self.vdf = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.vdf)
        self.sc = self.cfg / "shortcuts.vdf"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def seed(self, force):
        return subprocess.run([sys.executable, str(UFS / "seed-installer-shortcut.py"),
                               "--steam-root", str(self.tmp), "--vdf-module", str(VDF),
                               "--force-removable", force], capture_output=True, text=True)

    def names(self):
        t, _ = self.vdf.parse_binary_vdf(self.sc.read_bytes())
        return {k: v["AppName"] for k, v in t["shortcuts"].items() if k != "tags"}

    def entry(self):
        t, _ = self.vdf.parse_binary_vdf(self.sc.read_bytes())
        return [v for k, v in t["shortcuts"].items() if k != "tags" and v["AppName"] == "Zaviya Installer"][0]

    def test_art_files(self):
        from PIL import Image
        art = UFS / "art"
        for name, size in (("installer-portrait.png", (600, 900)), ("installer-wide.png", (920, 430)),
                           ("installer-hero.png", (1920, 620)), ("installer-icon.png", (256, 256))):
            self.assertEqual(Image.open(art / name).size, size, name)
            self.assertLess((art / name).stat().st_size, 1 << 20, name)
        logo = Image.open(art / "installer-logo.png")
        self.assertEqual(logo.mode, "RGBA")
        self.assertEqual(logo.getchannel("A").getextrema()[0], 0)
        self.assertEqual(logo.width, 1281)

    def test_upgrade_adds_icon_and_art(self):
        # an entry from an older image: no icon, only the two capsules
        exe = str(Path("/usr/bin/zaviya-installer").resolve())
        self.vdf.add_shortcut(self.sc, "Zaviya Installer", exe)
        self.assertEqual(self.entry()["icon"], "")
        app_id = self.vdf.compute_app_id(exe, "Zaviya Installer")
        grid = self.cfg / "grid"
        grid.mkdir()
        (grid / f"{app_id}p.png").write_bytes(b"old")
        self.assertEqual(self.seed("yes").stdout, "")
        self.assertEqual(self.names(), {"0": "Zaviya Installer"})
        self.assertEqual(self.entry()["icon"], ICON)
        self.assertNotEqual((grid / f"{app_id}p.png").read_bytes(), b"old")
        self.assertTrue((grid / f"{app_id}_hero.png").is_file())
        # now current: untouched
        stamp = self.sc.stat().st_mtime_ns - 5 * 10 ** 9
        os.utime(self.sc, ns=(stamp, stamp))
        self.seed("yes")
        self.assertEqual(self.sc.stat().st_mtime_ns, stamp)

    def other(self):
        self.vdf.add_shortcut(self.sc, "Other A", "/bin/true")
        self.vdf.add_shortcut(self.sc, "Other B", "/bin/false")

    def test_round_trip(self):
        self.other()
        r = self.seed("yes")
        self.assertEqual((r.returncode, r.stdout), (0, ""))
        self.assertEqual(self.names(), {"0": "Other A", "1": "Other B", "2": "Zaviya Installer"})
        app_id = self.vdf.compute_app_id(str(Path("/usr/bin/zaviya-installer").resolve()), "Zaviya Installer")
        grid = self.cfg / "grid"
        self.assertTrue((grid / f"{app_id}p.png").is_file())
        self.assertTrue((grid / f"{app_id}.png").is_file())
        for n in (f"{app_id}_hero.png", f"{app_id}_logo.png", f"{app_id}.json"):
            self.assertTrue((grid / n).is_file(), n)
        self.assertEqual(json.loads((grid / f"{app_id}.json").read_text())["nVersion"], 1)
        self.assertEqual(self.entry()["icon"], ICON)
        # idempotent: file is not rewritten
        before = self.sc.stat().st_mtime_ns
        data = self.sc.read_bytes()
        os.utime(self.sc, ns=(before - 5 * 10 ** 9, before - 5 * 10 ** 9))
        stamp = self.sc.stat().st_mtime_ns
        self.seed("yes")
        self.assertEqual(self.sc.stat().st_mtime_ns, stamp)
        self.assertEqual(self.sc.read_bytes(), data)
        # internal storage: removed, others renumbered, art gone
        self.seed("no")
        self.assertEqual(self.names(), {"0": "Other A", "1": "Other B"})
        self.assertFalse((grid / f"{app_id}p.png").exists())
        self.assertFalse((grid / f"{app_id}.png").exists())
        self.assertEqual(list(grid.iterdir()), [])
        stamp = self.sc.stat().st_mtime_ns
        os.utime(self.sc, ns=(stamp - 5 * 10 ** 9, stamp - 5 * 10 ** 9))
        stamp = self.sc.stat().st_mtime_ns
        self.seed("no")
        self.assertEqual(self.sc.stat().st_mtime_ns, stamp)

    def test_renumber_middle(self):
        self.vdf.add_shortcut(self.sc, "Other A", "/bin/true")
        self.seed("yes")
        self.vdf.add_shortcut(self.sc, "Other B", "/bin/false")
        self.seed("no")
        self.assertEqual(self.names(), {"0": "Other A", "1": "Other B"})

    def test_no_file_remove_creates_nothing(self):
        self.seed("no")
        self.assertFalse(self.sc.exists())

    def test_unparseable_left_alone(self):
        junk = b"\x00shortcuts\x00\x0bgarbage\x00\x01"
        self.sc.write_bytes(junk)
        r = self.seed("yes")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.sc.read_bytes(), junk)
        self.assertIn("left alone", r.stdout)
        self.assertEqual(self.seed("no").returncode, 0)
        self.assertEqual(self.sc.read_bytes(), junk)

    def test_missing_module_still_exits_zero(self):
        r = subprocess.run([sys.executable, str(UFS / "seed-installer-shortcut.py"), "--steam-root",
                            str(self.tmp), "--vdf-module", "/nonexistent.py", "--force-removable", "yes"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertTrue(r.stdout.strip())


if __name__ == "__main__":
    unittest.main()
