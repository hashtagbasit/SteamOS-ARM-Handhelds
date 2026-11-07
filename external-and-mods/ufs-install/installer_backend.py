#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Backend of the Zaviya installer: everything except the window.

Pure standard library (no gi). The window calls Installer.probe(),
Installer.start() and Installer.status(); the rest is parsing and checks that
can be tested without a device. With ZAVIYA_INSTALLER_FAKE=1 the Installer
pretends, with canned sizes and a simulated log, so the window can be built and
looked at on a computer.
"""
from __future__ import annotations

import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from typing import Callable, Optional

INSTALL_UNIT = "zaviya-install"
INSTALL_LOG = "/run/zaviya-install.log"
HERE = os.path.dirname(os.path.abspath(__file__))

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
FINGERPRINT_RE = re.compile(r"[0-9a-f]{16}")
HOME_MODES = ("all", "essentials", "none")


# ------------------------------------------------------------------ probe ----
def parse_probe(text: str) -> "dict[str, str]":
    """KEY=VALUE lines of the sizing probe. Anything else is ignored."""
    out: "dict[str, str]" = {}
    for line in (text or "").splitlines():
        m = re.match(r"^([A-Z][A-Z0-9_]*)=(.*)$", line.strip())
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


@dataclass
class Probe:
    min_gib: int = 0
    max_gib: int = 0
    recommended_gib: int = 0
    fingerprint: str = ""
    existing_install: bool = False
    tablet: bool = False
    running_from_removable: bool = False
    error: Optional[str] = None
    orig_android_gib: int = 0
    boot_gib: int = 0
    root_gib: int = 0
    disk_total_gib: int = 0
    mode: str = ""
    unsupported: bool = False
    available_gib: float = 0.0    # room after userdata's start, one decimal (AVAILABLE_GIB)

    @classmethod
    def from_keys(cls, d: "dict[str, str]") -> "Probe":
        """Never raises: a missing or malformed value sets .error instead."""
        if d.get("ERROR"):
            return cls(error=d["ERROR"])
        nums = {}
        for attr, key in (("min_gib", "MIN_ANDROID_GIB"), ("max_gib", "MAX_ANDROID_GIB"),
                          ("recommended_gib", "RECOMMENDED_ANDROID_GIB"),
                          ("orig_android_gib", "ORIG_ANDROID_GIB"), ("boot_gib", "BOOT_PART_GIB"),
                          ("root_gib", "ROOT_PART_GIB")):
            raw = d.get(key)
            if raw is None or not re.fullmatch(r"\d+", raw.strip()):
                return cls(error=f"The storage check did not report {key}")
            nums[attr] = int(raw)
        # The total is "123.4" in the raw detect output; the probe passes it on.
        raw = d.get("DISK_TOTAL_GIB", "")
        if not re.fullmatch(r"\d+(\.\d+)?", raw.strip()):
            return cls(error="The storage check did not report DISK_TOTAL_GIB")
        nums["disk_total_gib"] = int(float(raw))
        avail = d.get("AVAILABLE_GIB", "").strip()
        nums["available_gib"] = float(avail) if re.fullmatch(r"\d+(\.\d+)?", avail) else 0.0
        fp = d.get("TABLE_FINGERPRINT", d.get("FINGERPRINT", ""))
        if not FINGERPRINT_RE.fullmatch(fp):
            return cls(error="The storage check returned no partition table fingerprint")
        mode = d.get("MODE", "")
        err = None
        if mode == "occupied":
            err = ("Other partitions follow Android's userdata ("
                   + (d.get("OCCUPIED") or "unknown") + "). Remove them first.")
        elif mode == "toosmall":
            err = "There is not enough room after Android's userdata for Zaviya."
        return cls(fingerprint=fp, existing_install=d.get("EXISTING_INSTALL") == "1",
                   tablet=d.get("TABLET") == "1",
                   running_from_removable=d.get("RUNNING_FROM_SD") == "1",
                   error=err, mode=mode, **nums)


def zaviya_home_gib(probe: Probe, android_gib: int) -> int:
    """Home space left for the chosen Android size, in whole GiB, never too high.

    ufs-partition.py plan(): userdata ends android_gib after its start, boot
    starts at the next MiB, then boot_gib and root_gib, and home runs to where
    userdata used to end. So home = room after userdata's start - android -
    boot - root, less a sliver for MiB alignment. The room is AVAILABLE_GIB,
    printed to one decimal (so up to 0.05 off either way); without it the
    whole-GiB orig_android_gib is used.
    """
    room = probe.available_gib - 0.05 if probe.available_gib > 0 else float(probe.orig_android_gib)
    left = room - int(android_gib) - int(probe.boot_gib) - int(probe.root_gib)
    return max(0, int(left // 1))


# ------------------------------------------------------ device checks ----
def _read_compatible() -> str:
    try:
        with open("/sys/firmware/devicetree/base/compatible", "rb") as fh:
            return fh.read().decode(errors="replace")
    except OSError:
        return ""


def _run_out(cmd: "list[str]") -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _root_is_removable(run: Callable[["list[str]"], str], realpath: Callable[[str], str]) -> bool:
    src = run(["findmnt", "-no", "SOURCE", "/"]).strip()
    disk = (run(["lsblk", "-no", "PKNAME", src]).split("\n")[0].strip()) if src else ""
    if not disk:
        return False
    return disk.startswith("mmcblk") or "/usb" in realpath(f"/sys/class/block/{disk}")


def running_from_removable_media(run: Callable[["list[str]"], str] = _run_out,
                                 realpath: Callable[[str], str] = os.path.realpath) -> bool:
    """The root filesystem is on a microSD card or a USB drive."""
    return _root_is_removable(run, realpath)


def install_unsupported(read_compatible: Callable[[], str] = _read_compatible,
                        run: Callable[["list[str]"], str] = _run_out,
                        realpath: Callable[[str], str] = os.path.realpath) -> bool:
    """Not on SM8250, not on the Y700 Gen 5, and only from a card or USB drive."""
    compat = read_compatible().split("\0")
    if "qcom,sm8250" in compat or "lenovo,baldur" in compat:
        return True
    return not _root_is_removable(run, realpath)


# ------------------------------------------------------------ unit state ----
def unit_state(props: "dict[str, str]") -> str:
    """idle | running | done | failed, from `systemctl show` properties."""
    active, sub = props.get("ActiveState", ""), props.get("SubState", "")
    if props.get("LoadState") != "loaded":
        return "idle"
    if active == "failed":
        return "failed"
    if active in ("active", "activating") and sub in ("start", "running"):
        return "running"
    if active == "active":
        return "done"
    return "idle"


def read_unit_props() -> "dict[str, str]":
    out = _run_out(["systemctl", "show", INSTALL_UNIT, "-p",
                    "LoadState,ActiveState,SubState,Result,ExecMainStatus"])
    return dict(ln.split("=", 1) for ln in out.splitlines() if "=" in ln)


# -------------------------------------------------------------- progress ----
# (key, label, weight). Weights are shares of the total time: the two copies
# dominate. Strings in _MARKERS are the install script's log() lines.
_STAGE_DEFS = [
    ("repartition", "Repartitioning internal storage", 3),
    ("format", "Formatting the new partitions", 2),
    ("system", "Copying the system", 45),
    ("home", "Copying games and settings", 38),
    ("kernel", "Installing the boot image", 6),
    ("check", "Checking the result", 6),
    ("done", "Finished", 0),
]
STAGES = [(k, label) for k, label, _ in _STAGE_DEFS]
_WEIGHT = {k: w for k, _, w in _STAGE_DEFS}

_MARKERS = [
    ("repartition", re.compile(r"^\[ufs\] repartitioning")),
    ("format", re.compile(r"^\[ufs\] formatting")),
    ("system", re.compile(r"^\[ufs\] copying the system")),
    ("home", re.compile(r"^\[ufs\] copying (/home \(games included\)|/home without installed games|"
                        r"a fresh /home)")),
    ("kernel", re.compile(r"^\[ufs\] installing KERNEL")),
    ("check", re.compile(r"^\[ufs\] checking the result")),
    ("done", re.compile(r"^\[ufs\] done\.")),
]
_ERROR = re.compile(r"^\[ufs\] ERROR:\s*(.*)$")
_PLAIN_ERROR = re.compile(r"^ERROR:\s*(.*)$")
_PERCENT = re.compile(r"(?:^|\s)(\d{1,3})%(?:\s|$)")


@dataclass
class Progress:
    stage_key: str = STAGES[0][0]
    stage_label: str = STAGES[0][1]
    stage_index: int = 0          # 0-based, into the stages in use
    stage_count: int = len(STAGES)
    percent: Optional[int] = None
    error: Optional[str] = None
    done: bool = False
    fraction: float = 0.0


def clean_segments(text: str) -> "list[str]":
    """Text without colours, split at every newline and carriage return."""
    return [s for s in re.split(r"[\r\n]+", ANSI.sub("", text or "")) if s.strip()]


def parse_progress(log_text: str, reinstall: bool = False) -> Progress:
    stages = [s for s in _STAGE_DEFS if not (reinstall and s[0] == "repartition")]
    keys = [s[0] for s in stages]
    cur, percent, error, done = keys[0], None, None, False
    plain_error = None
    for seg in clean_segments(log_text):
        seg = seg.strip()
        hit = next((k for k, rx in _MARKERS if rx.match(seg)), None)
        if hit and hit in keys:
            cur, percent = hit, None
            if hit == "done":
                done = True
            continue
        m = _ERROR.match(seg)
        if m:
            error = m.group(1).strip() or "The install stopped"
            continue
        m = _PLAIN_ERROR.match(seg)
        if m:
            plain_error = m.group(1).strip()
            continue
        if cur in ("system", "home"):
            m = _PERCENT.search(seg)
            if m and int(m.group(1)) <= 100:
                percent = max(percent or 0, int(m.group(1)))
    if error is None:
        error = plain_error
    idx = keys.index(cur)
    total = sum(w for _, _, w in stages) or 1
    before = sum(w for _, _, w in stages[:idx])
    if done:
        frac = 1.0
    else:
        inside = (percent or 0) / 100 if cur in ("system", "home") else 0.0
        frac = (before + _WEIGHT[cur] * inside) / total
    return Progress(stage_key=cur, stage_label=dict(STAGES)[cur], stage_index=idx,
                    stage_count=len(stages), percent=percent, error=error, done=done,
                    fraction=max(0.0, min(1.0, frac)))


def last_log_lines(text: str, n: int = 8) -> "list[str]":
    """The last n lines, no colours; for a line rewritten with \\r only its last version."""
    lines = []
    for raw in ANSI.sub("", text or "").split("\n"):
        seg = raw.split("\r")
        keep = next((s for s in reversed(seg) if s.strip()), "")
        if keep.strip():
            lines.append(keep.rstrip())
    return lines[-n:] if n > 0 else []


# ------------------------------------------------------------- installer ----
def is_fake() -> bool:
    return os.environ.get("ZAVIYA_INSTALLER_FAKE") == "1"


def _clean_env() -> "dict[str, str]":
    env = dict(os.environ)
    env.pop("LD_LIBRARY_PATH", None)
    env.pop("LD_PRELOAD", None)
    return env


def _refused(rc: int) -> bool:
    return rc in (126, 127)


REFUSED_TEXT = "Administrator rights were refused, so nothing was changed."


class _RealInstaller:
    def __init__(self) -> None:
        self.dir = HERE
        self.reinstall = False

    def _pkexec(self, args: "list[str]") -> "subprocess.CompletedProcess":
        return subprocess.run(["pkexec", *args], capture_output=True, text=True,
                              env=_clean_env(), timeout=300)

    def probe(self) -> Probe:
        if install_unsupported():
            p = Probe()
            p.unsupported = True
            return p
        script = os.path.join(self.dir, "ufs-probe-sizes.sh")
        try:
            r = self._pkexec([script])
        except (OSError, subprocess.SubprocessError) as e:
            return Probe(error=f"Could not run the storage check: {e}")
        keys = parse_probe(r.stdout)
        if _refused(r.returncode) and not keys:
            return Probe(error=REFUSED_TEXT)
        if r.returncode != 0 or "ERROR" in keys:
            return Probe(error=keys.get("ERROR") or r.stderr.strip() or f"The storage check failed (exit {r.returncode})")
        return Probe.from_keys(keys)

    def start(self, android_gib: int, home_mode: str, fingerprint: str, reinstall: bool) -> Optional[str]:
        if home_mode not in HOME_MODES:
            return "Unknown choice for what to bring"
        if not FINGERPRINT_RE.fullmatch(str(fingerprint)):
            return "No partition table to check against; restart the installer"
        size = ["--resume"] if reinstall else ["--android-gb", str(int(android_gib))]
        args = [os.path.join(self.dir, "zaviya-install-start"), "--expect", fingerprint,
                "--home", home_mode, *size]
        try:
            r = self._pkexec(args)
        except (OSError, subprocess.SubprocessError) as e:
            return f"Could not start the install: {e}"
        if r.returncode != 0:
            if _refused(r.returncode):
                return REFUSED_TEXT
            return r.stderr.strip() or f"The install did not start (exit {r.returncode})"
        self.reinstall = bool(reinstall)
        return None

    def status(self) -> "tuple[str, Progress, str]":
        state = unit_state(read_unit_props())
        text = ""
        if state != "idle":
            try:
                with open(INSTALL_LOG, "rb") as fh:
                    fh.seek(0, os.SEEK_END)
                    fh.seek(max(0, fh.tell() - 4 * 1024 * 1024))
                    text = fh.read().decode(errors="replace")
            except OSError:
                text = ""
        return state, parse_progress(text, self.reinstall), text


class _FakeInstaller:
    """Canned sizes and a simulated 20 second install, with the real log strings."""
    DURATION = 20.0

    def __init__(self) -> None:
        self.t0: Optional[float] = None
        self.reinstall = False
        self.home_mode = "all"
        self.fail = os.environ.get("ZAVIYA_INSTALLER_FAKE_FAIL") == "1"

    def probe(self) -> Probe:
        existing = os.environ.get("ZAVIYA_INSTALLER_FAKE_EXISTING") == "1"
        p = Probe(min_gib=16, max_gib=202, recommended_gib=64, fingerprint="0123456789abcdef",
                  existing_install=existing,
                  tablet=os.environ.get("ZAVIYA_INSTALLER_FAKE_TABLET") == "1",
                  running_from_removable=True, orig_android_gib=240, available_gib=240.0, boot_gib=2, root_gib=20,
                  disk_total_gib=256, mode="installed" if existing else "fresh")
        p.unsupported = os.environ.get("ZAVIYA_INSTALLER_FAKE_UNSUPPORTED") == "1"
        return p

    def start(self, android_gib: int, home_mode: str, fingerprint: str, reinstall: bool) -> Optional[str]:
        if home_mode not in HOME_MODES:
            return "Unknown choice for what to bring"
        if not FINGERPRINT_RE.fullmatch(str(fingerprint)):
            return "No partition table to check against; restart the installer"
        self.t0 = time.monotonic()
        self.reinstall = bool(reinstall)
        self.home_mode = home_mode
        return None

    @staticmethod
    def _rsync(pct: int) -> str:
        return (f"\r{int(1.2e9 * pct / 100):>15,} {pct:>3}%   85.00MB/s    0:00:{(100 - pct) // 4:02d}"
                f" (xfr#{pct * 9}, to-chk={1000 - pct * 10}/1000)")

    def _timeline(self) -> "list[tuple[float, float, str, bool]]":
        """(start, end, log line, has rsync progress) for each stage."""
        home_line = {"all": "copying /home (games included)",
                     "essentials": "copying /home without installed games",
                     "none": "copying a fresh /home (Steam client and Decky, no account or personal data)"}
        tl = [(0.0, 0.5, "KONKR Pocket FIT: internal disk /dev/sda (256.0 GiB, 4096-byte sectors)", False)]
        if not self.reinstall:
            tl.append((0.5, 2.0, "repartitioning (one write; the old table goes to /boot/ufs-backup first)", False))
        tl += [(2.0, 3.5, "formatting", False),
               (3.5, 11.0, "copying the system (a few minutes)", True),
               (11.0, 17.0, home_line[self.home_mode], True),
               (17.0, 18.5, "installing KERNEL (root=PARTLABEL=STORAGE)", False),
               (18.5, self.DURATION, "checking the result", False)]
        return tl

    def _log(self, elapsed: float) -> "tuple[str, str]":
        green, red = "\033[1;32m[ufs]\033[0m ", "\033[1;31m[ufs] ERROR:\033[0m "
        text = ""
        for a, b, line, copy in self._timeline():
            if elapsed < a:
                break
            text += green + line + "\n"
            if copy:
                pct = min(100, int(100 * (elapsed - a) / (b - a)))
                text += "".join(self._rsync(p) for p in range(0, pct + 1, 4)) + "\n"
            if self.fail and elapsed >= 9.0:
                return "failed", text + red + "rsync failed while copying the system (simulated)\n"
        if elapsed >= self.DURATION:
            return "done", text + "\n" + green + "done. Zaviya is on internal storage.\n"
        return "running", text

    def status(self) -> "tuple[str, Progress, str]":
        if self.t0 is None:
            return "idle", parse_progress("", self.reinstall), ""
        state, text = self._log(time.monotonic() - self.t0)
        return state, parse_progress(text, self.reinstall), text


class Installer:
    """What the window talks to: probe(), start(), status()."""

    def __init__(self) -> None:
        self._impl = _FakeInstaller() if is_fake() else _RealInstaller()

    def probe(self) -> Probe:
        return self._impl.probe()

    def start(self, android_gib: int, home_mode: str, fingerprint: str, reinstall: bool) -> Optional[str]:
        return self._impl.start(android_gib, home_mode, fingerprint, reinstall)

    def status(self) -> "tuple[str, Progress, str]":
        return self._impl.status()
