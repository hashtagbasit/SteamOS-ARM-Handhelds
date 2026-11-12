"""Tests for the Pocket FIT Steam/Performance button remap in konkrd. Run:
    python3 -m unittest tests.test_button_remap
Needs PyYAML.
"""
import importlib.machinery
import importlib.util
import os
import tempfile
import unittest
from unittest import mock

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAPS = os.path.join(ROOT, "sm8650-overlay/etc/inputplumber/capability_maps.d")
loader = importlib.machinery.SourceFileLoader("konkrd", os.path.join(ROOT, "sm8650-overlay/usr/lib/konkr/konkrd"))
spec = importlib.util.spec_from_loader("konkrd", loader)
k = importlib.util.module_from_spec(spec)
loader.exec_module(k)

# file -> {button: source event_code}
FILES = {
    "konkr_pocketfit_deck.yaml": {"steam": "BTN_MODE"},
    "konkr_pocketfit_dinput.yaml": {"steam": "BTN_MODE"},
    "konkr_pocketfit_sysbtn.yaml": {"perf": "BTN_TRIGGER_HAPPY5"},
}
SHIPPED_TARGET = {"steam": {"gamepad": {"button": "Guide"}}, "perf": {"keyboard": "KeyF14"}}


def shipped(name):
    with open(os.path.join(MAPS, name), encoding="utf-8") as fh:
        return fh.read()


def targets(text):
    """source event_code -> target_event, for every mapping entry."""
    out = {}
    for m in yaml.safe_load(text)["mapping"]:
        out[m["source_events"][0]["evdev"]["event_code"]] = m["target_event"]
    return out


class ButtonRemap(unittest.TestCase):
    def test_codes_match_installed_paths(self):
        got = {os.path.basename(p): c for p, c in k.REMAP_MAPS.items()}
        self.assertEqual(got, FILES)

    def test_shipped_entries_have_the_documented_defaults(self):
        for name, codes in FILES.items():
            t = targets(shipped(name))
            for button, code in codes.items():
                self.assertEqual(t[code], SHIPPED_TARGET[button], (name, button))

    def test_default_is_identical_bytes(self):
        for name, codes in FILES.items():
            text = shipped(name)
            self.assertEqual(k.remap_text(text, codes, {}), text)
            self.assertEqual(k.remap_text(text, codes, {b: "default" for b in codes}), text)

    def test_each_choice(self):
        for name, codes in FILES.items():
            text = shipped(name)
            before = targets(text)
            for button, code in codes.items():
                for choice, target in k.REMAP_TARGET.items():
                    new = k.remap_text(text, codes, {button: choice})
                    self.assertIsNotNone(new)
                    after = targets(new)  # still valid YAML
                    self.assertEqual(after[code], {"gamepad": {"button": target}})
                    for other in before:
                        if other != code:
                            self.assertEqual(after[other], before[other])
                    self.assertEqual(len(new.split("\n")), len(text.split("\n")))
                    # back to default restores the shipped steam entry exactly;
                    # the perf entry is left to ensure_sysbtn_map
                    if button == "steam":
                        self.assertEqual(k.remap_text(new, codes, {}), text)

    def test_perf_default_does_not_touch_the_line(self):
        codes = FILES["konkr_pocketfit_sysbtn.yaml"]
        text = shipped("konkr_pocketfit_sysbtn.yaml").replace("keyboard: KeyF14", "gamepad: {button: LeftTouchpadPress}")
        self.assertEqual(k.remap_text(text, codes, {"perf": "default"}), text)

    def test_invalid_choice_rejected(self):
        for name, codes in FILES.items():
            for button in codes:
                for bad in ("Start", "Guide", "x\n  evil: 1", "", None, 3, "start; rm"):
                    with self.assertRaises(ValueError):
                        k.remap_text(shipped(name), codes, {button: bad})

    def test_missing_or_odd_entries_leave_file_alone(self):
        for name, codes in FILES.items():
            text = shipped(name)
            code = next(iter(codes.values()))
            self.assertIsNone(k.remap_text("", codes, {}))
            self.assertIsNone(k.remap_text("mapping: []\n", codes, {}))
            self.assertIsNone(k.remap_text(text.replace(f"event_code: {code},", "event_code: BTN_X,"), codes, {}))
            self.assertIsNone(k.remap_text(text + text, codes, {}))
            at = text.index("target_event:", text.index(f"event_code: {code},"))
            odd = text[:at] + "target_x:" + text[at + len("target_event:"):]
            self.assertIsNone(k.remap_text(odd, codes, {}))
            cut = text[:text.index(f"event_code: {code},")]
            cut = cut[:cut.rindex("\n") + 1] + f"      - evdev: {{event_code: {code},"
            self.assertIsNone(k.remap_text(cut, codes, {}))

    def test_choice_reader(self):
        self.assertEqual(k.remap_choice({}, "steam"), "default")
        self.assertEqual(k.remap_choice({"remap": {"steam": "start"}}, "steam"), "start")
        self.assertEqual(k.remap_choice({"remap": {"steam": "evil"}}, "steam"), "default")
        self.assertEqual(k.remap_choice({"remap": "x"}, "perf"), "default")


