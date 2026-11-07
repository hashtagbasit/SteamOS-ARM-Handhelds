#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Zaviya Installer: full-screen GTK4 window that installs Zaviya from a
removable drive to internal storage.

The window only asks, confirms and shows progress. Everything that touches the
device lives in installer_backend.py; the game controller is installer_pad.py.

Hidden options (for building and testing without a device):
  --snapshot STEP OUT.png   render one step with fake data into a PNG and quit
                            (STEP: checks size reinstall bring confirm progress
                            done failed unsupported)
  --snapshot-size WxH       window size for --snapshot (default 1920x1080)
Environment:
  ZAVIYA_INSTALLER_FAKE=1   fake backend (see installer_backend.py)
  ZAVIYA_INSTALLER_SCRIPT   comma separated events fed to the pad dispatcher at
                            300 ms intervals: up down left right l r a_down
                            a_up b tap hold wait:SECONDS
"""
from __future__ import annotations

import ctypes
import os
import string
import sys
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

APP_ID = "org.zaviya.installer"
GOLD = "#C9A24D"
HOLD_SECONDS = 2.0
PAGE_GUARD = 0.2          # seconds after a page change in which A is ignored


# ------------------------------------------------------------ own options ----
def _split_args(argv):
    """Takes the hidden options out of argv before Gtk sees them."""
    rest, snap, size = [argv[0]], None, (1920, 1080)
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--snapshot" and i + 2 < len(argv):
            snap = (argv[i + 1], argv[i + 2])
            i += 3
        elif a == "--snapshot-size" and i + 1 < len(argv):
            try:
                w, h = argv[i + 1].lower().split("x")
                size = (int(w), int(h))
            except ValueError:
                pass
            i += 2
        else:
            rest.append(a)
            i += 1
    return rest, snap, size


ARGV, SNAPSHOT, SNAPSHOT_SIZE = _split_args(sys.argv)
if SNAPSHOT:
    os.environ["ZAVIYA_INSTALLER_FAKE"] = "1"      # a snapshot never touches a device


# ------------------------------------------------------------------ fonts ----
def load_fonts() -> None:
    """Makes Jost visible to Pango. Must run before any widget exists."""
    try:
        fc = ctypes.CDLL("libfontconfig.so.1")
        fc.FcConfigGetCurrent.restype = ctypes.c_void_p
        fc.FcConfigAppFontAddFile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        fc.FcConfigAppFontAddFile.restype = ctypes.c_int
        cfg = fc.FcConfigGetCurrent()
        for name in ("jost_light.ttf", "jost_regular.ttf"):
            path = os.path.join(HERE, "fonts", name)
            if os.path.exists(path):
                fc.FcConfigAppFontAddFile(cfg, path.encode())
    except (OSError, AttributeError):
        pass


load_fonts()

import gi  # noqa: E402

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Graphene", "1.0")
gi.require_version("Gsk", "4.0")
from gi.repository import Gdk, Gio, GLib, Graphene, Gsk, Gtk, Pango  # noqa: E402

import installer_backend as backend  # noqa: E402
from installer_pad import Pad  # noqa: E402


# ----------------------------------------------------------------- helpers ----
def detect_tablet() -> bool:
    if os.environ.get("ZAVIYA_INSTALLER_FAKE_TABLET") == "1":
        return True
    try:
        with open("/sys/firmware/devicetree/base/compatible", "rb") as fh:
            compat = fh.read()
    except OSError:
        return False
    return b"lenovo,tb321fu" in compat or b"lenovo,elden" in compat


def safe(fn):
    """A Python error in a handler shows the message page instead of freezing."""
    def wrapper(self, *a, **k):
        try:
            return fn(self, *a, **k)
        except Exception as e:      # noqa: BLE001
            traceback.print_exc()
            self.fatal(e)
            return False
    return wrapper


class Clamp(Gtk.Widget):
    """Holds one child at no more than max_width, centred."""
    __gtype_name__ = "ZaviyaClamp"

    def __init__(self, child, max_width=1200):
        super().__init__()
        self._child = child
        self.max_width = max_width
        child.set_parent(self)

    def set_max_width(self, w):
        self.max_width = w
        self.queue_resize()

    def do_measure(self, orientation, for_size):
        c = self._child
        if orientation == Gtk.Orientation.HORIZONTAL:
            mn = c.measure(orientation, -1)[0]
            w = max(mn, self.max_width)      # always asks for the full column, so wrapped text measures right
            return w, w, -1, -1
        mnw = c.measure(Gtk.Orientation.HORIZONTAL, -1)[0]
        for_size = max(mnw, self.max_width) if for_size < 0 else min(for_size, max(mnw, self.max_width))
        mn, nat, _, _ = c.measure(orientation, for_size)
        return mn, nat, -1, -1

    def do_size_allocate(self, width, height, baseline):
        mnw = self._child.measure(Gtk.Orientation.HORIZONTAL, -1)[0]
        w = min(width, max(mnw, self.max_width))
        r = Gdk.Rectangle()
        r.x, r.y, r.width, r.height = (width - w) // 2, 0, w, height
        self._child.size_allocate(r, baseline)

    def do_dispose(self):
        if self._child is not None:
            self._child.unparent()
            self._child = None


class Sized(Gtk.Widget):
    """Gives its child exactly w x h (a Gtk.Picture would ask for its own size)."""
    __gtype_name__ = "ZaviyaSized"

    def __init__(self, child, w, h, crop=(0.0, 0.0)):
        super().__init__()
        self._child, self.w, self.h, self.crop = child, w, h, crop
        child.set_parent(self)

    def set_size(self, w, h):
        self.w, self.h = w, h
        self.queue_resize()

    def do_measure(self, orientation, for_size):
        if orientation == Gtk.Orientation.HORIZONTAL:
            v = round(self.w * (1 - 2 * self.crop[0]))
        else:
            v = round(self.h * (1 - 2 * self.crop[1]))
        return v, v, -1, -1

    def do_size_allocate(self, width, height, baseline):
        # the child keeps its full size; crop trims its empty margins from the layout
        off = Graphene.Point().init(-self.w * self.crop[0], -self.h * self.crop[1])
        self._child.allocate(self.w, self.h, baseline, Gsk.Transform().translate(off))

    def do_dispose(self):
        if self._child is not None:
            self._child.unparent()
            self._child = None


class HoldButton(Gtk.Widget):
    """A button that fires after being held HOLD_SECONDS, with a gold fill that
    grows across it. Pointer, touch, keyboard and pad all end up in begin()/end()."""
    __gtype_name__ = "ZaviyaHoldButton"

    def __init__(self, text, on_complete):
        super().__init__()
        self._text = text
        self._complete = on_complete
        self.frac = 0.0
        self._src = None
        self._t0 = 0.0
        self._tick_id = 0
        self.fired = False
        self.set_focusable(True)
        self.set_halign(Gtk.Align.END)
        g = Gtk.GestureClick()
        g.set_button(0)
        g.connect("pressed", self._pressed)
        g.connect("released", lambda *_: self.end("pointer"))
        g.connect("cancel", lambda *_: self.end("pointer"))
        g.connect("stopped", lambda *_: self.end("pointer"))
        self.add_controller(g)

    def _pressed(self, gesture, n, x, y):
        self.grab_focus()
        self.begin("pointer")

    def set_text(self, text):
        self._text = text
        self.queue_resize()
        self.queue_draw()

    def reset(self):
        self.fired = False
        self._stop()
        self.frac = 0.0
        self.remove_css_class("busy")
        self.queue_draw()

    def begin(self, source):
        if self.fired or self._src is not None:
            return
        self._src = source
        self._t0 = time.monotonic()
        self._tick_id = self.add_tick_callback(self._tick)

    def end(self, source):
        if self._src != source or self.fired:
            return
        self._stop()
        self.frac = 0.0
        self.queue_draw()

    def _stop(self):
        self._src = None
        if self._tick_id:
            self.remove_tick_callback(self._tick_id)
            self._tick_id = 0

    def _tick(self, widget, clock):
        if self._src is None:
            self._tick_id = 0
            return False
        self.frac = min(1.0, (time.monotonic() - self._t0) / HOLD_SECONDS)
        self.queue_draw()
        if self.frac >= 1.0 and not self.fired:
            self.fired = True          # only once, until reset()
            self._src = None
            self._tick_id = 0
            self.add_css_class("busy")
            GLib.idle_add(self._fire)
            return False
        return True

    def _fire(self):
        self._complete()
        return False

    def do_measure(self, orientation, for_size):
        w, h = self.create_pango_layout(self._text).get_pixel_size()
        v = w if orientation == Gtk.Orientation.HORIZONTAL else h
        return v, v, -1, -1

    def do_snapshot(self, snapshot):
        w, h = self.get_width(), self.get_height()
        layout = self.create_pango_layout(self._text)
        tw, th = layout.get_pixel_size()
        white, black, gold = Gdk.RGBA(), Gdk.RGBA(), Gdk.RGBA()
        white.parse("#ffffff")
        black.parse("#000000")
        gold.parse(GOLD)
        fw = w * self.frac
        if fw > 0:
            snapshot.append_color(gold, Graphene.Rect().init(0, 0, fw, h))
        # white text on the empty part, black on the gold fill
        for (x0, x1, colour) in ((fw, w, white), (0, fw, black)):
            if x1 - x0 <= 0:
                continue
            snapshot.push_clip(Graphene.Rect().init(x0, 0, x1 - x0, h))
            snapshot.save()
            snapshot.translate(Graphene.Point().init((w - tw) / 2, (h - th) / 2))
            snapshot.append_layout(layout, colour)
            snapshot.restore()
            snapshot.pop()


HoldButton.set_css_name("holdbutton")


# --------------------------------------------------------------------- CSS ----
CSS = string.Template("""
window, .root { background: #000000; color: #ffffff; }
window.repaint { background: #000001; }
* { font-family: "Jost", sans-serif; font-weight: 400; }
label, button, holdbutton { color: #ffffff; }
label:disabled { opacity: 1; }
.h1 { font-size: ${h1}px; font-weight: 300; }
.lead { font-size: ${lead}px; color: rgba(255,255,255,0.80); }
.lead-strong { font-size: ${lead}px; color: #ffffff; }
.cap { font-size: ${cap}px; color: rgba(255,255,255,0.62); letter-spacing: 2px; }
.hint { font-size: ${hint}px; color: rgba(255,255,255,0.70); }
.step { font-size: ${hint}px; color: rgba(255,255,255,0.70); letter-spacing: 1px; }
.gold { color: ${gold}; }
.big { font-size: ${big}px; font-weight: 300; }
.pct { font-size: ${pct}px; font-weight: 300; color: ${gold}; }
.warn { font-size: ${cap}px; color: ${gold}; }
.mt1 { margin-top: ${g1}px; }
.mt2 { margin-top: ${g2}px; }
.mt3 { margin-top: ${g3}px; }
.mt4 { margin-top: ${g4}px; }
separator { background: rgba(255,255,255,0.22); min-height: 1px; min-width: 1px; border: none; }
.rowkey { font-size: ${cap}px; color: rgba(255,255,255,0.62); letter-spacing: 1px; }
.rowval { font-size: ${lead}px; }

button.act {
  all: unset;
  font-family: "Jost", sans-serif; font-size: ${btn}px; font-weight: 400; color: #ffffff;
  padding: ${bpy}px ${bpx}px;
  border: 2px solid rgba(255,255,255,0.42);
  background: transparent;
}
button.act:hover { border-color: rgba(255,255,255,0.80); }
button.act:focus, button.act:focus-visible {
  border-color: ${gold}; background: rgba(201,162,77,0.20);
  outline: ${ring}px solid ${gold}; outline-offset: ${ringoff}px;
}
button.primary { background: ${gold}; border-color: ${gold}; color: #000000; }
button.primary:hover { background: #d8b45f; border-color: #d8b45f; }
button.primary:focus, button.primary:focus-visible { background: #e3bf6a; border-color: #ffffff; }
button.act:disabled { opacity: 0.30; }

holdbutton {
  font-family: "Jost", sans-serif; font-size: ${btn}px; font-weight: 400;
  padding: ${hpy}px ${hpx}px; border: 2px solid ${gold}; background: rgba(201,162,77,0.12);
}
holdbutton:hover { background: rgba(201,162,77,0.22); }
holdbutton:focus, holdbutton:focus-visible {
  background: rgba(201,162,77,0.26); outline: ${ring}px solid ${gold}; outline-offset: ${ringoff}px;
}
holdbutton.busy { opacity: 0.6; }

button.opt {
  all: unset; padding: ${opy}px ${opx}px;
  border-top: 1px solid rgba(255,255,255,0.22);
}
button.opt:hover { background: rgba(255,255,255,0.05); }
button.opt:focus, button.opt:focus-visible {
  background: rgba(201,162,77,0.16);
  outline: ${ring}px solid ${gold}; outline-offset: -${ring}px;
}
.dot { min-width: ${dot}px; min-height: ${dot}px; border-radius: 999px;
       border: 3px solid rgba(255,255,255,0.55); }
button.opt:checked .dot { background: ${gold}; border-color: ${gold}; box-shadow: inset 0 0 0 5px #000000; }
.opt-title { font-size: ${lead}px; font-weight: 400; color: #ffffff; }
.opt-desc { font-size: ${cap}px; color: rgba(255,255,255,0.70); }

scale, scale:focus, scale:focus-visible, scale trough, scale trough:focus { outline: none; }
scale trough { min-height: ${trough}px; background: #2b2b2b; border: none; border-radius: 0; }
scale highlight { background: ${gold}; border: none; border-radius: 0; min-height: ${trough}px; }
scale slider {
  min-width: ${knob}px; min-height: ${knob}px; margin: -${knobm}px; padding: 0;
  background: ${gold}; border: 3px solid #000000; border-radius: 999px; box-shadow: none;
}
scale:focus slider, scale:focus-visible slider { box-shadow: 0 0 0 ${ring}px #000000, 0 0 0 ${ring2}px ${gold}; }
progressbar trough { min-height: ${bar2}px; background: #262626; border: none; border-radius: 0; }
progressbar progress { min-height: ${bar2}px; background: ${gold}; border: none; border-radius: 0; }
spinner { color: ${gold}; }
.logbox { font-family: monospace; font-size: ${mono}px; color: rgba(255,255,255,0.88);
          background: rgba(255,255,255,0.07); border-left: 3px solid ${gold};
          padding: ${lpy}px ${lpx}px; }
""")


def metrics(h):
    s = max(0.55, min(1.6, h / 1080.0))

    def f(v, lo=1):
        return max(lo, round(v * s))
    return dict(
        s=s, gold=GOLD,
        h1=f(76, 36), lead=f(34, 20), cap=f(26, 16), btn=f(34, 20), hint=f(26, 16),
        big=f(120, 56), pct=f(96, 44), mono=f(22, 14),
        g1=f(14), g2=f(30), g3=f(42), g4=f(84),
        bpy=f(18), bpx=f(48), hpy=f(22), hpx=f(56), ring=max(3, f(5)), ringoff=f(6), ring2=max(6, f(10)),
        opy=f(18), opx=f(26), bar=f(8), dot=f(34, 22),
        trough=f(10, 6), knob=f(48, 30), knobm=f(19, 12), bar2=f(22, 12),
        lpy=f(18), lpx=f(24))


# -------------------------------------------------------------------- pages ----
class Page:
    def __init__(self, name, widget, focus=None, step=0, back=None, hint="sel_back",
                 small_logo=True, enter=None):
        self.name, self.widget, self.focus, self.step = name, widget, focus, step
        self.back, self.hint, self.small_logo, self.enter = back, hint, small_logo, enter
        self.clamp = None


def hbox(*children, spacing=0):
    b = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing)
    for c in children:
        b.append(c)
    return b


def vbox(*children, spacing=0):
    b = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=spacing)
    for c in children:
        b.append(c)
    return b


def clear(box):
    child = box.get_first_child()
    while child is not None:
        nxt = child.get_next_sibling()
        box.remove(child)
        child = nxt


def label(text, *classes, wrap=True, xalign=0.0, markup=False):
    lb = Gtk.Label()
    if markup:
        lb.set_markup(text)
    else:
        lb.set_text(text)
    for c in classes:
        lb.add_css_class(c)
    lb.set_wrap(wrap)
    lb.set_xalign(xalign)
    lb.set_halign(Gtk.Align.FILL)
    if xalign == 0.5:
        lb.set_justify(Gtk.Justification.CENTER)
    return lb


def rule():
    return Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)


def act_button(text, primary=False, on_click=None):
    b = Gtk.Button(label=text)
    b.add_css_class("act")
    if primary:
        b.add_css_class("primary")
    if on_click:
        b.connect("clicked", lambda *_: on_click())
    return b


def action_row(left=None, right=None):
    row = hbox()
    row.add_css_class("mt3")
    if left is not None:
        left.set_halign(Gtk.Align.START)
        row.append(left)
    spacer = Gtk.Box()
    spacer.set_hexpand(True)
    row.append(spacer)
    if right is not None:
        right.set_halign(Gtk.Align.END)
        row.append(right)
    return row


def make_page_body(content_children, actions=None):
    """Content centred in the free space, the action row pinned below it."""
    content = vbox(*content_children)
    content.set_vexpand(True)
    content.set_valign(Gtk.Align.CENTER)
    page = vbox(content)
    if actions is not None:
        page.append(actions)
    page.set_vexpand(True)
    return page


# --------------------------------------------------------------------- app ----
class InstallerApp:
    MODES = (
        ("all", "Everything", "All settings, saves and accounts, with installed games."),
        ("essentials", "Essentials", "Steam login, settings, saves and plugins. Games are downloaded again."),
        ("none", "Clean start", "Steam client and plugins only. No account or personal data."),
    )

    def __init__(self, app):
        self.app = app
        self.snapshot = SNAPSHOT
        self.script_mode = bool(os.environ.get("ZAVIYA_INSTALLER_SCRIPT"))
        self.inst = backend.Installer()
        self.tablet = detect_tablet()
        self.probe = None
        self.android_gib = 0
        self.home_mode = "all"
        self.reinstall = None            # None: unknown (window opened onto a finished unit)
        self.cur = ""
        self.pages = {}
        self._guard_until = 0.0
        self._keys_down = set()
        self._dim = (0, 0)
        self._sizers = []
        self._poll_id = 0
        self._polling = False
        self._idle_polls = 0
        self._close_armed = False
        self._finished = False
        self._starting = False

        self.provider = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), self.provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)
        Gtk.Settings.get_default().set_property("gtk-application-prefer-dark-theme", True)

        self.win = Gtk.ApplicationWindow(application=app)
        self.win.set_title("Zaviya Installer")
        self.build_chrome()
        self.build_pages()
        if SNAPSHOT:
            self.apply_metrics(SNAPSHOT_SIZE[0], SNAPSHOT_SIZE[1])
        else:
            self.apply_metrics(1920, 1080)

        self.pad = None
        if not self.snapshot and not self.script_mode:
            self.pad = Pad(self.dispatch)
            if self.pad.available:
                GLib.timeout_add(16, self.poll_pad)
        # snapshots show the pad hint so the bottom row can be judged
        self.hint.set_visible(bool(self.snapshot or (self.pad and self.pad.available)))

        keys = Gtk.EventControllerKey()
        keys.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self.on_key_pressed)
        keys.connect("key-released", self.on_key_released)
        self.win.add_controller(keys)
        self.win.connect("close-request", self.on_close)
        self.win.add_tick_callback(self.on_frame)

        if self.snapshot:
            self.win.set_default_size(*SNAPSHOT_SIZE)
        else:
            self.win.fullscreen()
        self.win.present()
        self.win.set_focus_visible(True)

        if self.snapshot:
            self.start_snapshot()
        else:
            self.begin_startup()
            if self.script_mode:
                self.start_script(os.environ["ZAVIYA_INSTALLER_SCRIPT"])

    # ------------------------------------------------------------- wording ----
    @property
    def media(self):
        return "USB drive" if self.tablet else "SD card"

    # -------------------------------------------------------------- chrome ----
    def build_chrome(self):
        self.logo = Gtk.Picture.new_for_filename(os.path.join(HERE, "zaviya-logo-white.svg"))
        self.logo.set_can_shrink(True)
        self.logo.set_content_fit(Gtk.ContentFit.CONTAIN)
        self.logo_box = Sized(self.logo, 100, 100, crop=(0.25, 0.12))
        self.logo_box.set_halign(Gtk.Align.START)
        self.step_label = label("", "step", wrap=False, xalign=1.0)
        self.step_label.set_halign(Gtk.Align.END)
        self.step_label.set_valign(Gtk.Align.CENTER)
        spacer = Gtk.Box()
        spacer.set_hexpand(True)
        self.top = hbox(self.logo_box, spacer, self.step_label)

        self.stack = Gtk.Stack()
        # No crossfade: on the device's GL renderer it leaves the top row of the old page's tallest
        # glyph on screen (a white dot above the heading) in the strip the pages do not share.
        self.stack.set_transition_type(Gtk.StackTransitionType.NONE)
        self.stack.set_vexpand(True)
        self.stack.set_hexpand(True)
        self.stack.set_hhomogeneous(False)
        self.stack.set_vhomogeneous(False)

        self.hint = label("", "hint", wrap=False, markup=True)
        self.hint.set_hexpand(True)
        self.bottom = hbox(self.hint)
        self.bottom.set_margin_top(16)

        root = vbox(self.top, self.stack, self.bottom)
        root.add_css_class("root")
        self.win.set_child(root)

        def size(S):
            # the artwork has empty margins (mark and word occupy the middle half of the width)
            h = round(120 * S)
            w = round(h * 800 / 573)
            self.logo_box.set_size(w, h)
            root.set_margin_start(round(76 * S))
            root.set_margin_end(round(76 * S))
            root.set_margin_top(round(40 * S))
            root.set_margin_bottom(round(36 * S))
        self._sizers.append(size)

    def add_page(self, page, clamp_width=1240):
        clamp = Clamp(page.widget, clamp_width)
        clamp.set_vexpand(True)
        clamp.set_hexpand(True)
        self.stack.add_named(clamp, page.name)
        page.clamp = clamp
        self.pages[page.name] = page

        def size(S, c=clamp, w=clamp_width, body=page.widget):
            c.set_max_width(round(w * S))
            # room for the focus ring, which the stack would otherwise clip
            for side in ("start", "end", "top", "bottom"):
                getattr(body, "set_margin_" + side)(round(18 * S))
        self._sizers.append(size)

    def tagline(self, height):
        pic = Gtk.Picture.new_for_filename(os.path.join(HERE, "zaviya-logo-tagline-white.svg"))
        pic.set_can_shrink(True)
        pic.set_content_fit(Gtk.ContentFit.CONTAIN)

        box = Sized(pic, 100, 100)

        def size(S, b=box, h=height):
            b.set_size(round(h * S * 800 / 642), round(h * S))
        self._sizers.append(size)
        return box

    # --------------------------------------------------------------- pages ----
    def build_pages(self):
        self.build_checks()
        self.build_message()
        self.build_size()
        self.build_reinstall()
        self.build_bring()
        self.build_confirm()
        self.build_progress()
        self.build_done()
        self.build_failed()

    def build_checks(self):
        spinner = Gtk.Spinner()
        spinner.set_spinning(True)
        spinner.set_halign(Gtk.Align.CENTER)
        spinner.add_css_class("mt3")

        def size(S):
            spinner.set_size_request(round(84 * S), round(84 * S))
        self._sizers.append(size)
        text = label("Checking internal storage", "h1", xalign=0.5)
        text.add_css_class("mt3")
        logo = self.tagline(300)
        logo.set_halign(Gtk.Align.CENTER)
        self.add_page(Page("checks", make_page_body([logo, spinner, text]), hint="", small_logo=False))

    def build_message(self):
        self.msg_title = label("", "h1")
        self.msg_text = label("", "lead")
        self.msg_text.add_css_class("mt2")
        self.msg_close = act_button("Close", primary=True, on_click=self.close)
        body = make_page_body([self.msg_title, self.msg_text], action_row(right=self.msg_close))
        self.add_page(Page("message", body, focus=lambda: self.msg_close, hint="sel"))

    def show_message(self, title, text):
        self.msg_title.set_text(title)
        self.msg_text.set_text(text)
        self.finish_polling()
        self.show("message")

    def build_size(self):
        title = label("Android storage", "h1")
        lead = label("Android keeps its system, and its apps and data are erased. The size chosen here is the "
                     "space Android keeps. The rest of internal storage goes to Zaviya.", "lead")
        lead.add_css_class("mt2")
        self.adj = Gtk.Adjustment(value=64, lower=16, upper=200, step_increment=1, page_increment=4)
        self.scale = Gtk.Scale(orientation=Gtk.Orientation.HORIZONTAL, adjustment=self.adj)
        self.scale.set_draw_value(False)
        self.scale.set_hexpand(True)
        self.scale.set_round_digits(0)
        self.scale.add_css_class("mt2")
        self.adj.connect("value-changed", self.on_size_changed)
        sk = Gtk.EventControllerKey()
        sk.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)
        sk.connect("key-pressed", self.on_scale_key)
        self.scale.add_controller(sk)

        self.android_val = label("64 GB", "big", wrap=False)
        self.zaviya_val = label("120 GB", "big", wrap=False)
        c1 = vbox(label("ANDROID", "cap", wrap=False), self.android_val, label("space kept for Android", "cap"))
        c2 = vbox(label("ZAVIYA", "cap", wrap=False), self.zaviya_val, label("space for games and settings", "cap"))
        c1.set_hexpand(True)
        c2.set_hexpand(True)
        readout = hbox(c1, c2)
        readout.add_css_class("mt3")
        self.min_label = label("16 GB", "cap", wrap=False)
        self.max_label = label("200 GB", "cap", wrap=False, xalign=1.0)
        self.max_label.set_hexpand(True)
        ends = hbox(self.min_label, self.max_label)
        ends.add_css_class("mt1")
        self.size_next = act_button("Continue", primary=True, on_click=lambda: self.show("bring"))
        body = make_page_body([title, lead, readout, self.scale, ends], action_row(right=self.size_next))
        self.add_page(Page("size", body, focus=lambda: self.scale, step=1, hint="sel"))

    def on_size_changed(self, adj):
        v = int(round(adj.get_value()))
        self.android_gib = v
        self.android_val.set_text(f"{v} GB")
        if self.probe:
            self.zaviya_val.set_text(f"{backend.zaviya_home_gib(self.probe, v)} GB")

    def fill_size(self):
        p = self.probe
        lo, hi = int(p.min_gib), int(max(p.max_gib, p.min_gib + 1))
        self.adj.configure(min(max(p.recommended_gib, lo), hi), lo, hi, 1, 4, 0)
        self.min_label.set_text(f"{lo} GB")
        self.max_label.set_text(f"{hi} GB")
        self.on_size_changed(self.adj)

    def build_reinstall(self):
        title = label("Zaviya is already installed", "h1")
        self.re_lead = label("", "lead")
        self.re_lead.add_css_class("mt2")
        lead2 = label("Android and its data are not changed. To keep games and saves, use Zaviya Update "
                      "instead.", "lead")
        lead2.add_css_class("mt2")
        self.re_next = act_button("Continue", primary=True, on_click=lambda: self.show("bring"))
        body = make_page_body([title, self.re_lead, lead2], action_row(right=self.re_next))
        self.add_page(Page("reinstall", body, focus=lambda: self.re_next, step=1, hint="sel"))

    def fill_reinstall(self):
        self.re_lead.set_text(
            "Zaviya is already on internal storage. Continuing replaces its system: the boot, system and "
            "home partitions are formatted again, so games, saves and accounts stored on internal "
            f"storage are erased. The data chosen next is then copied from the {self.media}.")

    def build_bring(self):
        title = label("What to copy", "h1")
        self.bring_lead = label("", "lead")
        self.bring_lead.add_css_class("mt2")
        first = None
        self.mode_buttons = {}
        listing = vbox()
        listing.add_css_class("mt3")
        for key, name, desc in self.MODES:
            tb = Gtk.ToggleButton()
            tb.add_css_class("opt")
            dot = Gtk.Box()
            dot.add_css_class("dot")
            dot.set_valign(Gtk.Align.CENTER)
            texts = vbox(label(name, "opt-title", wrap=False), label(desc, "opt-desc"))
            texts.set_hexpand(True)
            tb.set_child(hbox(dot, texts, spacing=28))
            if first is None:
                first = tb
            else:
                tb.set_group(first)
            tb.connect("toggled", self.on_mode_toggled, key)
            self.mode_buttons[key] = tb
            listing.append(tb)
        first.set_active(True)
        listing.append(rule())
        back = act_button("Back", on_click=self.go_back)
        nxt = act_button("Continue", primary=True, on_click=lambda: self.show("confirm"))
        body = make_page_body([title, self.bring_lead, listing], action_row(back, nxt))
        self.add_page(Page("bring", body, focus=lambda: self.mode_buttons[self.home_mode], step=2,
                           back=lambda: self.first_page()))

    def on_mode_toggled(self, btn, key):
        if btn.get_active():
            self.home_mode = key

    def first_page(self):
        return "reinstall" if (self.probe and self.probe.existing_install) else "size"

    def build_confirm(self):
        title = label("Ready to install", "h1")
        self.conf_grid = Gtk.Grid()
        self.conf_grid.set_column_spacing(48)
        self.conf_grid.add_css_class("mt3")
        hold_hint = label("Press and hold the button for two seconds. Release early to cancel.", "cap")
        hold_hint.add_css_class("mt2")
        self.conf_error = label("", "warn")
        self.conf_error.add_css_class("mt1")
        self.conf_back = act_button("Back", on_click=self.go_back)
        self.hold = HoldButton("Erase Android data and install", self.on_hold_complete)
        body = make_page_body([title, self.conf_grid, hold_hint, self.conf_error],
                              action_row(self.conf_back, self.hold))
        self.add_page(Page("confirm", body, focus=lambda: self.hold, step=3, back=lambda: "bring",
                           hint="hold_back", enter=self.enter_confirm))

    def mode_title(self):
        return next(t for k, t, _ in self.MODES if k == self.home_mode)

    def enter_confirm(self):
        p = self.probe
        if p.existing_install:
            rows = [("Internal storage", "Boot, system and home are formatted again."),
                    ("Erased", "Games, saves and accounts stored on internal storage."),
                    ("Android", "Not changed.")]
            self.hold_text = "Replace the internal system and install"
        else:
            gib = self.android_gib
            rows = [("Android", f"{gib} GB kept. Its apps and data are erased."),
                    ("Zaviya", f"{backend.zaviya_home_gib(p, gib)} GB for games and settings, "
                               f"plus {p.boot_gib + p.root_gib} GB of system partitions.")]
            self.hold_text = "Erase Android data and install"
        rows += [("Copied", self.mode_title()), (self.media, "Not changed.")]
        clear(self.conf_grid)
        for i, (k, v) in enumerate(rows):
            kl = label(k.upper(), "rowkey", wrap=False)
            kl.set_valign(Gtk.Align.START)
            kl.set_margin_top(12)
            vl = label(v, "rowval")
            vl.set_hexpand(True)
            vl.set_margin_top(6)
            vl.set_margin_bottom(6)
            self.conf_grid.attach(rule(), 0, i * 2, 2, 1)
            self.conf_grid.attach(kl, 0, i * 2 + 1, 1, 1)
            self.conf_grid.attach(vl, 1, i * 2 + 1, 1, 1)
        self.conf_grid.attach(rule(), 0, len(rows) * 2, 2, 1)
        self.conf_error.set_text("")
        self.conf_back.set_sensitive(True)
        self.hold.set_text(self.hold_text)
        self.hold.reset()
        self._starting = False

    def build_progress(self):
        self.prog_stage = label("Starting", "h1")
        self.prog_bar = Gtk.ProgressBar()
        self.prog_bar.add_css_class("mt3")
        self.prog_pct = label(" ", "pct", wrap=False)
        self.prog_count = label("", "lead", wrap=False, xalign=1.0)
        self.prog_count.set_hexpand(True)
        self.prog_count.set_valign(Gtk.Align.END)
        row = hbox(self.prog_pct, self.prog_count)
        row.add_css_class("mt2")
        self.prog_note = label("", "lead")
        self.prog_note.add_css_class("mt2")
        self.prog_close_note = label(" ", "warn")
        self.prog_close_note.add_css_class("mt2")
        body = make_page_body([self.prog_stage, self.prog_bar, row, self.prog_note, self.prog_close_note])
        self.add_page(Page("progress", body, focus=None, hint=""))

    def full_repaint(self):
        # The renderer redraws only what it thinks changed, and heading glyphs
        # reach a pixel past the bounds it tracks, so a row of the old heading
        # stayed on screen. An invisible background change repaints all of it.
        # Deferred and only once: two toggles in one frame would cancel out.
        if getattr(self, "_repaint_queued", False):
            return
        self._repaint_queued = True

        def toggle():
            self._repaint_queued = False
            if self.win.has_css_class("repaint"):
                self.win.remove_css_class("repaint")
            else:
                self.win.add_css_class("repaint")
            return False
        GLib.idle_add(toggle)

    def update_progress(self, prog):
        if self.prog_stage.get_text() != prog.stage_label:
            self.prog_stage.set_text(prog.stage_label)
            self.full_repaint()
        self.prog_bar.set_fraction(prog.fraction)
        if prog.stage_key in ("system", "home"):
            self.prog_pct.set_text(f"{prog.percent or 0}%")
        else:
            self.prog_pct.set_text(" ")
        self.prog_count.set_text(f"Stage {prog.stage_index + 1} of {prog.stage_count}")
        self.prog_note.set_text(
            f"This can take a long while. Keep the device powered and leave the {self.media} in until "
            "the install finishes. Closing this window does not stop the install.")

    def build_done(self):
        logo = self.tagline(300)
        logo.set_valign(Gtk.Align.CENTER)
        logo.set_margin_end(64)
        title = label("Zaviya is on internal storage", "h1")
        self.done_steps = vbox()
        self.done_steps.add_css_class("mt3")
        self.done_close = act_button("Close", primary=True, on_click=self.close)
        text = vbox(title, self.done_steps)
        text.set_hexpand(True)
        text.set_valign(Gtk.Align.CENTER)
        body = make_page_body([hbox(logo, text)], action_row(right=self.done_close))
        self.add_page(Page("done", body, focus=lambda: self.done_close, hint="sel", small_logo=False),
                      clamp_width=1560)

    def done_lines(self):
        if self.tablet:
            return ["Power off and unplug the USB drive, then power on. The device starts Zaviya from "
                    "internal storage.",
                    "To return to Android later, flash the saved boot image from a PC with fastboot. "
                    "It is stored in /home/.ufs-backup."]
        lines = ["Power off and take out the SD card.",
                 "In the ABL menu (hold Volume Down at power-on), set Boot source to Internal, then boot "
                 "Linux. With Boot source left on SD, the menu stops at “no volumes match boot source”."]
        if self.reinstall is False:
            lines.append("Android is chosen in the same menu. It sets itself up again, as its user data "
                         "was erased.")
        else:
            lines.append("Android stays available in the same menu.")
        return lines

    def show_done(self):
        clear(self.done_steps)
        self.done_steps.append(rule())
        for i, line in enumerate(self.done_lines(), 1):
            num = label(str(i), "lead-strong", wrap=False)
            num.add_css_class("gold")
            num.set_valign(Gtk.Align.START)
            num.set_width_chars(2)
            num.set_margin_end(16)
            txt = label(line, "lead")
            txt.set_hexpand(True)
            r = hbox(num, txt)
            r.set_margin_top(10)
            r.set_margin_bottom(10)
            self.done_steps.append(r)
            self.done_steps.append(rule())
        self.finish_polling()
        self.show("done")

    def build_failed(self):
        title = label("The install did not finish", "h1")
        self.fail_text = label("", "lead")
        self.fail_text.add_css_class("mt2")
        self.fail_log = label("", "logbox", wrap=False)
        self.fail_log.set_ellipsize(Pango.EllipsizeMode.END)
        self.fail_log.add_css_class("mt2")
        self.fail_path = label("", "cap")
        self.fail_path.add_css_class("mt1")
        close = act_button("Close", on_click=self.close)
        self.fail_again = act_button("Start over", primary=True, on_click=self.begin_checks)
        body = make_page_body([title, self.fail_text, self.fail_log, self.fail_path],
                              action_row(right=hbox(close, self.fail_again, spacing=24)))
        self.add_page(Page("failed", body, focus=lambda: self.fail_again, hint="sel"))

    def show_failed(self, error, text):
        lines = backend.last_log_lines(text, 8)
        self.fail_text.set_text(error or "The install stopped before it finished.")
        self.fail_log.set_text("\n".join(lines) or "(the log is empty)")
        self.fail_path.set_text(f"Full log: {backend.INSTALL_LOG}")
        self.finish_polling()
        self.show("failed")

    # --------------------------------------------------------- page switch ----
    def show(self, name):
        page = self.pages[name]
        self.cur = name
        for p in self.pages.values():
            p.clamp.set_sensitive(p is page)
        if page.enter:
            page.enter()
        if name == "size":
            self.fill_size()
        elif name == "reinstall":
            self.fill_reinstall()
        elif name == "bring":
            self.bring_lead.set_text(
                f"Choose what is copied from the {self.media}. The {self.media} itself is not changed.")
        self.stack.set_visible_child_name(name)
        self.full_repaint()
        self.step_label.set_text(f"Step {page.step} of 3" if page.step else "")
        self.logo_box.set_visible(page.small_logo)
        self.hint.set_markup(self.hint_markup(page.hint))
        self._guard_until = time.monotonic() + PAGE_GUARD
        if self.script_mode or os.environ.get("ZAVIYA_INSTALLER_TRACE"):
            print(f"[page] {name}", flush=True)
        GLib.idle_add(self.focus_page, name)

    @safe
    def focus_page(self, name):
        if name != self.cur:
            return False
        page = self.pages[name]
        target = page.focus() if page.focus else None
        if target is not None:
            target.grab_focus()
        else:
            self.win.set_focus(None)
        self.win.set_focus_visible(True)
        return False

    def hint_markup(self, kind):
        def k(c):
            return f"<span foreground='{GOLD}' weight='bold'>{c}</span>"
        gap = "  "
        return {"sel_back": f"{k('A')} Select{gap}{k('B')} Back",
                "sel": f"{k('A')} Select",
                "hold_back": f"{k('A')} Hold to confirm{gap}{k('B')} Back"}.get(kind, "")

    def go_back(self):
        page = self.pages.get(self.cur)
        if not page or not page.back or self._starting:
            return
        self.show(page.back())

    def close(self):
        self.win.close()

    # ------------------------------------------------------------- metrics ----
    @safe
    def on_frame(self, widget, clock):
        dim = (self.win.get_width(), self.win.get_height())
        if dim != self._dim and dim[1] > 0:
            self.apply_metrics(*dim)
        return True

    def apply_metrics(self, w, h):
        self._dim = (w, h)
        m = metrics(h)
        css = CSS.substitute(m)
        if hasattr(self.provider, "load_from_string"):
            self.provider.load_from_string(css)
        else:
            self.provider.load_from_data(css.encode())
        for fn in self._sizers:
            fn(m["s"])

    # --------------------------------------------------------------- input ----
    @safe
    def poll_pad(self):
        self.pad.poll()
        return True

    @safe
    def dispatch(self, ev):
        f = self.win.get_focus()
        if ev in ("up", "down", "left", "right"):
            if isinstance(f, Gtk.Scale) and ev in ("left", "right"):
                self.adj.set_value(self.adj.get_value() + (1 if ev == "right" else -1))
                return
            d = {"up": Gtk.DirectionType.UP, "down": Gtk.DirectionType.DOWN,
                 "left": Gtk.DirectionType.LEFT, "right": Gtk.DirectionType.RIGHT}[ev]
            self.win.child_focus(d)
        elif ev in ("l", "r"):
            if self.cur == "size":
                self.adj.set_value(self.adj.get_value() + (4 if ev == "r" else -4))
        elif ev == "a_down":
            if time.monotonic() < self._guard_until or f is None:
                return
            if isinstance(f, HoldButton):
                f.begin("pad")
            elif not isinstance(f, Gtk.Scale):
                f.activate()
        elif ev == "a_up":
            self.hold.end("pad")
        elif ev == "b":
            self.go_back()

    @safe
    def on_key_pressed(self, ctrl, keyval, keycode, state):
        again = keyval in self._keys_down
        self._keys_down.add(keyval)
        if keyval == Gdk.KEY_Escape:
            if not again:
                self.go_back()
            return True
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
            # a repeat, or a press right after a page change, must not act twice
            if again or time.monotonic() < self._guard_until:
                return True
            f = self.win.get_focus()
            if isinstance(f, HoldButton):
                f.begin("key")
                return True
        return False

    @safe
    def on_key_released(self, ctrl, keyval, keycode, state):
        self._keys_down.discard(keyval)
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
            self.hold.end("key")

    @safe
    def on_scale_key(self, ctrl, keyval, keycode, state):
        if keyval in (Gdk.KEY_Up, Gdk.KEY_Down):
            self.win.child_focus(Gtk.DirectionType.UP if keyval == Gdk.KEY_Up else Gtk.DirectionType.DOWN)
            return True
        return False

    @safe
    def on_close(self, win):
        """A close gesture during the install asks twice; the unit runs on either way."""
        if self.cur == "progress" and not self._close_armed:
            self._close_armed = True
            self.prog_close_note.set_text(
                "The install keeps running in the background. Close the window once more to leave it.")
            GLib.timeout_add(6000, self._disarm_close)
            return True
        return False

    def _disarm_close(self):
        self._close_armed = False
        self.prog_close_note.set_text(" ")
        return False

    # ------------------------------------------------------------ threading ----
    def run_bg(self, fn, done):
        def work():
            try:
                res = (fn(), None)
            except Exception as e:      # noqa: BLE001
                traceback.print_exc()
                res = (None, e)
            GLib.idle_add(self._deliver, done, res)
        threading.Thread(target=work, daemon=True).start()

    @safe
    def _deliver(self, done, res):
        done(*res)
        return False

    def fatal(self, exc):
        try:
            first = (str(exc).strip().splitlines() or [""])[0]
            self.show_message("The installer stopped unexpectedly", f"{type(exc).__name__}: {first}")
        except Exception:       # noqa: BLE001
            traceback.print_exc()

    # -------------------------------------------------------------- startup ----
    def begin_startup(self):
        self.show("checks")

        def work():
            st = self.inst.status()
            if st[0] == "idle":
                return ("probe", self.inst.probe())
            return ("status", st)
        self.run_bg(work, self.on_startup)

    def on_startup(self, res, exc):
        if exc:
            return self.fatal(exc)
        kind, data = res
        if kind == "probe":
            return self.on_probe(data, None)
        state, prog, text = data
        self._finished = False
        self.show("progress")
        self.update_progress(prog)
        self.handle_status(state, prog, text)
        if state == "running":
            self.start_polling()

    def begin_checks(self):
        self.show("checks")
        self.run_bg(self.inst.probe, self.on_probe)

    def on_probe(self, p, exc):
        if exc:
            return self.fatal(exc)
        self.probe = p
        if p.tablet:
            self.tablet = True
        if p.unsupported:
            article = "a USB drive" if self.tablet else "an SD card"
            return self.show_message(
                "Installer unavailable",
                f"The installer runs from {article}, and only on devices that support it. It is not "
                "available on this device, or when Zaviya already runs from internal storage.")
        if p.error:
            return self.show_message("The storage check failed", p.error)
        if not p.running_from_removable:
            article = "a USB drive" if self.tablet else "an SD card"
            return self.show_message(
                "Installer unavailable",
                f"The installer runs from {article}. It is not available when Zaviya already runs from "
                "internal storage.")
        self.reinstall = None
        self.show("reinstall" if p.existing_install else "size")

    # -------------------------------------------------------------- install ----
    def on_hold_complete(self):
        if self._starting or self.cur != "confirm":
            return
        self._starting = True
        self.conf_back.set_sensitive(False)
        self.hold.set_text("Starting…")
        p = self.probe
        args = (self.android_gib, self.home_mode, p.fingerprint, bool(p.existing_install))
        self.run_bg(lambda: self.inst.start(*args), lambda err, exc: self.on_started(err, exc, args[3]))

    def on_started(self, err, exc, reinstall):
        if exc:
            return self.fatal(exc)
        if err:
            self._starting = False
            self.conf_error.set_text(err)
            self.conf_back.set_sensitive(True)
            self.hold.set_text(self.hold_text)
            self.hold.reset()
            return
        self.reinstall = reinstall
        self._finished = False
        self._idle_polls = 0
        self.update_progress(backend.Progress())
        self.show("progress")
        self.start_polling()

    def start_polling(self):
        if not self._poll_id:
            self._poll_id = GLib.timeout_add(500, self.poll_status)

    def finish_polling(self):
        self._finished = True
        if self._poll_id:
            GLib.source_remove(self._poll_id)
            self._poll_id = 0

    @safe
    def poll_status(self):
        if self._finished:
            self._poll_id = 0
            return False
        if not self._polling:
            self._polling = True
            self.run_bg(self.inst.status, self.on_status)
        return True

    def on_status(self, res, exc):
        self._polling = False
        if self._finished:
            return
        if exc:
            self._idle_polls += 1
            if self._idle_polls > 10:
                self.show_failed(f"The install status could not be read: {exc}", "")
            return
        self.handle_status(*res)

    def handle_status(self, state, prog, text):
        if state == "running":
            self._idle_polls = 0
            self.update_progress(prog)
        elif state == "done":
            self.update_progress(prog)
            self.show_done()
        elif state == "failed":
            self.show_failed(prog.error, text)
        else:
            self._idle_polls += 1
            if self._idle_polls > 10:
                self.show_failed("The install is no longer running.", text)

    # ------------------------------------------------------------- scripting ----
    def start_script(self, spec):
        self._script = [c.strip() for c in spec.split(",") if c.strip()]
        self._t_script = time.monotonic()
        GLib.timeout_add(1500, self._script_step)

    @safe
    def _script_step(self):
        if not self._script:
            print(f"[script] end page={self.cur}", flush=True)
            GLib.timeout_add(300, self.app.quit)
            return False
        cmd = self._script.pop(0)
        delay = 300
        if cmd == "hold":
            self.dispatch("a_down")
            GLib.timeout_add(2200, lambda: (self.dispatch("a_up"), False)[1])
            delay = 2500
        elif cmd == "tap":
            self.dispatch("a_down")
            GLib.timeout_add(80, lambda: (self.dispatch("a_up"), False)[1])
        elif cmd.startswith("wait:"):
            delay = int(float(cmd[5:]) * 1000)
        else:
            self.dispatch(cmd)
        f = self.win.get_focus()
        print(f"[script] t={time.monotonic() - self._t_script:5.1f} {cmd:8} page={self.cur} "
              f"focus={type(f).__name__ if f else None}", flush=True)
        GLib.timeout_add(delay, self._script_step)
        return False

    # -------------------------------------------------------------- snapshot ----
    def start_snapshot(self):
        step, out = SNAPSHOT
        self._snap_out = out
        known = ("checks", "size", "reinstall", "bring", "confirm", "progress", "done", "failed",
                 "unsupported")
        if step not in known:
            print(f"unknown step {step}; use one of {', '.join(known)}", file=sys.stderr)
            self.app.quit()
            return
        impl = self.inst._impl
        p = impl.probe()
        self.probe = p
        self.tablet = self.tablet or p.tablet
        self.android_gib = p.recommended_gib
        self.reinstall = p.existing_install
        if step == "checks":
            self.show("checks")
        elif step == "unsupported":
            p.unsupported = True
            self.on_probe(p, None)
        elif step in ("size", "reinstall"):
            self.show("reinstall" if p.existing_install else "size")
        elif step in ("bring", "confirm"):
            self.show(step)
        elif step == "progress":
            impl.start(self.android_gib, "all", p.fingerprint, p.existing_install)
            impl.t0 = time.monotonic() - 8.5
            self.update_progress(self.inst.status()[1])
            self.show("progress")
        elif step == "done":
            self.show_done()
        elif step == "failed":
            impl.fail = True
            impl.start(self.android_gib, "all", p.fingerprint, p.existing_install)
            impl.t0 = time.monotonic() - 12.0
            _, prog, text = self.inst.status()
            self.show_failed(prog.error, text)
        GLib.timeout_add(700, self.save_snapshot)
        GLib.timeout_add(10000, self.app.quit)      # never hang a batch run

    @safe
    def save_snapshot(self):
        w, h = self.win.get_width(), self.win.get_height()
        paintable = Gtk.WidgetPaintable.new(self.win)
        snap = Gtk.Snapshot()
        paintable.snapshot(snap, w, h)
        node = snap.to_node()
        texture = self.win.get_renderer().render_texture(node, Graphene.Rect().init(0, 0, w, h))
        texture.save_to_png(self._snap_out)
        print(f"snapshot {self._snap_out} {w}x{h}", flush=True)
        self.app.quit()
        return False


def main() -> int:
    app = Gtk.Application(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE)
    holder = []

    def on_activate(a):
        try:
            holder.append(InstallerApp(a))
        except Exception:       # noqa: BLE001
            traceback.print_exc()
            a.quit()

    app.connect("activate", on_activate)
    return app.run(ARGV)


if __name__ == "__main__":
    sys.exit(main())
