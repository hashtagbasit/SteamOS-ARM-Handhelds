#!/usr/bin/env python3
"""Zaviya Installer: GUI for installing Zaviya to internal UFS."""

from __future__ import annotations

import os
import shutil
import subprocess
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, Pango

APP_NAME = "Zaviya Installer"
APP_VERSION = "2.0.0"

SHARE = Path(os.environ.get("ZAVIYA_INSTALL_ROOT", "/usr/share/zaviya-install"))
INSTALL_SH = SHARE / "install-to-internal.sh"
PROBE_SH = SHARE / "ufs-probe-sizes.sh"
DIAGNOSE_SH = SHARE / "ufs-diagnose.sh"


def _is_tablet() -> bool:
    """Lenovo Legion Y700 Gen 3 / Gen 4: no OpenABL, runs from USB."""
    try:
        compat = Path("/sys/firmware/devicetree/base/compatible").read_bytes()
    except OSError:
        return False
    return b"lenovo,tb321fu" in compat or b"lenovo,elden" in compat


TABLET = _is_tablet()
SOURCE = "the USB drive" if TABLET else "the SD card"


def _pkexec(argv: list[str]) -> subprocess.CompletedProcess[str]:
    if os.geteuid() == 0:
        return subprocess.run(argv, check=False, text=True, capture_output=True)
    if shutil.which("pkexec"):
        return subprocess.run(["pkexec", *argv], check=False, text=True, capture_output=True)
    return subprocess.run(["sudo", "--", *argv], check=False, text=True, capture_output=True)


def probe_sizes() -> dict[str, str]:
    script = PROBE_SH if PROBE_SH.is_file() else Path(__file__).resolve().parent / "ufs-probe-sizes.sh"
    if not script.is_file():
        raise RuntimeError(f"Missing probe script: {script}")
    # Probe may need root for parted on some devices
    proc = _pkexec([str(script)])
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "").strip() or f"exit {proc.returncode}"
        raise RuntimeError(err)
    out: dict[str, str] = {}
    for line in (proc.stdout or "").splitlines():
        if "=" in line and not line.startswith("ERROR="):
            k, v = line.split("=", 1)
            out[k] = v
        elif line.startswith("ERROR="):
            raise RuntimeError(line.split("=", 1)[1])
    if "MAX_ANDROID_GIB" not in out:
        raise RuntimeError("Probe did not return sizing info")
    return out


