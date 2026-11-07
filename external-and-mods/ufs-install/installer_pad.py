#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Game controller input for the installer window, through SDL2 (ctypes).

Steam's own overlay cannot reach a window that is not a Steam game, so the
installer reads the controller itself. Pad.poll() is called from a GLib timeout
(about every 16 ms) and reports events by name:

  up down left right   d-pad or left stick, repeating while held
  l r                  shoulder buttons, repeating while held
  a_down a_up          south button pressed and released
  b                    east button pressed

PadLogic holds the edge and repeat rules with no SDL in it, so it can be tested
alone. If SDL cannot be loaded, Pad does nothing (available is False).
"""
from __future__ import annotations

import ctypes
import os
import time
from typing import Callable, Optional

DEADZONE = 16000
REPEAT_FIRST = 0.350
REPEAT_NEXT = 0.120

_SDL_INIT_GAMECONTROLLER = 0x00002000
_BTN = {"a": 0, "b": 1, "l": 9, "r": 10, "up": 11, "down": 12, "left": 13, "right": 14}
_AXIS_LX, _AXIS_LY = 0, 1


class PadLogic:
    """Turns held-button state into events. No SDL here."""

    REPEATING = ("up", "down", "left", "right", "l", "r")

    def __init__(self) -> None:
        self._held: "dict[str, bool]" = {}
        self._next: "dict[str, float]" = {}

    @staticmethod
    def _levels(state: dict) -> "dict[str, bool]":
        lx, ly = int(state.get("lx", 0)), int(state.get("ly", 0))
        up = bool(state.get("up")) or ly < -DEADZONE
        down = bool(state.get("down")) or ly > DEADZONE
        left = bool(state.get("left")) or lx < -DEADZONE
        right = bool(state.get("right")) or lx > DEADZONE
        # Both ways at once means no way.
        if up and down:
            up = down = False
        if left and right:
            left = right = False
        return {"up": up, "down": down, "left": left, "right": right,
                "l": bool(state.get("l")), "r": bool(state.get("r")),
                "a": bool(state.get("a")), "b": bool(state.get("b"))}

    def update(self, state: dict, now: float) -> "list[str]":
        """state: up/down/left/right/a/b/l/r as booleans (d-pad and buttons),
        lx/ly as raw stick axes (-32768..32767). Returns the events for this tick."""
        lv = self._levels(state)
        events: "list[str]" = []
        for name in ("up", "down", "left", "right", "l", "r"):
            was, is_ = self._held.get(name, False), lv[name]
            if is_ and not was:
                events.append(name)
                self._next[name] = now + REPEAT_FIRST
            elif is_ and was and now >= self._next.get(name, now + 1):
                events.append(name)
                self._next[name] = now + REPEAT_NEXT
        for name, down_ev, up_ev in (("a", "a_down", "a_up"), ("b", "b", None)):
            was, is_ = self._held.get(name, False), lv[name]
            if is_ and not was:
                events.append(down_ev)
            elif was and not is_ and up_ev:
                events.append(up_ev)
        self._held = lv
        return events


class Pad:
    """Opens every attached game controller and feeds PadLogic."""

    def __init__(self, on_event: Callable[[str], None]) -> None:
        self.on_event = on_event
        self.available = False
        self.controllers: "list[str]" = []     # names, for the log and for tests
        self._logic = PadLogic()
        self._open: "list[ctypes.c_void_p]" = []
        self._count = -1
        self._sdl = None
        try:
            self._load()
        except Exception:
            self._sdl = None
            self.available = False

    def _load(self) -> None:
        # Outside a Steam launch, SDL leaves Steam's virtual gamepad (the only
        # pad the handheld's buttons reach) out of its list unless told
        # otherwise; it reads this from the environment.
        os.environ.setdefault("SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD", "1")
        # SDL would otherwise catch SIGTERM, and Steam could not close the window.
        os.environ.setdefault("SDL_NO_SIGNAL_HANDLERS", "1")
        sdl = None
        for name in ("libSDL2-2.0.so.0", "libSDL2-2.0.so", "libSDL2-2.0.0.dylib", "libSDL2.dylib"):
            try:
                sdl = ctypes.CDLL(name)
                break
            except OSError:
                continue
        if sdl is None:
            return
        vp, ci = ctypes.c_void_p, ctypes.c_int
        sdl.SDL_SetHint.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        sdl.SDL_SetHint.restype = ci
        sdl.SDL_Init.argtypes = [ctypes.c_uint32]
        sdl.SDL_Init.restype = ci
        sdl.SDL_PumpEvents.argtypes = []
        sdl.SDL_GameControllerUpdate.argtypes = []
        sdl.SDL_NumJoysticks.restype = ci
        sdl.SDL_IsGameController.argtypes = [ci]
        sdl.SDL_IsGameController.restype = ci
        sdl.SDL_GameControllerOpen.argtypes = [ci]
        sdl.SDL_GameControllerOpen.restype = vp
        sdl.SDL_GameControllerClose.argtypes = [vp]
        sdl.SDL_GameControllerGetAttached.argtypes = [vp]
        sdl.SDL_GameControllerGetAttached.restype = ci
        sdl.SDL_GameControllerName.argtypes = [vp]
        sdl.SDL_GameControllerName.restype = ctypes.c_char_p
        sdl.SDL_GameControllerGetButton.argtypes = [vp, ci]
        sdl.SDL_GameControllerGetButton.restype = ctypes.c_uint8
        sdl.SDL_GameControllerGetAxis.argtypes = [vp, ci]
        sdl.SDL_GameControllerGetAxis.restype = ctypes.c_int16
        sdl.SDL_SetHint(b"SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", b"1")
        if sdl.SDL_Init(_SDL_INIT_GAMECONTROLLER) != 0:
            return
        self._sdl = sdl
        self.available = True
        self._rescan()

    def _rescan(self) -> None:
        sdl = self._sdl
        for c in self._open:
            sdl.SDL_GameControllerClose(c)
        self._open, self.controllers = [], []
        n = sdl.SDL_NumJoysticks()
        self._count = n
        for i in range(max(0, n)):
            if sdl.SDL_IsGameController(i):
                c = sdl.SDL_GameControllerOpen(i)
                if c:
                    self._open.append(c)
                    nm = sdl.SDL_GameControllerName(c)
                    self.controllers.append(nm.decode(errors="replace") if nm else "controller")

    def poll(self) -> None:
        if not self.available:
            return
        try:
            sdl = self._sdl
            sdl.SDL_PumpEvents()
            sdl.SDL_GameControllerUpdate()
            if sdl.SDL_NumJoysticks() != self._count or any(
                    not sdl.SDL_GameControllerGetAttached(c) for c in self._open):
                self._rescan()
            state: dict = {k: False for k in _BTN}
            lx = ly = 0
            for c in self._open:
                for k, b in _BTN.items():
                    if sdl.SDL_GameControllerGetButton(c, b):
                        state[k] = True
                x, y = sdl.SDL_GameControllerGetAxis(c, _AXIS_LX), sdl.SDL_GameControllerGetAxis(c, _AXIS_LY)
                if abs(x) > abs(lx):
                    lx = x
                if abs(y) > abs(ly):
                    ly = y
            state["lx"], state["ly"] = lx, ly
            for ev in self._logic.update(state, time.monotonic()):
                self.on_event(ev)
        except Exception:
            self.available = False
