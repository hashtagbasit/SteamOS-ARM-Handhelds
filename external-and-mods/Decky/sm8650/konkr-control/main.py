#!/usr/bin/env python3
"""Decky backend — Zaviya Control.

Thin front for the device daemon: konkrd (KONKR Pocket FIT, the 8 Gen 2
devices) or odin3d (AYN Odin 3, KONKR Pocket FIT Elite). Every setting lives
in the daemon's state.json, which it re-reads on SIGHUP, so the buttons,
konkrctl/odin3ctl, the bottom screen and this panel stay in sync.
"""
from __future__ import annotations

import asyncio
import glob
import json
import os
import re
import socket
import subprocess
from typing import Any

import decky

ODIN3D = os.path.exists("/usr/lib/odin3/odin3d")
STATE = "/var/lib/odin3/state.json" if ODIN3D else "/var/lib/konkrd/state.json"
DAEMON = "odin3d" if ODIN3D else "konkrd"
BLACKLIST = "/etc/modprobe.d/konkr-mcu.conf"
FLIP = "/etc/steamos-arm/flip-screen"
REQUEST = "/run/konkrd/request"
INSTALL_DIR = "/usr/share/zaviya-install"
INSTALL_UNIT = "zaviya-install"
INSTALL_LOG = "/run/zaviya-install.log"
LOGS_SCRIPT = "/usr/lib/steamos-arm/steamos-arm-logs"
USER = "steamos"
USER_HOME = "/home/steamos"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def gen5() -> bool:
    """Lenovo Legion Y700 Gen 5 (its bootloader can't be unlocked: Android and
    SteamOS take turns in boot_a)."""
    try:
        with open("/sys/firmware/devicetree/base/compatible", "rb") as fh:
            return "lenovo,baldur" in fh.read().decode(errors="replace").split("\0")
    except OSError:
        return False


def tablet() -> bool:
    """Lenovo Legion Y700 Gen 3 / Gen 4."""
    try:
        with open("/sys/firmware/devicetree/base/compatible", "rb") as fh:
            compat = fh.read().decode(errors="replace").split("\0")
    except OSError:
        return False
    return any(c in compat for c in ("lenovo,tb321fu", "lenovo,elden", "lenovo,baldur"))


def install_unsupported() -> bool:
    """The installer runs from a microSD card or USB drive, and not on SM8250."""
    if "qcom,sm8250" in rd("/sys/firmware/devicetree/base/compatible").split("\0") or gen5():
        return True
    src = subprocess.run(["findmnt", "-no", "SOURCE", "/"], capture_output=True, text=True).stdout.strip()
    disk = subprocess.run(["lsblk", "-no", "PKNAME", src], capture_output=True, text=True).stdout.split("\n")[0].strip()
    if not disk:
        return True
    return not (disk.startswith("mmcblk") or "/usb" in os.path.realpath(f"/sys/class/block/{disk}"))


def unit_props() -> dict[str, str]:
    out = subprocess.run(["systemctl", "show", INSTALL_UNIT, "-p", "LoadState,ActiveState,SubState,Result,ExecMainStatus"],
                         capture_output=True, text=True).stdout
    return dict(ln.split("=", 1) for ln in out.splitlines() if "=" in ln)


def last_log_line() -> str:
    try:
        with open(INSTALL_LOG, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - 4096))
            tail = fh.read().decode(errors="replace")
    except OSError:
        return ""
    # rsync redraws its progress line with \r
    lines = [ANSI.sub("", ln).strip() for ln in re.split(r"[\r\n]", tail)]
    return next((ln for ln in reversed(lines) if ln), "")


PROFILES = ("silent", "balanced", "turbo")
ACTIONS = ("profile-next", "rgb-next", "sticks-toggle", "fan-boost", "game", "none")


def rd(path: str, default: str = "") -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return default