class MainWindow(Gtk.Window):
    def __init__(self) -> None:
        super().__init__(title=APP_NAME)
        self.set_default_size(640, 720)
        # No closing halfway through an install.
        self.connect("delete-event", lambda *_a: self._busy)
        self.set_border_width(14)
        self._busy = False
        self._info: dict[str, str] = {}

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.add(root)

        title = Gtk.Label()
        title.set_markup(f"<span size='x-large'><b>{APP_NAME}</b></span>")
        title.set_xalign(0)
        root.pack_start(title, False, False, 0)

        frame = Gtk.Frame(label="Read carefully")
        frame.set_shadow_type(Gtk.ShadowType.ETCHED_IN)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.set_border_width(10)
        # Red-ish emphasis via markup
        warn_m = Gtk.Label()
        warn_m.set_markup(
            "<span foreground='#b00020'><b>WARNING — THIS WILL MODIFY THE INTERNAL "
            "STORAGE OF YOUR DEVICE</b></span>\n\n"
            + GLib.markup_escape_text(
                ("This tool repartitions internal UFS and installs Zaviya next to Android's "
                 "data (boot + system + home), then writes Zaviya's boot image "
                 "over Android's. Android's boot image is saved to /home/.ufs-backup first.\n\n"
                 "• Android userdata will be ERASED (factory-reset style).\n"
                 "• The old partition table is saved to the USB drive first (/boot/ufs-backup).\n"
                 "• Incorrect use MAY cause data loss or make Android/Linux unbootable.\n"
                 "• Run this from Zaviya on the USB drive, not from an already-installed one.\n\n"
                 if TABLET else
                 "This tool repartitions internal UFS and installs Zaviya alongside Android "
                 "(boot + system + home).\n\n"
                 "• Android userdata will be ERASED (factory-reset style).\n"
                 "• The old partition table is saved to the SD card first (/boot/ufs-backup), "
                 "so the space can be given back to Android later.\n"
                 "• Incorrect use MAY cause data loss or make Android/Linux unbootable.\n"
                 "• Run this from microSD Linux, not from an already-installed UFS root.\n"
                 "• Keep OpenABL installed and a working /boot/KERNEL on the SD.\n\n") +
                "No password needed. If you set one with passwd, Zaviya may ask for it.\n\n"
                "Nothing should go wrong if you follow the steps, but DATA LOSS IS POSSIBLE.\n"
                "Proceed only if you understand the risk."
            )
        )
        warn_m.set_xalign(0)
        warn_m.set_line_wrap(True)
        warn_m.set_selectable(True)
        box.pack_start(warn_m, False, False, 0)
        frame.add(box)
        root.pack_start(frame, False, False, 0)

        self.status = Gtk.Label(label="Click Refresh to probe internal UFS…")
        self.status.set_xalign(0)
        self.status.set_line_wrap(True)
        root.pack_start(self.status, False, False, 0)

        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        grid.attach(Gtk.Label(label="Android partition size (GB):", xalign=0), 0, 0, 1, 1)
        adj = Gtk.Adjustment(value=64, lower=16, upper=512, step_increment=1, page_increment=8)
        self.size_spin = Gtk.SpinButton(adjustment=adj, climb_rate=1, digits=0)
        self.size_spin.set_numeric(True)
        grid.attach(self.size_spin, 1, 0, 1, 1)
        self.linux_label = Gtk.Label(label="Zaviya partitions: none", xalign=0)
        self.linux_label.set_line_wrap(True)
        grid.attach(self.linux_label, 0, 1, 2, 1)
        grid.attach(Gtk.Label(label=f"Bring from {SOURCE}'s /home:", xalign=0), 0, 2, 1, 1)
        self.home_combo = Gtk.ComboBoxText()
        self.home_combo.append("all", "Everything, installed games included")
        self.home_combo.append("essentials", "Settings, saves and Steam login (no games)")
        self.home_combo.append("none", "Fresh start (no Steam login, saves or games)")
        self.home_combo.set_active_id("all")
        grid.attach(self.home_combo, 1, 2, 1, 1)
        root.pack_start(grid, False, False, 0)
        self.size_spin.connect("value-changed", lambda *_: self._update_linux_label())

        self.ack = Gtk.CheckButton(
            label="I understand this modifies internal UFS and may erase Android data"
        )
        root.pack_start(self.ack, False, False, 0)

        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.refresh_btn = Gtk.Button(label="Refresh UFS info")
        self.refresh_btn.connect("clicked", lambda *_: self.refresh_async())
        self._install_label = "Install to internal UFS"
        self._reinstall = False
        self.install_btn = Gtk.Button(label=self._install_label)
        self.install_btn.connect("clicked", self._on_install)
        buttons.pack_start(self.refresh_btn, False, False, 0)
        buttons.pack_start(self.install_btn, False, False, 0)
        buttons.pack_end(Gtk.Label(label=f"v{APP_VERSION}"), False, False, 0)
        root.pack_start(buttons, False, False, 0)

        self.log = Gtk.TextView()
        self.log.set_editable(False)
        self.log.set_monospace(True)
        self.log.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        scroll = Gtk.ScrolledWindow()
        scroll.set_min_content_height(180)
        scroll.add(self.log)
        root.pack_start(scroll, True, True, 0)

        self.connect("destroy", Gtk.main_quit)
        self.refresh_async()

    def _append(self, text: str) -> None:
        buf = self.log.get_buffer()
        buf.insert(buf.get_end_iter(), text.rstrip() + "\n")

    def _update_linux_label(self) -> None:
        if not self._info:
            return
        try:
            android = int(self.size_spin.get_value())
            boot = int(self._info.get("BOOT_PART_GIB", "2"))
            root = int(self._info.get("ROOT_PART_GIB", "16"))
            total = int(self._info.get("ORIG_ANDROID_GIB", "0"))
            home = total - android - boot - root
            self.linux_label.set_text(
                f"boot {boot} GB  |  system {root} GB  |  home ~{home} GB"
            )
        except ValueError:
            pass

    def refresh_async(self) -> None:
        if self._busy:
            return
        self._busy = True
        self.refresh_btn.set_sensitive(False)
        self.status.set_text("Probing internal UFS…")

        def worker() -> None:
            err = ""
            info: dict[str, str] = {}
            try:
                info = probe_sizes()
            except Exception as exc:  # noqa: BLE001
                err = str(exc)

            def done() -> None:
                self._busy = False
                self.refresh_btn.set_sensitive(True)
                if err:
                    self.status.set_text(f"Probe failed: {err}")
                    self._append(err)
                    return
                self._info = info
                mode = info.get("MODE")
                from_sd = info.get("RUNNING_FROM_SD") == "1"
                # An earlier install, finished or not (an interrupted one left the
                # app greyed out for good): offer to install it again over our own
                # partitions. Android and its size stay as they are.
                self._reinstall = mode == "installed"
                self.install_btn.set_label("Install again" if self._reinstall else self._install_label)
                self.install_btn.set_sensitive(mode in ("fresh", "installed") and from_sd)
                self.size_spin.set_sensitive(not self._reinstall)
                if self._reinstall and from_sd:
                    self._append("Zaviya is already on internal storage, or an install didn't finish. "
                                 "Install again erases internal Zaviya, games and saves included, and copies "
                                 f"{SOURCE} again. Android isn't touched.")
                if not from_sd:
                    self._append(f"Running from internal storage: boot {SOURCE} to install.")
                elif info.get("MODE") == "occupied":
                    self._append(f"Other partitions follow userdata ({info.get('OCCUPIED')}). "
                                 "Remove them in the ABL menu (UNINSTALL CFW) first.")
                mn = int(info["MIN_ANDROID_GIB"])
                mx = int(info["MAX_ANDROID_GIB"])
                rec = int(info["RECOMMENDED_ANDROID_GIB"])
                self.size_spin.set_range(mn, mx)
                self.size_spin.set_value(rec)
                existing = info.get("EXISTING_INSTALL", "0") == "1"
                old_two = info.get("OLD_TWOPART_INSTALL", "0") == "1"
                extra = ""
                if existing:
                    extra = " (Zaviya already installed, use Zaviya Update; reinstall erases internal games and saves)"
                elif old_two:
                    extra = " (old 2-partition layout, UNINSTALL CFW before a fresh Zaviya install)"
                self.status.set_text(
                    f"UFS {info.get('DEVICE')} · total ~{info.get('DISK_TOTAL_GIB')} GB · "
                    f"userdata now ~{info.get('ORIG_ANDROID_GIB')} GB · "
                    f"Android size {mn}–{mx} GB (recommended {rec}){extra}"
                )
                self._update_linux_label()
                self._append(f"Probe OK: {info}")

            GLib.idle_add(done)

        threading.Thread(target=worker, daemon=True).start()

    def _on_install(self, *_args) -> None:
        if self._busy:
            return
        if not self.ack.get_active():
            self._append("Tick the confirmation checkbox first.")
            return
        script = INSTALL_SH if INSTALL_SH.is_file() else Path(__file__).resolve().parent / "install-to-internal.sh"
        if not script.is_file():
            self._append(f"Missing installer: {script}")
            return
        android_gb = int(self.size_spin.get_value())
        root_gb = int(self._info.get("ROOT_PART_GIB", "16")) if self._info else 16
        boot_gb = int(self._info.get("BOOT_PART_GIB", "2")) if self._info else 2
        dialog = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text="Confirm internal UFS install",
        )
        reinstall = getattr(self, "_reinstall", False)
        dialog.format_secondary_text(
            "Internal Zaviya (boot, system and home) will be ERASED and copied again, "
            "games and saves on it included. Android isn't touched. Continue?"
            if reinstall else
            f"Android userdata will be set to {android_gb} GB and ERASED.\n"
            f"Creates boot ({boot_gb} GB) + system ({root_gb} GB) + home (remaining).\n"
            "Internal partitions will be rewritten. Continue?"
        )
        response = dialog.run()
        dialog.destroy()
        if response != Gtk.ResponseType.OK:
            return

        self._busy = True
        self.install_btn.set_sensitive(False)
        self.status.set_text(f"Installing with --android-gb {android_gb} (this takes a while)…")
        progress = self._progress_dialog()

        fingerprint = self._info.get("TABLE_FINGERPRINT", "")
        home_mode = self.home_combo.get_active_id() or "all"
        # The table is about to change: the next install needs a fresh probe.
        self._info = {}

        def worker() -> None:
            size = ["--resume"] if reinstall else ["--android-gb", str(android_gb)]
            proc = _pkexec([str(script), "--force", *size,
                            "--expect", fingerprint, "--home", home_mode])
            out = ((proc.stdout or "") + (proc.stderr or "")).strip()

            def done() -> None:
                self._busy = False
                GLib.source_remove(progress.pulse_id)
                progress.destroy()
                self.install_btn.set_sensitive(False)
                if out:
                    self._append(out[-8000:])
                if proc.returncode == 0:
                    if TABLET:
                        self.status.set_text("Install finished. Power off, unplug the USB drive, then power on.")
                    else:
                        self.status.set_text("Install finished. Power off, remove the SD card, then in the ABL menu set Boot source to Internal and boot Linux.")
                else:
                    self.status.set_text(f"Install failed (exit {proc.returncode}). See log.")

            GLib.idle_add(done)

        threading.Thread(target=worker, daemon=True).start()


    def _progress_dialog(self) -> Gtk.Dialog:
        """A window over everything until the install ends. A line in the
        status label was easy to miss on a small screen, and people closed the
        installer or restarted halfway, leaving internal storage half done."""
        dialog = Gtk.Dialog(title="Installing Zaviya", transient_for=self, modal=True)
        dialog.set_deletable(False)
        dialog.connect("delete-event", lambda *_a: True)
        box = dialog.get_content_area()
        box.set_spacing(12)
        box.set_border_width(18)
        label = Gtk.Label()
        label.set_markup(
            "<span size='large'><b>Installing Zaviya to internal storage</b></span>\n\n"
            "This takes about 5 to 10 minutes. Don't close this window, restart or\n"
            "turn the device off until it says the install has finished.")
        label.set_line_wrap(True)
        box.pack_start(label, False, False, 0)
        bar = Gtk.ProgressBar()
        box.pack_start(bar, False, False, 0)
        dialog.pulse_id = GLib.timeout_add(150, lambda: (bar.pulse(), True)[1])
        dialog.show_all()
        return dialog


def main() -> int:
    win = MainWindow()
    win.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
