"""steamos-arm-space-guard against a fake file tree."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "steamos-overlay/usr/lib/steamos-arm"


class SpaceGuard(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = Path(self.tmp.name)
        home = self.t / "home/steamos"
        self.cases = {
            "pkg": self.t / "var/cache/pacman/pkg/a.pkg.tar.zst",
            "logs": home / ".local/share/Steam/logs/x.txt",
            "mesa": home / ".cache/mesa_shader_cache/a/b",
            "shader": home / ".local/share/Steam/steamapps/shadercache/123/f.foz",
        }
        self.keep = {
            "save": home / ".local/share/Steam/steamapps/common/Game/save.dat",
            "config": home / ".config/app/settings.ini",
            "other_cache": home / ".cache/some-app/state.db",
            "manifest": home / ".local/share/Steam/steamapps/appmanifest_1.acf",
        }
        for p in list(self.cases.values()) + list(self.keep.values()):
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("x")

    def tearDown(self):
        self.tmp.cleanup()

    def run_guard(self, min_mb):
        env = dict(os.environ, SPACE_GUARD_ROOT=str(self.t), STEAMOS_ARM_MIN_FREE_MB=str(min_mb))
        return subprocess.run(["bash", str(LIB / "steamos-arm-space-guard")], env=env,
                              capture_output=True, text=True, timeout=60)

    def test_enough_space_deletes_nothing(self):
        r = self.run_guard(1)
        self.assertEqual(r.returncode, 0)
        for p in list(self.cases.values()) + list(self.keep.values()):
            self.assertTrue(p.exists(), p)
        self.assertFalse((self.t / "run/steamos-arm/low-space").exists())

    def test_low_space_clears_caches_only(self):
        r = self.run_guard(10**9)
        self.assertEqual(r.returncode, 0)
        for p in self.cases.values():
            self.assertFalse(p.exists(), p)
        for p in self.keep.values():
            self.assertTrue(p.exists(), p)
        self.assertTrue((self.t / "run/steamos-arm/low-space").exists())
        self.assertIn("still nearly full", r.stdout)


if __name__ == "__main__":
    unittest.main()