def load() -> dict[str, Any]:
    try:
        with open(STATE, encoding="utf-8") as fh:
            st = json.load(fh)
    except (OSError, ValueError):
        st = {}
    st.setdefault("profile", "balanced")
    st.setdefault("rgb", {"mode": "static", "color": "ff3c00", "brightness": 160})
    st.setdefault("fan", {"mode": "auto", "fixed": 50, "boost": False})
    st.setdefault("power_led", True)
    st.setdefault("menu_clicks", True)
    st.setdefault("buttons", {"F13": "rgb-next", "F14": "profile-next"})
    st.setdefault("remap", {"steam": "default", "perf": "default"})
    return st


GAME_FILE = "/run/konkr/game.json"
FAN_FILE = "/run/konkr/fan.json"
# konkrd's built-in curves as [temp °C, speed %], for the graph and as the
# starting point of a new curve. Keep in step with FAN_CURVES in konkrd.
BUILTIN_CURVES = {
    "silent": [[65, 20], [76, 30], [82, 40], [88, 60], [94, 80], [98, 100]],
    "balanced": [[55, 20], [72, 30], [78, 40], [84, 60], [90, 80], [96, 100]],
    "turbo": [[45, 20], [66, 30], [74, 40], [80, 60], [85, 80], [90, 100]],
}
# Steam button and Performance button (Pocket FIT). konkrd rewrites the
# InputPlumber maps from the saved choice (its REMAP_TARGET); this is the
# allowlist for the state file.
REMAP_CHOICES = ("default", "start", "select", "steam", "quickaccess")
REMAP_KEYS = ("steam", "perf")
REMAP_MAPS = {
    "/etc/inputplumber/capability_maps.d/konkr_pocketfit_deck.yaml": "BTN_MODE",
    "/etc/inputplumber/capability_maps.d/konkr_pocketfit_dinput.yaml": "BTN_MODE",
    "/etc/inputplumber/capability_maps.d/konkr_pocketfit_sysbtn.yaml": "BTN_TRIGGER_HAPPY5",
}


def remap_available() -> bool:
    """All maps are installed with the entries konkrd edits."""
    for path, code in REMAP_MAPS.items():
        if f"event_code: {code}," not in rd(path):
            return False
    return True


def clean_remap(raw: Any) -> dict[str, str]:
    raw = raw if isinstance(raw, dict) else {}
    return {k: raw[k] if raw.get(k) in REMAP_CHOICES else "default" for k in REMAP_KEYS}


REACTIONS = ("gentle", "calm", "quick", "instant")
MAX_CURVES = 8


def clean_curve(points: Any) -> list[list[int]] | None:
    """Sorted [temp, speed] points, 2 to 8, the speed never dropping as the
    temperature rises; None if there aren't two usable points."""
    out: list[list[int]] = []
    try:
        pts = sorted((max(20, min(105, int(t))), max(0, min(100, int(p)))) for t, p in points)
    except (TypeError, ValueError):
        return None
    for t, p in pts:
        if out and t <= out[-1][0]:
            continue
        out.append([t, max(p, out[-1][1] if out else 0)])
    return out[:8] if len(out) >= 2 else None


def game_fan_state(st: dict[str, Any]) -> dict[str, Any]:
    """The game konkrd sees running (0 for none) and its fan choice."""
    try:
        appid = int(json.load(open(GAME_FILE, encoding="utf-8")).get("appid", 0))
    except (OSError, ValueError, TypeError):
        appid = 0
    entry = (st.get("fan_games") or {}).get(str(appid)) if appid else None
    if not entry:
        choice = "global"
    elif entry.get("mode") == "fixed":
        choice = f"fixed-{int(entry.get('fixed', 50))}"
    else:
        choice = entry.get("curve", "global")
    return {"appid": appid, "fan": choice}


