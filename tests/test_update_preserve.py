"""The offline updater keeps identity files and the sshd enablement links."""
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("konkr_update", ROOT / "external-and-mods/konkr-update/konkr-update.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

SSHD = ("systemd/system/multi-user.target.wants/sshd.service", "systemd/system/sockets.target.wants/sshd.socket")


class Preserve(unittest.TestCase):
    def test_sshd_links_are_preserved_in_etc_and_overlay(self):
        for rel in SSHD:
            self.assertIn(rel, mod.PRESERVE)
            self.assertTrue(mod.preserved("root/etc/" + rel))
            self.assertTrue(mod.preserved("root/" + mod.UPPER + "/" + rel))

    def test_siblings_are_not_preserved(self):
        self.assertFalse(mod.preserved("root/etc/systemd/system/multi-user.target.wants/other.service"))
        self.assertFalse(mod.preserved("root/etc/systemd/system/multi-user.target.wants/sshd.service.bak"))
        self.assertFalse(mod.preserved("root/usr/" + SSHD[0]))

    def test_existing_entries_still_preserved(self):
        self.assertTrue(mod.preserved("root/etc/ssh/ssh_host_ed25519_key"))
        self.assertTrue(mod.preserved("root/etc/NetworkManager/system-connections/home.nmconnection"))


if __name__ == "__main__":
    unittest.main()
