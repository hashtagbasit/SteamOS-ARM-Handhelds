#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Puts "Zaviya Installer" in Steam's library while running from a card or USB drive.

Run before Steam starts (RUNSTEAM.sh). On removable media the shortcut and its
artwork are added to every Steam user's shortcuts.vdf; on internal storage any
such entry is removed again. A file is only rewritten when something changes,
and one that cannot be parsed is left alone. Always exits 0.

  seed-installer-shortcut.py [--steam-root DIR] [--vdf-module FILE]
                             [--force-removable yes|no] [--art-dir DIR]
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
NAME = "Zaviya Installer"
EXE = "/usr/bin/zaviya-installer"
ICON = "/usr/share/zaviya-install/art/installer-icon.png"
DEFAULT_VDF = str(HERE / "shortcuts_vdf.py")


def load_vdf(path: str):
    # By file path: the package's __init__ may import a window toolkit.
    spec = importlib.util.spec_from_file_location("seed_shortcuts_vdf", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def parse_file(vdf, path: Path):
    """The parsed tree, or None when the file is absent or empty; raises if it does not parse."""
    if not path.is_file():
        return None
    data = path.read_bytes()
    if not data:
        return None
    tree, end = vdf.parse_binary_vdf(data)
    if end != len(data):
        raise ValueError("trailing data")
    if "shortcuts" not in tree:
        tree = {"shortcuts": tree}
    return tree


def entries(tree: dict) -> "list[tuple[str, dict]]":
    sc = tree.get("shortcuts", {})
    return [(k, v) for k, v in sc.items() if k != "tags" and isinstance(v, dict)]


def named(tree: dict, name: str) -> "list[str]":
    return [k for k, v in entries(tree) if v.get("AppName") == name]


def remove_and_renumber(tree: dict, keys: "list[str]") -> dict:
    sc = tree["shortcuts"]
    kept = [v for k, v in sorted(entries(tree), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 1 << 30)
            if k not in keys]
    new = {str(i): v for i, v in enumerate(kept)}
    for k, v in sc.items():
        if k == "tags" or (not isinstance(v, dict)):
            new[k] = v
    tree["shortcuts"] = new
    return tree


def write_tree(vdf, path: Path, tree: dict) -> None:
    if path.is_file():
        path.with_suffix(".vdf.bak").write_bytes(path.read_bytes())
    vdf.save_shortcuts(path, tree)
    os.chmod(path, 0o644)


# Steam's grid names for the shortcut's unsigned appid: portrait capsule, wide capsule, hero
# banner and transparent logo. The .json is the logo's position over the hero, in Steam's format.
ART = (("installer-portrait.png", "{}p.png"), ("installer-wide.png", "{}.png"),
       ("installer-hero.png", "{}_hero.png"), ("installer-logo.png", "{}_logo.png"))
LOGO_POSITION = {"nVersion": 1, "logoPosition": {"pinnedPosition": "BottomLeft", "nWidthPct": 42, "nHeightPct": 60}}


def put_file(out: Path, data: bytes) -> None:
    if not out.is_file() or out.read_bytes() != data:
        out.write_bytes(data)
        os.chmod(out, 0o644)


def put_art(grid: Path, app_id: int, art_dir: Path) -> None:
    grid.mkdir(parents=True, exist_ok=True)
    for src, dst in ART:
        put_file(grid / dst.format(app_id), (art_dir / src).read_bytes())
    put_file(grid / f"{app_id}.json", (json.dumps(LOGO_POSITION) + "\n").encode())


def drop_art(grid: Path, app_id: int) -> None:
    for dst in [d for _, d in ART] + ["{}.json"]:
        try:
            (grid / dst.format(app_id)).unlink()
        except FileNotFoundError:
            pass


def seed_user(vdf, cfg: Path, want: bool, art_dir: Path) -> str:
    path = cfg / "shortcuts.vdf"
    exe = str(Path(EXE).resolve())
    app_id = vdf.compute_app_id(exe, NAME)
    try:
        tree = parse_file(vdf, path)
    except Exception as e:
        return f"{path}: left alone, cannot parse it ({e})"
    if not want:
        if tree and named(tree, NAME):
            write_tree(vdf, path, remove_and_renumber(tree, named(tree, NAME)))
        drop_art(cfg / "grid", app_id)
        return ""
    hits = named(tree, NAME) if tree else []
    ok = False
    if len(hits) == 1:
        e = tree["shortcuts"][hits[0]]
        ok = (vdf.vdf_int_as_unsigned(e.get("appid", 0)) == app_id
              and e.get("Exe") == vdf.format_steam_path(exe)
              and e.get("StartDir") == vdf.format_steam_path(str(Path(exe).parent)))
        if ok and e.get("icon") != ICON:
            e["icon"] = ICON
            write_tree(vdf, path, tree)
    if not ok:
        if hits:
            write_tree(vdf, path, remove_and_renumber(tree, hits))
        vdf.add_shortcut(path, NAME, exe)
        tree = parse_file(vdf, path)
        key = named(tree, NAME)[0]
        tree["shortcuts"][key]["icon"] = ICON
        write_tree(vdf, path, tree)
    put_art(cfg / "grid", app_id, art_dir)
    return ""


def main(argv: "list[str] | None" = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--steam-root", default=os.path.expanduser("~/.local/share/Steam"))
    ap.add_argument("--vdf-module", default=DEFAULT_VDF)
    ap.add_argument("--force-removable", choices=("yes", "no"))
    ap.add_argument("--art-dir", default=str(HERE / "art"))
    a = ap.parse_args(argv)
    try:
        vdf = load_vdf(a.vdf_module)
        if a.force_removable:
            want = a.force_removable == "yes"
        else:
            sys.path.insert(0, str(HERE))
            import installer_backend
            # Not on boards where the installer refuses to run either.
            want = not installer_backend.install_unsupported()
        for cfg in sorted(Path(a.steam_root).glob("userdata/*/config")):
            user = cfg.parent.name
            if not user.isdigit() or user == "0" or not cfg.is_dir():
                continue
            msg = seed_user(vdf, cfg, want, Path(a.art_dir))
            if msg:
                print(f"seed-installer-shortcut: {msg}")
    except Exception as e:  # never stop Steam from starting
        print(f"seed-installer-shortcut: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
