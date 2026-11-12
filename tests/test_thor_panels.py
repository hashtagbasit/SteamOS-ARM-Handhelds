"""Thor and Thor Lite panel assignment: which backlight is top and which is bottom.

The two devices are told apart by whole entries of the device-tree compatible
list, never by substring (ayn,thor is a prefix of ayn,thor-lite).
"""
import importlib.machinery
import importlib.util
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOTTOM_SCREEN = ROOT / "dualscreen-overlay/usr/lib/steamos-arm/bottom-screen"
BASE = "/sys/class/backlight"
THOR = ["ayn,thor", "qcom,qcs8550", "qcom,sm8550"]
THOR_LITE = ["ayn,thor-lite", "qcom,sm8250"]
GATED_SCRIPTS = [
    "external-and-mods/system-fixes/Thor/payload/usr/bin/thorch-display-setup",
    "external-and-mods/system-fixes/Thor/payload/usr/bin/thorch-touchscreen-setup",
    "external-and-mods/system-fixes/Thor/auto/thor-autoinstall.sh",
    "external-and-mods/system-fixes/Thor/fix-thor.sh",
    "external-and-mods/kernel/payload/fix-thor-screen/usr/bin/thorch-display-setup",
    "external-and-mods/kernel/payload/fix-thor-screen/usr/bin/thorch-kwin-touch-map",
    "external-and-mods/kernel/payload/fix-thor-screen/usr/bin/thorch-touchscreen-setup",
    "external-and-mods/kernel/payload/fix-thor-screen/fix-thor.sh",
    "external-and-mods/kernel/lib/fix-thor-screen.sh",
]


def load_backlightd():
    path = str(BOTTOM_SCREEN / "thor-backlightd")
    loader = importlib.machinery.SourceFileLoader("thor_backlightd", path)
    spec = importlib.util.spec_from_loader("thor_backlightd", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def nul_file(entries):
    f = tempfile.NamedTemporaryFile(delete=False)
    f.write(b"".join(e.encode() + b"\0" for e in entries))
    f.close()
    return Path(f.name)


class BacklightDaemonPanels(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_backlightd()

    def test_thor_keeps_its_assignment(self):
        top, bottom = self.mod.panels(THOR)
        self.assertEqual(top, f"{BASE}/ae96000.dsi.0")
        self.assertEqual(bottom, f"{BASE}/ae94000.dsi.0")

    def test_thor_lite_is_swapped(self):
        top, bottom = self.mod.panels(THOR_LITE)
        self.assertEqual(top, f"{BASE}/ae94000.dsi.0")
        self.assertEqual(bottom, f"{BASE}/ae96000.dsi.0")

    def test_whole_entries_only(self):
        # Neither a prefix of the Thor name nor a longer one picks the Lite.
        self.assertEqual(self.mod.panels(["ayn,thor-litex"]), self.mod.panels(THOR))
        self.assertEqual(self.mod.panels([]), self.mod.panels(THOR))

    def test_reads_nul_separated_file(self):
        for entries in (THOR, THOR_LITE):
            p = nul_file(entries)
            self.addCleanup(p.unlink)
            self.assertEqual(self.mod.dt_compatibles(str(p)), entries)
        self.assertEqual(self.mod.dt_compatibles("/nonexistent/compatible"), [])


class DashboardAndSession(unittest.TestCase):
    def test_dashboard_labels(self):
        src = (BOTTOM_SCREEN / "dashboard").read_text()
        thor = re.search(r'"AYN Thor": \{"(\w+\.dsi\.0)": "Top screen"', src)
        lite = re.search(r'"AYN Thor Lite": \{"(\w+\.dsi\.0)": "Top screen"', src)
        self.assertEqual(thor.group(1), "ae96000.dsi.0")
        self.assertEqual(lite.group(1), "ae94000.dsi.0")

    def test_gamescope_session_top_backlight(self):
        src = (ROOT / "steamos-overlay/usr/lib/steamos/gamescope-session").read_text()
        for model, top in (("AYN Thor", "ae96000"), ("AYN Thor Lite", "ae94000")):
            m = re.search(r'"%s"\)(.*?);;' % re.escape(model), src, re.S)
            self.assertIsNotNone(m, model)
            self.assertIn(f"TOP_BACKLIGHT=/sys/class/backlight/{top}.dsi.0", m.group(1))


if __name__ == "__main__":
    unittest.main()
