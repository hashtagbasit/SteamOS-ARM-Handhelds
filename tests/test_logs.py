"""steamos-arm-logs against a fake file tree and fake tools."""
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "steamos-overlay/usr/lib/steamos-arm/steamos-arm-logs"
MAC = "aa:bb:cc:11:22:33"


class Logs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = Path(self.tmp.name)
        self.home = self.t / "home"
        self.home.mkdir()
        fake = self.t / "root"
        (fake / "proc/device-tree").mkdir(parents=True)
        (fake / "proc/device-tree/model").write_bytes(b"KONKR Pocket FIT\0")
        (fake / "proc/device-tree/compatible").write_bytes(b"konkr,fit\0qcom,sm8550\0")
        (fake / "proc/cmdline").write_text("root=/dev/mmcblk0p2\n")
        (fake / "etc").mkdir()
        (fake / "etc/os-release").write_text('NAME="Zaviya"\n')
        bat = fake / "sys/class/power_supply/battery"
        bat.mkdir(parents=True)
        (bat / "capacity").write_text("87\n")
        (bat / "status").write_text("Charging\n")
        inv = fake / "usr/share/steamos-arm/update"
        inv.mkdir(parents=True)
        (inv / "installed.json").write_text('{"version": "1.5", "soc": "sm8550", "files": {"secret/path": [1, 2, "x"]}}')
        self.fake_root = fake
        # Only journalctl exists among the optional tools; the rest are missing.
        self.bin = self.t / "bin"
        self.bin.mkdir()
        jc = self.bin / "journalctl"
        jc.write_text(f"#!/bin/sh\necho 'wlan0 {MAC} up'\necho 'konkr-sleep: suspend'\n")
        jc.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def run_logs(self):
        env = dict(os.environ, HOME=str(self.home), ZAVIYA_LOGS_ROOT=str(self.fake_root),
                   PATH=f"{self.bin}:/usr/bin:/bin", TMPDIR=str(self.t))
        return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=120)

    def read_archive(self, r):
        path = Path(r.stdout.strip().splitlines()[-1])
        self.assertTrue(path.is_file(), path)
        with tarfile.open(path) as tf:
            return path, {Path(m.name).name: tf.extractfile(m).read().decode() for m in tf.getmembers() if m.isfile()}

    def test_archive_contents_and_redaction(self):
        r = self.run_logs()
        self.assertEqual(r.returncode, 0, r.stderr)
        path, files = self.read_archive(r)
        self.assertEqual(path.parent, self.home / "zaviya-logs")
        self.assertIn("konkr-pocket-fit", path.name)
        self.assertIn("README.txt", files)
        self.assertIn("Left out on purpose", files["README.txt"])
        self.assertIn("KONKR Pocket FIT", files["device.txt"])
        self.assertIn("87", files["power-supply.txt"])
        self.assertIn("version: 1.5", files["release.txt"])
        self.assertNotIn("secret/path", files["release.txt"])
        self.assertIn("konkr-sleep", files["sleep-wake.txt"])
        text = "".join(files.values())
        self.assertNotIn(MAC, text)
        self.assertIn("aa:bb:cc:xx:xx:xx", files["journal-boot.txt"])

    def test_missing_tools_do_not_fail(self):
        r = self.run_logs()
        self.assertEqual(r.returncode, 0, r.stderr)
        _, files = self.read_archive(r)
        self.assertIn("not available", files["vulkan.txt"])
        self.assertIn("not available", files["network.txt"])

    def test_keeps_five_newest(self):
        out = self.home / "zaviya-logs"
        out.mkdir()
        for i in range(7):
            p = out / f"zaviya-logs-old-2020010{i}-000000.tar.gz"
            p.write_text("x")
            os.utime(p, (1_000_000 + i, 1_000_000 + i))
        r = self.run_logs()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(list(out.glob("zaviya-logs-*.tar.gz"))), 5)
        self.assertTrue(Path(r.stdout.strip().splitlines()[-1]).exists())


if __name__ == "__main__":
    unittest.main()