class Apply(unittest.TestCase):
    """ensure_button_remap and ensure_sysbtn_map against copies of the maps."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.paths = {}
        for name in FILES:
            dst = os.path.join(self.tmp.name, name)
            with open(dst, "w", encoding="utf-8") as fh:
                fh.write(shipped(name))
            self.paths[name] = dst
        by_name = {os.path.basename(p): c for p, c in k.REMAP_MAPS.items()}
        maps = {self.paths[n]: by_name[n] for n in FILES}
        real_rd = k.rd
        for patcher in (
            mock.patch.object(k, "REMAP_MAPS", maps),
            mock.patch.object(k, "SYSBTN_MAP", self.paths["konkr_pocketfit_sysbtn.yaml"]),
            mock.patch.object(k, "rd", lambda p, *a: "KONKR Pocket FIT" if p.endswith("devicetree/base/model") else real_rd(p, *a)),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.restarts = mock.patch.object(k, "restart_inputplumber")
        self.restart = self.restarts.start()
        self.addCleanup(self.restarts.stop)

    def read(self, name):
        with open(self.paths[name], encoding="utf-8") as fh:
            return fh.read()

    def test_default_changes_nothing_and_does_not_restart(self):
        k.ensure_button_remap({})
        for name in FILES:
            self.assertEqual(self.read(name), shipped(name))
        self.restart.assert_not_called()

    def test_choice_rewrites_and_queues_one_restart(self):
        k.ensure_button_remap({"remap": {"steam": "select", "perf": "start"}})
        self.assertEqual(targets(self.read("konkr_pocketfit_deck.yaml"))["BTN_MODE"], {"gamepad": {"button": "Select"}})
        self.assertEqual(targets(self.read("konkr_pocketfit_dinput.yaml"))["BTN_MODE"], {"gamepad": {"button": "Select"}})
        self.assertEqual(targets(self.read("konkr_pocketfit_sysbtn.yaml"))["BTN_TRIGGER_HAPPY5"], {"gamepad": {"button": "Start"}})
        self.restart.assert_called_once()
        self.restart.reset_mock()
        k.ensure_button_remap({"remap": {"steam": "select", "perf": "start"}})  # second run: no change
        self.restart.assert_not_called()

    def test_steam_back_to_default_restores_files(self):
        k.ensure_button_remap({"remap": {"steam": "start"}})
        k.ensure_button_remap({})
        for name in ("konkr_pocketfit_deck.yaml", "konkr_pocketfit_dinput.yaml"):
            self.assertEqual(self.read(name), shipped(name))

    def test_front_button_rewrite_leaves_perf_alone_while_remapped(self):
        st = {"remap": {"perf": "select"}, "buttons": {"F13": "rgb-next", "F14": "profile-next"}}
        k.ensure_button_remap(st)
        k.ensure_sysbtn_map(st)
        self.assertEqual(targets(self.read("konkr_pocketfit_sysbtn.yaml"))["BTN_TRIGGER_HAPPY5"],
                         {"gamepad": {"button": "Select"}})
        # back to default: the keyboard entry returns
        st = {"buttons": {"F13": "rgb-next", "F14": "profile-next"}}
        k.ensure_sysbtn_map(st)
        k.ensure_button_remap(st)
        self.assertEqual(self.read("konkr_pocketfit_sysbtn.yaml"), shipped("konkr_pocketfit_sysbtn.yaml"))

    def test_restart_never_blocks(self):
        self.restarts.stop()
        with mock.patch.object(k.subprocess, "Popen") as popen, mock.patch.object(k.subprocess, "run") as run:
            k.restart_inputplumber()
        run.assert_not_called()
        argv = popen.call_args[0][0]
        self.assertIn("--no-block", argv)
        self.restarts.start()


if __name__ == "__main__":
    unittest.main()