def fan_live() -> dict[str, Any] | None:
    """What konkrd's fan curve sees right now (smoothed temperature, the
    speed it's on and the one it's heading for)."""
    try:
        with open(FAN_FILE, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def save(st: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE + ".tmp", "w", encoding="utf-8") as fh:
        json.dump(st, fh, indent=2)
    os.replace(STATE + ".tmp", STATE)
    subprocess.run(["systemctl", "kill", "-s", "HUP", f"{DAEMON}.service"], check=False)


def telemetry() -> dict[str, Any]:
    out: dict[str, Any] = {"fan_rpm": None, "fan_pwm": None, "gpu_mhz": None, "temp_c": None}
    for d in glob.glob("/sys/class/hwmon/hwmon*"):
        if rd(f"{d}/name") == "pwmfan":
            out["fan_rpm"] = int(rd(f"{d}/fan1_input", "0") or 0)
            out["fan_pwm"] = int(rd(f"{d}/pwm1", "0") or 0)
    for d in glob.glob("/sys/class/devfreq/*gpu*"):
        cur = rd(f"{d}/cur_freq")
        if cur.isdigit():
            out["gpu_mhz"] = int(cur) // 1_000_000
    temps = []
    for z in glob.glob("/sys/class/thermal/thermal_zone*"):
        if rd(f"{z}/type").startswith(("cpu", "gpu")):
            v = rd(f"{z}/temp")
            if v.lstrip("-").isdigit():
                temps.append(int(v) / 1000)
    if temps:
        out["temp_c"] = round(max(temps), 1)
    return out


# Bypass charging lives in steamos-arm-power (it also serves Steam's charge
# limit): plugged in, the battery holds and the device runs from the charger.
POWER = ["busctl", "--system", "--", "org.steamos_arm.Power", "/org/steamos_arm/Power", "org.steamos_arm.Power1"]


LIMIT = ["com.steampowered.SteamOSManager1.BatteryChargeLimit1", "MaxChargeLevel"]


def charge_limit() -> int | None:
    """Steam's charge limit as our power service keeps it: a percentage, 100
    for none, None without a battery that takes one."""
    if not glob.glob("/sys/class/power_supply/*/charge_control_end_threshold"):
        return None
    r = subprocess.run(["busctl", "--system", "get-property", *POWER[3:5], *LIMIT],
                       capture_output=True, text=True, timeout=5)
    if r.returncode != 0:
        return None
    v = int(r.stdout.split()[-1])
    return 100 if v < 0 else v


def bypass_state() -> dict[str, Any]:
    out: dict[str, Any] = {"supported": False, "on": False, "level": 55}
    for prop, key in (("BypassSupported", "supported"), ("BypassCharging", "on"), ("BypassLevel", "level")):
        r = subprocess.run(["busctl", "--system", "get-property", *POWER[3:], prop],
                           capture_output=True, text=True, timeout=5)
        if r.returncode != 0:
            return out
        val = r.stdout.split(maxsplit=1)[-1].strip()
        out[key] = (val == "true") if key != "level" else int(val)
    return out


STEAM = "/home/steamos/.local/share/Steam"
# Steam's own tools show up as installed apps too.
NOT_GAMES = re.compile(r"^(Proton|Steam Linux Runtime|Steamworks Common|SteamVR|FEX$|Lepton$)", re.I)


def installed_games() -> list[dict[str, Any]]:
    """Installed Steam games, by name, from every library's app manifests."""
    libs = {f"{STEAM}/steamapps"}
    for path in re.findall(r'"path"\s+"([^"]+)"', rd(f"{STEAM}/steamapps/libraryfolders.vdf")):
        libs.add(f"{path}/steamapps")
    games = {}
    for lib in libs:
        for mf in glob.glob(f"{lib}/appmanifest_*.acf"):
            text = rd(mf)
            appid = re.search(r'"appid"\s+"(\d+)"', text)
            name = re.search(r'"name"\s+"([^"]+)"', text)
            if appid and name and not NOT_GAMES.match(name.group(1)):
                games[int(appid.group(1))] = name.group(1)
    return [{"appid": a, "name": n} for a, n in sorted(games.items(), key=lambda g: g[1].lower())]


GAME_PRIORITIES = ("normal", "high", "highest")


def clean_perf(cfg: dict[str, Any]) -> dict[str, Any]:
    """A game's own performance settings, leaving out what follows the
    profile anyway."""
    out: dict[str, Any] = {}
    if cfg.get("profile") in PROFILES:
        out["profile"] = cfg["profile"]
    if str(cfg.get("cpu_max", "")).isdigit() and int(cfg["cpu_max"]) < 100:
        out["cpu_max"] = max(30, int(cfg["cpu_max"]))
    for key in ("gpu_min", "gpu_max"):
        if str(cfg.get(key, "")).isdigit():
            out[key] = min(100, int(cfg[key]))
    if "gpu_min" in out and "gpu_max" in out and out["gpu_min"] > out["gpu_max"]:
        out["gpu_min"] = out["gpu_max"]
    cores = str(cfg.get("cores", "default")).replace(" ", "")
    if cores in ("all", "big") or (cores not in ("", "default") and re.fullmatch(r"\d+(-\d+)?(,\d+(-\d+)?)*", cores)):
        out["cores"] = cores
    if cfg.get("priority") in GAME_PRIORITIES[1:]:
        out["priority"] = cfg["priority"]
    return out


def system_info() -> dict[str, Any]:
    osr = dict(line.split("=", 1) for line in rd("/etc/os-release").splitlines() if "=" in line)
    ips = subprocess.run(["ip", "-4", "-o", "addr", "show", "scope", "global"],
                         capture_output=True, text=True).stdout.split("\n")
    return {
        "os": osr.get("PRETTY_NAME", "").strip('"'),
        "build": osr.get("BUILD_ID", "").strip('"'),
        "kernel": os.uname().release,
        "ip": ", ".join(l.split()[3].split("/")[0] for l in ips if len(l.split()) > 3),
        "ssh": subprocess.run(["systemctl", "is-active", "--quiet", "sshd"]).returncode == 0,
        "has_password": has_password(),
    }


def has_password(user: str = "steamos") -> bool:
    """SSH logs in with the user's password (root login is off), and sshd
    turns away an empty one."""
    for line in rd("/etc/shadow").splitlines():
        name, _, rest = line.partition(":")
        if name == user:
            pw = rest.split(":", 1)[0]
            return bool(pw) and pw[0] not in "!*"
    return False


def mode_of(st: dict[str, Any]) -> tuple[str, bool]:
    return st["profile"], bool(st["fan"].get("boost"))


class Plugin:
    async def _main(self) -> None:
        self.watcher = asyncio.create_task(self._watch_mode())
        decky.logger.info(f"Zaviya Control ready ({DAEMON})")

    async def _unload(self) -> None:
        self.watcher.cancel()

    # The KONKR/Performance button goes straight to konkrd, so the frontend
    # would only see a change once the panel is opened. Watch konkrd's state
    # and tell the frontend, which shows a toast over whatever is running.
    async def _watch_mode(self) -> None:
        try:
            await self._watch_mode_loop()
        except asyncio.CancelledError:
            raise
        except Exception:
            decky.logger.exception("mode watcher stopped")

    async def _watch_mode_loop(self) -> None:
        stamp = None
        mode = mode_of(load())
        while True:
            await asyncio.sleep(0.25)
            try:
                cur = os.stat(STATE).st_mtime_ns
            except OSError:
                continue
            if cur == stamp:
                continue
            stamp = cur
            new = mode_of(load())
            if new != mode:
                old, mode = mode, new
                decky.logger.info(f"mode {old} -> {new}")
                await decky.emit("konkr_mode", new[0], new[1], old[0] != new[0])

    async def get_state(self, **_: Any) -> dict[str, Any]:
        st = load()
        model = rd("/sys/firmware/devicetree/base/model").rstrip("\0")
        leds = glob.glob("/sys/class/leds/*joysticks*") + glob.glob("/sys/class/leds/*-joystick") \
            + glob.glob("/sys/class/leds/rgb:[lr][0-9]") + glob.glob("/sys/class/leds/[lr]:r1")
        fit = model == "KONKR Pocket FIT"
        return {
            "model": model,
            "daemon_name": DAEMON,
            "profile": st["profile"],
            "rgb": st["rgb"],
            "fan": st["fan"],
            "fan_curves": st.get("fan_curves") or {},
            "builtin_curves": BUILTIN_CURVES,
            "fan_live": fan_live(),
            "fan_editor": not ODIN3D,
            "perf_games": st.get("perf_games") or {},
            "fan_games": st.get("fan_games") or {},
            "cpus": os.cpu_count() or 8,
            "game": game_fan_state(st),
            "power_led": st["power_led"],
            "menu_clicks": st["menu_clicks"],
            "tablet": tablet(),
            "has_flip": tablet(),
            # The Lenovo tablets have no fan: no Fan page, no fan choices per game.
            "has_fan": not tablet(),
            "flip": os.path.exists(FLIP),
            # Tablets: SteamOS on the microSD card next to Android. Handhelds:
            # OpenABL, whose menu picks Android or Linux.
            "has_dualboot": not tablet() or subprocess.run(["sh", "-c", "findmnt -no SOURCE / | grep -q mmcblk || "
                                                            "[ \"$(lsblk -no PARTLABEL \"$(findmnt -no SOURCE /)\")\" = steamos ]"]).returncode == 0,
            "dualboot_label": ("Restart into ZUI" if gen5() else "Restart into ZUXOS") if tablet() else "Restart into Android",
            "dualboot_text": ("SteamOS runs next to Android. This restarts into "
                              + ("ZUI; to come back, use Switch to SteamOS in KernelSU" if gen5()
                                 else "ZUXOS; to come back, run fastboot set_active b")) if tablet() else
                             ("Restarts into the boot menu: choose Switch boot mode until it says Android, "
                              "then Start. To come back, restart holding Volume Down and switch it back to Linux."),
            "has_motors": any("HID_ID=0003:00004001:00000428" in rd(f"{d}/device/uevent")
                              for d in glob.glob("/sys/class/hidraw/hidraw*")),
            "buttons": st["buttons"],
            # What this device has, so the panel only shows what works here.
            "has_power_led": not ODIN3D and bool(glob.glob("/sys/class/leds/*power-led*")),
            "has_mcu_link": fit and not ODIN3D,
            "has_breath": not ODIN3D and any(os.path.exists(f"{d}/effect") for d in leds),
            "fit_buttons": fit,
            "remap": clean_remap(st.get("remap")),
            "remap_available": fit and await asyncio.to_thread(remap_available),
            "mcu_enabled": not os.path.exists(BLACKLIST),
            "mcu_loaded": os.path.isdir("/sys/module/konkr_sysbtn"),
            "sticks_led": bool(leds),
            "daemon": subprocess.run(["systemctl", "is-active", "--quiet", DAEMON]).returncode == 0,
            "bypass": await asyncio.to_thread(bypass_state),
            "charge_limit": await asyncio.to_thread(charge_limit),
            "system": await asyncio.to_thread(system_info),
            **await asyncio.to_thread(telemetry),
        }

    async def set_bypass(self, on: bool = False, **_: Any) -> dict[str, Any]:
        await asyncio.to_thread(subprocess.run, ["busctl", "--system", "set-property", *POWER[3:],
                                                 "BypassCharging", "b", "true" if on else "false"],
                                capture_output=True, timeout=5)
        return await asyncio.to_thread(bypass_state)

    async def set_ssh(self, on: bool = False, **_: Any) -> bool:
        if on and not has_password():
            return False
        await asyncio.to_thread(subprocess.run, ["systemctl", "enable" if on else "disable", "--now", "sshd"])
        return system_info()["ssh"]

    async def set_password(self, password: str = "", **_: Any) -> bool:
        """Password for the steamos user (sudo and SSH use it)."""
        if len(password) < 4 or any(c in password for c in ":\n"):
            return False
        r = await asyncio.to_thread(subprocess.run, ["chpasswd"], input=f"steamos:{password}\n",
                                    text=True, capture_output=True)
        return r.returncode == 0

    async def set_charge_limit(self, level: int = 100, **_: Any) -> int | None:
        """Stop charging at level % (100 = charge to full)."""
        level = int(level)
        await asyncio.to_thread(subprocess.run, ["busctl", "--system", "set-property", "--", *POWER[3:5], *LIMIT,
                                                 "i", str(-1 if level >= 100 else max(55, level))],
                                capture_output=True, timeout=5)
        return await asyncio.to_thread(charge_limit)

    async def set_profile(self, profile: str = "balanced", **_: Any) -> str:
        if profile not in PROFILES:
            return load()["profile"]
        st = load()
        st["profile"] = profile
        save(st)
        return profile

    async def set_rgb(self, mode: str = "static", color: str = "ff3c00", brightness: int = 160, **_: Any) -> dict:
        rgb = {"mode": mode, "color": color.lstrip("#").lower()[:6],
               "brightness": max(0, min(255, int(brightness)))}
        # konkrd's request socket sets the lights without reloading
        # everything, fast enough to follow a slider.
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
                sock.sendto(f"rgb-set:{rgb['mode']}:{rgb['color']}:{rgb['brightness']}".encode(), REQUEST)
            return rgb
        except OSError:
            pass
        st = load()
        st["rgb"] = rgb
        save(st)
        return st["rgb"]

    async def set_mcu(self, enabled: bool = False, **_: Any) -> bool:
        if enabled:
            if os.path.exists(BLACKLIST):
                os.remove(BLACKLIST)
            subprocess.run(["modprobe", "konkr_sysbtn"], check=False)
        else:
            with open(BLACKLIST, "w", encoding="utf-8") as fh:
                fh.write("# Pocket FIT MCU UART driver — opt-in (konkrctl mcu enable)\nblacklist konkr_sysbtn\n")
            subprocess.run(["modprobe", "-r", "konkr_sysbtn"], check=False)
        subprocess.run(["systemctl", "restart", "inputplumber.service"], check=False)
        return enabled

    async def set_fan(self, mode: str = "auto", fixed: int = 50, boost: bool = False, **_: Any) -> dict:
        st = load()
        st["fan"].update(mode="fixed" if mode == "fixed" else "auto",
                         fixed=max(0, min(100, int(fixed))), boost=bool(boost))
        save(st)
        return st["fan"]

    async def get_games(self, **_: Any) -> list[dict[str, Any]]:
        return await asyncio.to_thread(installed_games)

    async def set_game_perf(self, appid: int = 0, cfg: Any = None, **_: Any) -> dict[str, Any]:
        """One game's own performance settings ({} = follow the profile).
        konkrd applies them while the game runs, at once if it already does."""
        st = load()
        games = st.setdefault("perf_games", {})
        clean = clean_perf(cfg if isinstance(cfg, dict) else {})
        if int(appid or 0):
            if clean:
                games[str(int(appid))] = clean
            else:
                games.pop(str(int(appid)), None)
            save(st)
        return games

    async def set_charging_fan(self, pct: int = 0, **_: Any) -> dict:
        st = load()
        st["fan"]["charging_min"] = max(0, min(60, int(pct)))
        save(st)
        return st["fan"]

    async def set_fan_tuning(self, curve: str = "", reaction: str = "calm", stop_below: int = 0,
                             **_: Any) -> dict:
        """The curve the fan follows ("" = the profile's, a built-in name or
        one of the user's), how fast it reacts, and the temperature it may
        stop under (0 = never)."""
        st = load()
        mine = st.get("fan_curves") or {}
        st["fan"].update(curve=curve if curve in BUILTIN_CURVES or curve in mine else "",
                         reaction=reaction if reaction in REACTIONS else "calm",
                         stop_below=0 if not stop_below else max(35, min(70, int(stop_below))))
        save(st)
        return st["fan"]

    async def save_fan_curve(self, name: str = "", points: Any = None, **_: Any) -> dict:
        """Create or update one of the user's curves. Returns all of them."""
        st = load()
        mine = st.setdefault("fan_curves", {})
        name = " ".join(str(name).split())[:24]
        pts = clean_curve(points or [])
        reserved = name in BUILTIN_CURVES or name == "global" or name.startswith("fixed-")
        if name and pts and not reserved and (name in mine or len(mine) < MAX_CURVES):
            mine[name] = pts
            save(st)
        return mine

    async def rename_fan_curve(self, old: str = "", new: str = "", **_: Any) -> dict:
        st = load()
        mine = st.setdefault("fan_curves", {})
        new = " ".join(str(new).split())[:24]
        reserved = new in BUILTIN_CURVES or new == "global" or new.startswith("fixed-")
        if old in mine and new and not reserved and new not in mine:
            mine[new] = mine.pop(old)
            if st["fan"].get("curve") == old:
                st["fan"]["curve"] = new
            for entry in (st.get("fan_games") or {}).values():
                if entry.get("curve") == old:
                    entry["curve"] = new
            save(st)
        return mine

    async def delete_fan_curve(self, name: str = "", **_: Any) -> dict:
        st = load()
        mine = st.setdefault("fan_curves", {})
        if mine.pop(name, None) is not None:
            if st["fan"].get("curve") == name:
                st["fan"]["curve"] = ""
            for appid, entry in list((st.get("fan_games") or {}).items()):
                if entry.get("curve") == name:
                    st["fan_games"].pop(appid)
            save(st)
        return mine

    async def set_game_fan(self, appid: int = 0, choice: str = "global", **_: Any) -> dict:
        """The running game's own fan setting: "global" (none), a curve
        ("silent", "balanced", "turbo") or "fixed-<percent>"."""
        appid = int(appid or 0)
        st = load()
        games = st.setdefault("fan_games", {})
        if not appid:
            return game_fan_state(st)
        if choice == "global":
            games.pop(str(appid), None)
        elif choice in BUILTIN_CURVES or choice in (st.get("fan_curves") or {}):
            games[str(appid)] = {"curve": choice}
        elif choice.startswith("fixed-") and choice[6:].isdigit():
            games[str(appid)] = {"mode": "fixed", "fixed": max(0, min(100, int(choice[6:])))}
        save(st)
        return game_fan_state(st)

    async def set_button(self, key: str = "F13", action: str = "none", **_: Any) -> dict:
        if key not in ("F13", "F14") or action not in ACTIONS:
            return load()["buttons"]
        st = load()
        st["buttons"][key] = action
        save(st)
        return st["buttons"]

    async def set_remap(self, button: str = "steam", choice: str = "default", **_: Any) -> dict:
        """Steam button or Performance button: saved here, applied by konkrd
        (it rewrites the InputPlumber maps and queues an InputPlumber restart
        if they changed, on the HUP from save() and again at every start)."""
        st = load()
        if button in REMAP_KEYS and choice in REMAP_CHOICES:
            remap = clean_remap(st.get("remap"))
            remap[button] = choice
            st["remap"] = remap
            save(st)
        return clean_remap(st.get("remap"))

    async def set_menu_clicks(self, on: bool = True, **_: Any) -> bool:
        st = load()
        st["menu_clicks"] = bool(on)
        save(st)
        return st["menu_clicks"]

    async def set_flip(self, on: bool = False, **_: Any) -> bool:
        """Lenovo tablets: Game Mode the other way up. gamescope reads it when
        Game Mode starts; the touch mapping follows through udev now."""
        if on:
            os.makedirs(os.path.dirname(FLIP), exist_ok=True)
            open(FLIP, "w").close()
        elif os.path.exists(FLIP):
            os.remove(FLIP)
        await asyncio.to_thread(subprocess.run, ["udevadm", "trigger", "--subsystem-match=input", "--action=change"])
        return os.path.exists(FLIP)

    async def boot_android(self, **_: Any) -> bool:
        """Restart into Android: tablets switch back to their Android (ZUXOS or
        ZUI), handhelds restart into the ABL's boot menu."""
        # Gen 5: copy Android's boot image back into boot_a. Gen 4: make slot A active.
        # Handhelds: restart into the ABL's menu. OpenABL keeps its boot mode
        # in a UEFI variable, out of reach while we boot without EFI.
        if not tablet():
            tool = ["systemctl", "reboot", "--reboot-argument=bootloader"]
        else:
            tool = ["/usr/lib/steamos-arm/gen5-android"] if gen5() else ["/usr/lib/steamos-arm/tablet-slot", "android"]
        r = await asyncio.to_thread(subprocess.run, tool)
        return r.returncode == 0

    async def set_power_led(self, on: bool = True, **_: Any) -> bool:
        st = load()
        st["power_led"] = bool(on)
        save(st)
        return st["power_led"]

    async def install_probe(self, **_: Any) -> dict[str, Any]:
        """Sizes and state of the internal disk, from the installer's probe."""
        if await asyncio.to_thread(install_unsupported):
            return {"unsupported": True}
        script = f"{INSTALL_DIR}/ufs-probe-sizes.sh"
        if not os.path.isfile(script):
            return {"error": "The installer is missing from this image"}
        r = await asyncio.to_thread(subprocess.run, [script], capture_output=True, text=True)
        out: dict[str, Any] = {}
        for ln in r.stdout.splitlines():
            if "=" in ln:
                k, v = ln.split("=", 1)
                out[k] = v
        if r.returncode != 0 or "ERROR" in out:
            return {"error": out.get("ERROR") or r.stderr.strip() or f"exit {r.returncode}"}
        return out

    async def install_start(self, android_gb: int = 0, home_mode: str = "all", fingerprint: str = "",
                            reinstall: bool = False, **_: Any) -> dict[str, Any]:
        """Runs the installer as a system unit, so it outlives Steam and this plugin."""
        if home_mode not in ("all", "essentials", "none"):
            return {"error": "Unknown choice for what to bring"}
        if not re.fullmatch(r"[0-9a-f]{16}", str(fingerprint)):
            return {"error": "No partition table to check against; reopen the panel"}
        try:
            android_gb = int(android_gb)
        except (TypeError, ValueError):
            return {"error": "Android size must be a whole number"}
        if await asyncio.to_thread(install_unsupported):
            return {"error": "Not supported here"}
        props = await asyncio.to_thread(unit_props)
        if props.get("LoadState") == "loaded" and props.get("ActiveState") in ("active", "activating") \
                and props.get("SubState") in ("start", "running"):
            return {"error": "An install is already running"}
        # A finished unit is kept (--remain-after-exit) so its result can be read.
        await asyncio.to_thread(subprocess.run, ["systemctl", "stop", INSTALL_UNIT], capture_output=True)
        await asyncio.to_thread(subprocess.run, ["systemctl", "reset-failed", INSTALL_UNIT], capture_output=True)
        try:
            open(INSTALL_LOG, "w").close()
        except OSError as e:
            return {"error": str(e)}
        size = ["--resume"] if reinstall else ["--android-gb", str(android_gb)]
        r = await asyncio.to_thread(subprocess.run, [
            "systemd-run", f"--unit={INSTALL_UNIT}", "--remain-after-exit",
            f"--property=StandardOutput=append:{INSTALL_LOG}", f"--property=StandardError=append:{INSTALL_LOG}",
            f"{INSTALL_DIR}/install-to-internal.sh", "--force", "--expect", fingerprint, "--home", home_mode, *size,
        ], capture_output=True, text=True)
        if r.returncode != 0:
            return {"error": r.stderr.strip() or f"exit {r.returncode}"}
        return {"ok": True}

    async def install_status(self, **_: Any) -> dict[str, str]:
        """idle: no unit. running, then done (exit 0) or failed. The unit stays
        after it ends (--remain-after-exit) because --collect would drop a
        failed one before its result could be read."""
        p = await asyncio.to_thread(unit_props)
        active, sub = p.get("ActiveState", ""), p.get("SubState", "")
        if p.get("LoadState") != "loaded":
            state = "idle"
        elif active == "failed":
            state = "failed"
        elif active in ("active", "activating") and sub in ("start", "running"):
            state = "running"
        elif active == "active":
            state = "done"
        else:
            state = "idle"
        return {"state": state, "line": await asyncio.to_thread(last_log_line) if state != "idle" else ""}

    async def record_logs(self, **_: Any) -> dict[str, str]:
        """Run the log recorder as the steamos user, so the archive in its home
        folder belongs to them. The plugin itself runs as root."""
        try:
            r = await asyncio.wait_for(asyncio.to_thread(
                subprocess.run, ["runuser", "-u", USER, "--", "env", f"HOME={USER_HOME}", LOGS_SCRIPT],
                capture_output=True, text=True), timeout=240)
        except asyncio.TimeoutError:
            return {"error": "Timed out"}
        except OSError as e:
            return {"error": str(e)}
        lines = r.stdout.strip().splitlines()
        if r.returncode != 0 or not lines:
            return {"error": r.stderr.strip().splitlines()[-1] if r.stderr.strip() else f"exit {r.returncode}"}
        return {"path": lines[-1]}
