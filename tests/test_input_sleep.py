"""Checks for the controller-across-sleep packaging and the sleep hook:
bounded waits, the InputPlumber drop-ins and patch, and the wake-source record.
    python3 -m unittest tests.test_input_sleep
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SLEEP = os.path.join(ROOT, "sm8650-overlay/usr/lib/konkr/konkr-sleep")
IP = os.path.join(ROOT, "external-and-mods/InputPlumber")


def text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


class Packaging(unittest.TestCase):
    def test_targets_are_kept_across_sleep(self):
        conf = text(f"{IP}/systemd/inputplumber.service.d/90-keep-pads-across-sleep.conf")
        self.assertIn("Environment=SUSPEND_TARGET_DEVICES_ON_SLEEP=0", conf)

    def test_hooks_are_bounded(self):
        conf = text(f"{IP}/systemd/inputplumber-suspend.service.d/90-bounded.conf")
        calls = [l for l in conf.splitlines() if l.startswith(("ExecStart=-", "ExecStop=-"))]
        self.assertEqual(len(calls), 2)
        for line in calls:
            self.assertRegex(line, r"busctl --timeout=[1-9] ")
        self.assertRegex(conf, r"TimeoutStartSec=\d+")
        self.assertRegex(conf, r"TimeoutStopSec=\d+")
        # a failed HookSleep must not stop HookWake from being registered
        self.assertEqual(conf.count("ExecStart=\n"), 1)
        self.assertEqual(conf.count("ExecStop=\n"), 1)

    def test_patch_reads_the_setting_and_guards_resume(self):
        patch = text(f"{IP}/0006-keep-target-devices-across-sleep.patch")
        self.assertIn('std::env::var("SUSPEND_TARGET_DEVICES_ON_SLEEP")', patch)
        self.assertIn("target_devices_suspended.is_empty()", patch)

    def test_delta_updates_carry_the_rewritten_maps(self):
        src = text(os.path.join(ROOT, "scripts/build-update-v2.py"))
        for name in ("sysbtn", "deck", "dinput"):
            self.assertIn(f"'{name}'", src)


class SleepHook(unittest.TestCase):
    def test_no_unbounded_waits(self):
        src = text(SLEEP)
        for n, line in enumerate(src.splitlines(), 1):
            code = line.split("#", 1)[0]
            m = re.search(r"\bsleep ([0-9.]+)", code)
            if m:
                self.assertLessEqual(float(m.group(1)), 5, f"line {n}: {line}")
            if re.search(r"\bsystemctl (restart|stop|start)\b", code) and "no-block" not in code:
                self.assertIn("timeout", code, f"line {n}: {line}")
            if re.match(r"\s*(sync|modprobe)\b", code):
                self.fail(f"line {n}: unbounded {line.strip()}")

    @unittest.skipUnless(shutil.which("bash") and shutil.which("timeout"), "needs bash and timeout")
    def test_wake_source_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            for i, (name, count) in enumerate((("pmic pwrkey", 3), ("a600000.usb", 1))):
                d = os.path.join(tmp, f"wakeup{i}")
                os.makedirs(d)
                for f, v in (("name", name), ("event_count", count)):
                    with open(os.path.join(d, f), "w", encoding="utf-8") as fh:
                        fh.write(f"{v}\n")
            body = text(SLEEP).replace("/sys/class/wakeup", tmp)
            funcs = "\n".join(
                [re.search(r"^WAKE_SNAP=.*$", body, re.M).group(0)] +
                [re.search(rf"^{fn}\(\) \{{.*?^\}}$", body, re.S | re.M).group(0)
                 for fn in ("wake_snapshot", "wake_changed")])
            script = (f"{funcs}\nWAKE_SNAP={tmp}/snap\nwake_snapshot >$WAKE_SNAP\n"
                      f"echo none=[$(wake_changed)]\necho 5 >{tmp}/wakeup0/event_count\n"
                      f"echo changed=[$(wake_changed)]\nrm -rf {tmp}/wakeup0 {tmp}/wakeup1\n"
                      f"echo gone=[$(wake_snapshot)]\n")
            out = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=20).stdout
        self.assertIn("none=[]", out)
        self.assertIn("changed=[pmic pwrkey(+2)]", out)
        self.assertIn("gone=[]", out)


if __name__ == "__main__":
    unittest.main()
