const manifest = {"name":"Zaviya Control"};
const API_VERSION = 2;
const internalAPIConnection = window.__DECKY_SECRET_INTERNALS_DO_NOT_USE_OR_YOU_WILL_BE_FIRED_deckyLoaderAPIInit;
if (!internalAPIConnection) {
    throw new Error('[@decky/api]: Failed to connect to the loader as as the loader API was not initialized. This is likely a bug in Decky Loader.');
}
let api;
try {
    api = internalAPIConnection.connect(API_VERSION, manifest.name);
}
catch {
    api = internalAPIConnection.connect(1, manifest.name);
}
const callable = api.callable;
const toaster = api.toaster;
const definePlugin = (fn) => (...args) => fn(...args);

const DFL = window.DFL;
const SP_REACT = window.SP_REACT;
const SP_JSX = window.SP_JSX;
const { useEffect, useState, useCallback, useRef } = SP_REACT;
const jsx = SP_JSX.jsx;
const jsxs = SP_JSX.jsxs;

// Decky callable(): arguments are passed positionally to the Python method.
const getState = callable("get_state");
const setProfile = callable("set_profile");
const setRgb = callable("set_rgb");
const setMcu = callable("set_mcu");
const setFan = callable("set_fan");
const setPowerLed = callable("set_power_led");
const setFlip = callable("set_flip");
const bootAndroid = callable("boot_android");
const setMenuClicks = callable("set_menu_clicks");
const setBypass = callable("set_bypass");
const setButton = callable("set_button");
const setGameFan = callable("set_game_fan");
const setFanTuning = callable("set_fan_tuning");
const setChargeLimit = callable("set_charge_limit");
const setSsh = callable("set_ssh");
const installProbe = callable("install_probe");
const installStart = callable("install_start");
const installStatus = callable("install_status");
const getGames = callable("get_games");
const setGamePerf = callable("set_game_perf");
const setChargingFan = callable("set_charging_fan");
const setPassword = callable("set_password");
const saveFanCurve = callable("save_fan_curve");
const renameFanCurve = callable("rename_fan_curve");
const deleteFanCurve = callable("delete_fan_curve");
const BUILTIN_NAMES = { silent: "Quiet", balanced: "Balanced", turbo: "Cool" };
const gameFanOptions = (mine) => [
    { data: "global", label: "Same as above" },
    ...Object.entries(BUILTIN_NAMES).map(([k, v]) => ({ data: k, label: `${v} curve` })),
    ...Object.keys(mine).map((k) => ({ data: k, label: k })),
    { data: "fixed-40", label: "Fixed 40%" },
    { data: "fixed-60", label: "Fixed 60%" },
    { data: "fixed-80", label: "Fixed 80%" },
    { data: "fixed-100", label: "Fixed 100%" },
];
const REACTIONS = [
    { data: "gentle", label: "Gentle", desc: "Barely audible changes, slow to cool down" },
    { data: "calm", label: "Calm", desc: "Smooth, the default" },
    { data: "quick", label: "Quick", desc: "Follows load changes within seconds" },
    { data: "instant", label: "Instant", desc: "Jumps straight to the curve" },
];
function gameName(appid) {
    try {
        const o = window.appStore && window.appStore.GetAppOverviewByAppID(appid);
        if (o && o.display_name) return o.display_name;
    } catch (e) {}
    return `App ${appid}`;
}
const BUTTON_ACTIONS = [
    { data: "profile-next", label: "Next performance profile" },
    { data: "rgb-next", label: "Next stick lighting" },
    { data: "sticks-toggle", label: "Stick lights on/off" },
    { data: "fan-boost", label: "Fan boost" },
    { data: "game", label: "Game button (bind in Steam)" },
    { data: "none", label: "Nothing" },
];

const PROFILES = [
    { data: "silent", label: "Silent", desc: "Quiet fan, GPU capped at 75%, no game boost" },
    { data: "balanced", label: "Balanced", desc: "Full clocks on demand, game threads on the big cores" },
    { data: "turbo", label: "Turbo", desc: "Big cores held high, GPU floor raised, fan aggressive" },
];
const RGB_PRESETS = [
    { label: "Ember", mode: "static", color: "ff3c00" },
    { label: "Ice", mode: "static", color: "00b4ff" },
    { label: "Violet", mode: "static", color: "a000ff" },
    { label: "White", mode: "static", color: "ffffff" },
    { label: "Breathe", mode: "breath", color: "ff0040" },
    { label: "Off", mode: "off", color: "000000" },
];


// Custom stick colour: a hue at full saturation, as rrggbb.
function hueHex(h) {
    const f = (n) => { const k = (n + h / 60) % 6; return Math.round(255 * (1 - Math.max(0, Math.min(k, 4 - k, 1)))); };
    return [f(5), f(3), f(1)].map((v) => v.toString(16).padStart(2, "0")).join("");
}
function hexHue(hex) {
    const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
    const mx = Math.max(r, g, b), d = mx - Math.min(r, g, b);
    if (!d) return 0;
    const h = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
    return Math.round((h * 60 + 360) % 360);
}

// A slider that moves as fast as the finger: it keeps its own value while
// in use and sends only the latest one, at most every `every` ms, so the
// backend never holds it back. The stored value takes over again once it
// has been left alone for a moment.
function LiveSlider({ value, onChange, every = 120, ...props }) {
    const [v, setV] = useState(value);
    const touched = useRef(0), pending = useRef(null), timer = useRef(null);
    useEffect(() => { if (Date.now() - touched.current > 1500) setV(value); }, [value]);
    useEffect(() => () => clearTimeout(timer.current), []);
    const change = (nv) => {
        setV(nv);
        touched.current = Date.now();
        pending.current = nv;
        if (!timer.current) {
            timer.current = setTimeout(function send() {
                const out = pending.current;
                pending.current = null;
                if (out === null) { timer.current = null; return; }
                onChange(out);
                timer.current = setTimeout(send, every);
            }, 0);
        }
    };
    return jsx(DFL.SliderField, { ...props, value: v, onChange: change });
}

const section = (title, kids) => jsx(DFL.PanelSection, { title, children: kids.filter(Boolean) });
const row = (child) => jsx(DFL.PanelSectionRow, { children: child });
const note = (text) => row(jsx("div", { style: { fontSize: "12px", opacity: 0.75 }, children: text }));


// Short frame limit list. Steam offers every whole fraction of every refresh
// rate down to 12 (Pocket FIT: 12 15 18 20 24 30 36 40 45 48 60 72 90 120
// 144). It reads them from its GamescopeService state in the UI's query
// cache, so the copy there is trimmed to 30 plus the panel's refresh rates
// (Pocket FIT 30/60/90/120/144, RP6 30/60/120). Only entries are removed; the
// limiter is still Steam's. If the cache can't be found nothing changes.
const SHORT_FPS_KEY = "steamos-arm:short-fps-list";
const GS_STATE = ["GamescopeService", "State"];
let shortFpsUnsub = null;
let queryClient = null;
function shortFpsWanted() {
    try { return localStorage.getItem(SHORT_FPS_KEY) !== "0"; } catch (e) { return true; }
}
function findQueryClient() {
    if (queryClient) return queryClient;
    try {
        // Decky's module search: Steam's loader doesn't expose its module cache.
        // By shape only: the GamescopeService entry is only filled once
        // something asks for it, and the subscription catches that.
        queryClient = DFL.findModuleExport((e) => e && typeof e.getQueryData === "function"
            && typeof e.getQueryCache === "function" && typeof e.setQueryData === "function"
            && typeof e.invalidateQueries === "function") || null;
    } catch (e) { console.log("Zaviya Control: query cache", e); }
    return queryClient;
}
function trimFrameRates(d) {
    const adi = d && d.active_display_info;
    const fr = adi && adi.supported_frame_rates, rr = adi && adi.supported_refresh_rates;
    if (!Array.isArray(fr) || !Array.isArray(rr) || rr.length === 0) return null;
    const keep = new Set(rr);
    if (rr.some((r) => r % 30 === 0)) keep.add(30);
    const out = fr.filter((v) => keep.has(v));
    if (out.length === 0 || out.length === fr.length) return null;
    return { ...d, active_display_info: { ...adi, supported_frame_rates: out } };
}
// What the short list holds on this screen, for the toggle's description.
function shortFpsSteps() {
    const qc = findQueryClient();
    const adi = qc && qc.getQueryData(GS_STATE) && qc.getQueryData(GS_STATE).active_display_info;
    const rr = adi && Array.isArray(adi.supported_refresh_rates) ? [...adi.supported_refresh_rates] : [];
    if (rr.some((r) => r % 30 === 0) && !rr.includes(30)) rr.push(30);
    rr.sort((a, b) => a - b);
    return rr.length ? rr.join(" / ") : "30 / 60 / 90 / 120";
}
function applyShortFps(on) {
    if (shortFpsUnsub) { shortFpsUnsub(); shortFpsUnsub = null; }
    const qc = findQueryClient();
    if (!qc) return false;
    if (!on) { qc.invalidateQueries({ queryKey: GS_STATE }); return true; }
    const apply = () => { const t = trimFrameRates(qc.getQueryData(GS_STATE)); if (t) qc.setQueryData(GS_STATE, t); };
    shortFpsUnsub = qc.getQueryCache().subscribe((ev) => {
        const key = ev && ev.query && ev.query.queryKey;
        if (ev && ev.type === "updated" && key && key[0] === GS_STATE[0] && key[1] === GS_STATE[1]) apply();
    });
    apply();
    return true;
}
// Fan curve graph: the curve, its points (the selected one ringed) and where
// the fan is right now (filled dot) and heading (open ring).
const G = { w: 268, h: 128, l: 26, r: 8, t: 8, b: 18, t0: 30, t1: 105 };
const gx = (t) => G.l + (Math.max(G.t0, Math.min(G.t1, t)) - G.t0) / (G.t1 - G.t0) * (G.w - G.l - G.r);
const gy = (p) => G.t + (1 - Math.max(0, Math.min(100, p)) / 100) * (G.h - G.t - G.b);
function FanGraph({ points, sel, live }) {
    const pts = points || [];
    const line = pts.length ? [[G.t0, pts[0][1]], ...pts, [G.t1, pts[pts.length - 1][1]]] : [];
    const path = line.map(([t, p], i) => `${i ? "L" : "M"}${gx(t).toFixed(1)},${gy(p).toFixed(1)}`).join("");
    const area = path ? `${path}L${gx(G.t1)},${gy(0)}L${gx(G.t0)},${gy(0)}Z` : "";
    const grid = [];
    for (let t = 40; t <= 100; t += 20) {
        grid.push(jsx("line", { x1: gx(t), x2: gx(t), y1: G.t, y2: gy(0), stroke: "#ffffff14" }, `x${t}`));
        grid.push(jsx("text", { x: gx(t), y: G.h - 4, fill: "#ffffff70", fontSize: 9, textAnchor: "middle", children: `${t}°` }, `xt${t}`));
    }
    for (let p = 0; p <= 100; p += 50) {
        grid.push(jsx("line", { x1: G.l, x2: G.w - G.r, y1: gy(p), y2: gy(p), stroke: "#ffffff14" }, `y${p}`));
        grid.push(jsx("text", { x: G.l - 4, y: gy(p) + 3, fill: "#ffffff70", fontSize: 9, textAnchor: "end", children: `${p}%` }, `yt${p}`));
    }
    const kids = [
        jsxs("defs", { children: [
            jsxs("linearGradient", { id: "hc-heat", x1: 0, x2: 1, y1: 0, y2: 0, children: [
                jsx("stop", { offset: "0%", stopColor: "#4cc2ff" }),
                jsx("stop", { offset: "60%", stopColor: "#ffb547" }),
                jsx("stop", { offset: "100%", stopColor: "#ff5a3c" }),
            ] }),
        ] }),
        ...grid,
        area ? jsx("path", { d: area, fill: "url(#hc-heat)", opacity: 0.16 }) : null,
        path ? jsx("path", { d: path, fill: "none", stroke: "url(#hc-heat)", strokeWidth: 2.5, strokeLinejoin: "round" }) : null,
        ...pts.map(([t, p], i) => jsx("circle", {
            cx: gx(t), cy: gy(p), r: i === sel ? 5 : 3,
            fill: i === sel ? "#ffffff" : "#ffffffb0", stroke: i === sel ? "#4cc2ff" : "none", strokeWidth: 2,
        }, `p${i}`)),
    ];
    if (live && live.temp != null) {
        const now = Math.round((live.pwm || 0) / 2.55), aim = Math.round((live.target || 0) / 2.55);
        if (aim !== now) kids.push(jsx("circle", { cx: gx(live.temp), cy: gy(aim), r: 4, fill: "none", stroke: "#ffffffa0", strokeDasharray: "2 2" }));
        kids.push(jsx("line", { x1: gx(live.temp), x2: gx(live.temp), y1: gy(now), y2: gy(0), stroke: "#ffffff40", strokeDasharray: "3 3" }));
        kids.push(jsx("circle", { cx: gx(live.temp), cy: gy(now), r: 4.5, fill: "#7dff9a", stroke: "#0b1a10", strokeWidth: 1.5 }));
    }
    return jsx("svg", { viewBox: `0 0 ${G.w} ${G.h}`, style: { width: "100%", display: "block" }, children: kids });
}
const liveText = (live) => live && live.temp != null
    ? `Now ${live.temp} °C · fan ${Math.round((live.pwm || 0) / 2.55)}%` + (live.target !== live.pwm ? ` → ${Math.round((live.target || 0) / 2.55)}%` : "")
    : "";

// Password for the steamos user (SSH and sudo), typed twice. An existing one
// is simply replaced: the panel runs as root, so the old one isn't asked for.
function PasswordModal({ replace, onDone, closeModal }) {
    const [a, setA] = useState(""), [b, setB] = useState(""), [err, setErr] = useState("");
    return jsx(DFL.ConfirmModal, {
        strTitle: replace ? "New password for steamos" : "Password for steamos",
        strOKButtonText: "Save",
        bOKDisabled: a.length < 4 || a !== b,
        onOK: () => setPassword(a).then((ok) => {
            if (!ok) return setErr("Could not set it (use 4 characters or more, no colon)");
            toaster.toast({ title: "Zaviya Control", body: replace ? "Password changed" : "Password set" });
            onDone && onDone();
            closeModal && closeModal();
        }),
        onCancel: () => closeModal && closeModal(),
        closeModal,
        children: jsxs("div", { style: { display: "flex", flexDirection: "column", gap: "8px" }, children: [
            jsx(DFL.TextField, { label: "New password", bIsPassword: true, value: a, onChange: (e) => setA(e.target.value) }),
            jsx(DFL.TextField, { label: "Again", bIsPassword: true, value: b, onChange: (e) => setB(e.target.value) }),
            jsx("div", { style: { fontSize: "12px", opacity: 0.75 }, children: err || (b && a !== b ? "The two don't match" : replace ? "Replaces the current one, for SSH and sudo" : "Also used for sudo in Desktop Mode") }),
        ] }),
    });
}

// Install to internal storage: what gets erased, how much Android keeps, what
// to bring over. Nothing starts until the switch is on.
const HOME_CHOICES = [
    { data: "all", label: "Everything, installed games included" },
    { data: "essentials", label: "Settings, saves and Steam login (no games)" },
    { data: "none", label: "Fresh start (no Steam login, saves or games)" },
];
function InstallModal({ probe, onStart, closeModal }) {
    const installed = probe.MODE === "installed";
    const [gb, setGb] = useState(Number(probe.RECOMMENDED_ANDROID_GIB));
    const [home, setHome] = useState("all");
    const [ack, setAck] = useState(false);
    const line = (text) => jsx("div", { style: { fontSize: "13px" }, children: text });
    return jsx(DFL.ConfirmModal, {
        strTitle: "Install Zaviya to internal storage",
        strOKButtonText: "Install",
        bOKDisabled: !ack,
        onOK: () => { onStart(gb, home, installed); closeModal && closeModal(); },
        onCancel: () => closeModal && closeModal(),
        closeModal,
        children: jsxs("div", { style: { display: "flex", flexDirection: "column", gap: "8px" }, children: [
            ...(installed ? [
                line("Zaviya on internal storage is erased and copied again, games and saves on it included. Android isn't touched."),
            ] : [
                line("Android's data is erased: apps, photos, accounts."),
                line("Android itself stays and sets itself up again."),
                line("The old partition table is saved to the card so it can be put back."),
            ]),
            installed ? null : jsx(DFL.SliderField, {
                label: "Android size (GB)", value: gb, showValue: true, step: 1,
                min: Number(probe.MIN_ANDROID_GIB), max: Number(probe.MAX_ANDROID_GIB),
                onChange: setGb,
            }),
            jsx(DFL.DropdownItem, {
                label: "Bring from the card",
                rgOptions: HOME_CHOICES,
                selectedOption: home,
                onChange: (o) => setHome(o.data),
            }),
            jsx(DFL.ToggleField, { label: "I understand this erases data", checked: ack, onChange: setAck }),
        ].filter(Boolean) }),
    });
}

// Rename prompt (Steam's keyboard comes up for the text field).
function RenameModal({ name, onDone, closeModal }) {
    const [value, setValue] = useState(name);
    return jsx(DFL.ConfirmModal, {
        strTitle: "Rename curve",
        strOKButtonText: "Rename",
        onOK: () => { onDone(value); closeModal && closeModal(); },
        onCancel: () => closeModal && closeModal(),
        closeModal,
        children: jsx(DFL.TextField, { value, onChange: (e) => setValue(e.target.value) }),
    });
}

// Edits one of the user's curves in place. Every change is saved within a
// moment and konkrd follows it, so the fan can be heard changing.
function CurveEditor({ name, points, live, onChanged, onClose }) {
    const [pts, setPts] = useState(points);
    const [sel, setSel] = useState(Math.min(1, points.length - 1));
    const [armDelete, setArmDelete] = useState(false);
    const original = useRef(points);
    const timer = useRef(null);
    const commit = (next) => {
        setPts(next);
        clearTimeout(timer.current);
        timer.current = setTimeout(() => saveFanCurve(name, next).then(onChanged), 350);
    };
    useEffect(() => () => clearTimeout(timer.current), []);
    const cur = pts[sel];
    // A point stays between its neighbours, and its speed between theirs.
    const tLo = sel > 0 ? pts[sel - 1][0] + 1 : 20, tHi = sel < pts.length - 1 ? pts[sel + 1][0] - 1 : 105;
    const pLo = sel > 0 ? pts[sel - 1][1] : 0, pHi = sel < pts.length - 1 ? pts[sel + 1][1] : 100;
    const setPoint = (t, p) => commit(pts.map((q, i) => (i === sel ? [t, p] : q)));
    const add = () => {
        if (pts.length >= 8) return;
        const a = pts[sel], b = pts[sel + 1];
        const np = b ? [Math.round((a[0] + b[0]) / 2), Math.round((a[1] + b[1]) / 2)] : [Math.min(105, a[0] + 4), a[1]];
        if (b && np[0] <= a[0]) return;
        commit([...pts.slice(0, sel + 1), np, ...pts.slice(sel + 1)]);
        setSel(sel + 1);
    };
    const remove = () => {
        if (pts.length <= 2) return;
        commit(pts.filter((_, i) => i !== sel));
        setSel(Math.max(0, sel - 1));
    };
    return jsxs(SP_JSX.Fragment, { children: [
        row(jsx(FanGraph, { points: pts, sel, live })),
        note(`Editing ${name} · ${pts.length} points · changes apply as you make them`),
        row(jsx(DFL.SliderField, {
            label: "Point", value: sel + 1, min: 1, max: pts.length, step: 1, showValue: true,
            onChange: (v) => setSel(v - 1),
        })),
        row(jsx(DFL.SliderField, {
            label: "Temperature", value: cur[0], min: tLo, max: Math.max(tLo, tHi), step: 1,
            showValue: true, valueSuffix: " °C", disabled: tLo >= tHi,
            onChange: (v) => setPoint(v, cur[1]),
        })),
        row(jsx(DFL.SliderField, {
            label: "Fan speed", value: cur[1], min: pLo, max: Math.max(pLo, pHi), step: 1,
            showValue: true, valueSuffix: "%", disabled: pLo >= pHi,
            onChange: (v) => setPoint(cur[0], v),
        })),
        row(jsxs(DFL.Focusable, { style: { display: "flex", gap: "8px" }, "flow-children": "horizontal", children: [
            jsx(DFL.DialogButton, { style: { flex: 1, minWidth: 0 }, disabled: pts.length >= 8, onClick: add, children: "Add point" }),
            jsx(DFL.DialogButton, { style: { flex: 1, minWidth: 0 }, disabled: pts.length <= 2, onClick: remove, children: "Remove" }),
        ] })),
        row(jsxs(DFL.Focusable, { style: { display: "flex", gap: "8px" }, "flow-children": "horizontal", children: [
            jsx(DFL.DialogButton, { style: { flex: 1, minWidth: 0 }, onClick: () => commit(original.current), children: "Undo changes" }),
            jsx(DFL.DialogButton, {
                style: { flex: 1, minWidth: 0 },
                onClick: () => DFL.showModal(jsx(RenameModal, { name, onDone: (v) => renameFanCurve(name, v).then(() => { onChanged(); onClose(); }) })),
                children: "Rename",
            }),
        ] })),
        row(jsxs(DFL.Focusable, { style: { display: "flex", gap: "8px" }, "flow-children": "horizontal", children: [
            jsx(DFL.DialogButton, {
                style: { flex: 1, minWidth: 0, color: armDelete ? "#ff6b5a" : undefined },
                onClick: () => armDelete ? deleteFanCurve(name).then(() => { onChanged(); onClose(); }) : setArmDelete(true),
                children: armDelete ? "Press again" : "Delete",
            }),
            jsx(DFL.DialogButton, { style: { flex: 1, minWidth: 0 }, onClick: onClose, children: "Done" }),
        ] })),
    ] });
}

function fanSection(st, fan, refresh, editing, setEditing) {
    const mine = st.fan_curves || {};
    const all = { ...st.builtin_curves, ...mine };
    const following = fan.boost ? "turbo" : (fan.curve || st.profile);
    const pts = all[following] || all.balanced;
    if (editing && mine[editing]) {
        return [jsx(CurveEditor, {
            key: editing, name: editing, points: mine[editing], live: st.fan_live,
            onChanged: refresh, onClose: () => setEditing(null),
        })];
    }
    const modeRow = row(jsx(DFL.DropdownItem, {
        label: "Mode",
        description: fan.mode === "fixed"
            ? "Fixed speed (switches back to automatic above 90 °C)"
            : "Automatic, follows a temperature curve",
        rgOptions: [{ data: "auto", label: "Automatic" }, { data: "fixed", label: "Fixed speed" }],
        selectedOption: fan.mode,
        onChange: (o) => setFan(o.data, fan.fixed, fan.boost).then(refresh),
    }));
    if (fan.mode === "fixed" || !st.fan_editor) {
        return [modeRow, fan.mode === "fixed" ? row(jsx(LiveSlider, {
            label: "Speed",
            value: fan.fixed, min: 0, max: 100, step: 5, showValue: true, valueSuffix: "%",
            onChange: (v) => setFan("fixed", v, fan.boost),
        })) : null];
    }
    const tune = (patch) => setFanTuning(
        "curve" in patch ? patch.curve : (fan.curve || ""),
        patch.reaction || fan.reaction || "calm",
        "stop_below" in patch ? patch.stop_below : (fan.stop_below || 0),
    ).then(refresh);
    const profileName = BUILTIN_NAMES[st.profile] || st.profile;
    const curveOptions = [
        { data: "", label: `Profile (${profileName})` },
        ...Object.entries(BUILTIN_NAMES).map(([k, v]) => ({ data: k, label: v })),
        ...Object.keys(mine).map((k) => ({ data: k, label: k })),
        ...(Object.keys(mine).length < 8 ? [{ data: "+new", label: "New curve…" }] : []),
    ];
    const reaction = REACTIONS.find((r) => r.data === (fan.reaction || "calm")) || REACTIONS[1];
    return [
        row(jsx(FanGraph, { points: pts, sel: -1, live: st.fan_live })),
        note(liveText(st.fan_live) || "Waiting for the fan…"),
        modeRow,
        row(jsx(DFL.DropdownItem, {
            label: "Curve",
            description: fan.boost ? "Boost is on: the Cool curve wins until you turn it off" : "",
            rgOptions: curveOptions,
            selectedOption: fan.curve || "",
            onChange: (o) => {
                if (o.data !== "+new") return tune({ curve: o.data });
                const name = nextCurveName(mine);
                saveFanCurve(name, pts).then(() => tune({ curve: name })).then(() => setEditing(name));
            },
        })),
        mine[fan.curve] ? row(jsx(DFL.ButtonItem, {
            layout: "below", onClick: () => setEditing(fan.curve), children: `Edit ${fan.curve}`,
        })) : null,
        row(jsx(DFL.DropdownItem, {
            label: "Reaction",
            description: reaction.desc,
            rgOptions: REACTIONS.map((r) => ({ data: r.data, label: r.label })),
            selectedOption: reaction.data,
            onChange: (o) => tune({ reaction: o.data }),
        })),
        row(jsx(DFL.ToggleField, {
            label: "Silent when cool",
            description: fan.stop_below ? `The fan stops below ${fan.stop_below} °C and starts again ${fan.stop_below + 3} °C` : "Let the fan stop when the chip is cool",
            checked: !!fan.stop_below,
            onChange: (v) => tune({ stop_below: v ? 50 : 0 }),
        })),
        fan.stop_below ? row(jsx(LiveSlider, {
            label: "Stop below", value: fan.stop_below, min: 35, max: 70, step: 1,
            showValue: true, valueSuffix: " °C",
            onChange: (v) => tune({ stop_below: v }),
        })) : null,
        row(jsx(LiveSlider, {
            label: "While charging, at least",
            value: fan.charging_min || 0, min: 0, max: 60, step: 5,
            showValue: true, valueSuffix: "%", every: 300,
            onChange: (v) => setChargingFan(v).then(refresh),
        })),
        row(jsx(DFL.ToggleField, {
            label: "Boost",
            description: "Use the Cool curve with any profile",
            checked: !!fan.boost,
            onChange: (v) => setFan(fan.mode, fan.fixed, v).then(refresh),
        })),
    ];
}

// konkrd's GPU range per profile, as % (floor, ceiling): what a game's own
// range starts from.
const GPU_RANGE = { silent: [0, 75], balanced: [0, 100], turbo: [35, 100] };
const CORE_OPTIONS = [
    { data: "default", label: "Fast cores (default)" },
    { data: "big", label: "Big cores only" },
    { data: "all", label: "All cores" },
    { data: "custom", label: "Custom…" },
];
const PRIORITIES = [
    { data: "normal", label: "Normal" },
    { data: "high", label: "High" },
    { data: "highest", label: "Highest" },
];

// What a game's own settings change, in a few words.
function perfSummary(st, appid) {
    const c = (st.perf_games || {})[String(appid)] || {};
    const fan = gameFanChoice(st, appid);
    const bits = [
        c.profile && (PROFILES.find((p) => p.data === c.profile) || {}).label,
        c.cpu_max && `CPU ${c.cpu_max}%`,
        ("gpu_min" in c || "gpu_max" in c) && `GPU ${c.gpu_min ?? 0}–${c.gpu_max ?? 100}%`,
        c.cores && `cores ${c.cores}`,
        c.priority && `${c.priority} priority`,
        fan !== "global" && `fan ${BUILTIN_NAMES[fan] || fan.replace("fixed-", "") + (fan.startsWith("fixed-") ? "%" : "")}`,
    ].filter(Boolean);
    return bits.join(" · ");
}

// Games: an overview (the one running, those with settings of their own, and
// a picker for the rest); choosing one opens its settings.
// Picking from a dropdown closes Quick Access for the menu and mounts the
// panel again afterwards, so what has to outlive that lives out here.
let openGame = 0;
let lastState = null;
let rgbPick = { rgb: null, at: 0 };
let gameEdit = { target: 0, cfg: {}, at: 0 };

function GamePage({ st, refresh }) {
    const running = st.game && st.game.appid ? st.game.appid : 0;
    const [games, setGames] = useState([]);
    const [open, setOpenState] = useState(openGame);
    const setOpen = (id) => { openGame = id; setOpenState(id); };
    useEffect(() => { getGames().then(setGames).catch(() => {}); }, []);
    const names = new Map(games.map((g) => [g.appid, g.name]));
    const nameOf = (id) => names.get(id) || gameName(id);
    if (open) return jsx(GameSettings, { st, refresh, target: open, name: nameOf(open), running, onBack: () => setOpen(0) }, open);
    const own = [...new Set([...Object.keys(st.perf_games || {}), ...Object.keys(st.fan_games || {})])]
        .map(Number).filter((id) => id && id !== running);
    const rest = games.filter((g) => g.appid !== running && !own.includes(g.appid));
    const card = (id, label) => row(jsx(DFL.ButtonItem, {
        layout: "below",
        description: perfSummary(st, id) || "Follows Power and Fan",
        onClick: () => setOpen(id),
        children: label,
    }));
    return jsxs(SP_JSX.Fragment, { children: [
        running ? section("Now playing", [card(running, nameOf(running))]) : null,
        own.length ? section("With their own settings", own.map((id) => card(id, nameOf(id)))) : null,
        section(own.length || running ? "Other games" : "Games", [
            !own.length && !running ? note("Every game follows the Power and Fan pages until you give it settings of its own") : null,
            rest.length ? row(jsx(DFL.DropdownItem, {
                label: "Set up a game",
                strDefaultLabel: "Choose…",
                rgOptions: rest.map((g) => ({ data: g.appid, label: g.name })),
                selectedOption: null,
                onChange: (o) => setOpen(o.data),
            })) : note("No other games installed"),
        ]),
    ].filter(Boolean) });
}

// One game's settings, saved a moment after each change; konkrd applies them
// whenever the game runs, at once if it already does.
function GameSettings({ st, refresh, target, name, running, onBack }) {
    const [cfg, setCfg] = useState({});
    const [cores, setCores] = useState("");
    const timer = useRef(null);
    useEffect(() => {
        const c = gameEdit.target === target && Date.now() - gameEdit.at < 3000
            ? gameEdit.cfg : (st.perf_games || {})[String(target)] || {};
        setCfg(c);
        setCores(c.cores && !["all", "big"].includes(c.cores) ? c.cores : "");
    }, [target]);
    // Unmounted with a save still waiting (a dropdown pick does that): send it now.
    useEffect(() => () => {
        if (!timer.current) return;
        clearTimeout(timer.current);
        setGamePerf(gameEdit.target, gameEdit.cfg);
    }, []);
    const change = (patch) => {
        const next = { ...cfg, ...patch };
        Object.keys(next).forEach((k) => next[k] === undefined && delete next[k]);
        setCfg(next);
        gameEdit = { target, cfg: next, at: Date.now() };
        clearTimeout(timer.current);
        timer.current = setTimeout(() => { timer.current = null; setGamePerf(target, next).then(refresh); }, 300);
    };
    const profile = cfg.profile || st.profile;
    const [gLo, gHi] = GPU_RANGE[profile] || [0, 100];
    const customGpu = "gpu_min" in cfg || "gpu_max" in cfg;
    const coreChoice = !cfg.cores ? "default" : ["all", "big"].includes(cfg.cores) ? cfg.cores : "custom";
    const isRunning = target === running;
    const pickCores = (choice) => {
        if (choice !== "custom") return change({ cores: choice === "default" ? undefined : choice });
        const list = cores || `2-${st.cpus - 1}`;
        setCores(list);
        change({ cores: list });
    };
    return jsxs(SP_JSX.Fragment, { children: [
        section(name, [
            row(jsx(DFL.ButtonItem, { layout: "below", onClick: onBack, children: "‹  All games" })),
            note(isRunning ? "Running now: changes apply right away" : "Applied whenever this game starts"),
        ]),
        section("Performance", [
            row(jsx(DFL.DropdownItem, {
                label: "Profile",
                rgOptions: [{ data: "", label: `Follow global (${(PROFILES.find((p) => p.data === st.profile) || {}).label || st.profile})` },
                    ...PROFILES.map((p) => ({ data: p.data, label: p.label }))],
                selectedOption: cfg.profile || "",
                onChange: (o) => change({ profile: o.data || undefined }),
            })),
            row(jsx(LiveSlider, {
                label: "CPU limit", value: cfg.cpu_max || 100, min: 30, max: 100, step: 5,
                showValue: true, valueSuffix: "%", every: 300,
                onChange: (v) => change({ cpu_max: v >= 100 ? undefined : v }),
            })),
            row(jsx(DFL.ToggleField, {
                label: "Own GPU range",
                description: customGpu ? "" : `Profile range ${gLo}–${gHi} % of the GPU clock`,
                checked: customGpu,
                onChange: (v) => change(v ? { gpu_min: gLo, gpu_max: gHi } : { gpu_min: undefined, gpu_max: undefined }),
            })),
            customGpu ? row(jsx(LiveSlider, {
                label: "GPU floor", value: cfg.gpu_min ?? gLo, min: 0, max: 100, step: 5,
                showValue: true, valueSuffix: "%", every: 300,
                onChange: (v) => change({ gpu_min: v, gpu_max: Math.max(v, cfg.gpu_max ?? gHi) }),
            })) : null,
            customGpu ? row(jsx(LiveSlider, {
                label: "GPU ceiling", value: cfg.gpu_max ?? gHi, min: 0, max: 100, step: 5,
                showValue: true, valueSuffix: "%", every: 300,
                onChange: (v) => change({ gpu_max: v, gpu_min: Math.min(v, cfg.gpu_min ?? gLo) }),
            })) : null,
        ]),
        section("Threads", [
            row(jsx(DFL.DropdownItem, {
                label: "Cores",
                description: coreChoice === "default" ? "Keeps the game off the slow little cores" : "",
                rgOptions: CORE_OPTIONS,
                selectedOption: coreChoice,
                onChange: (o) => pickCores(o.data),
            })),
            coreChoice === "custom" ? row(jsx(DFL.TextField, {
                label: `Core list (0–${st.cpus - 1}, e.g. 2-4,7)`,
                value: cores,
                onChange: (e) => {
                    const v = e.target.value.replace(/[^0-9,-]/g, "");
                    setCores(v);
                    if (/^\d+(-\d+)?(,\d+(-\d+)?)*$/.test(v)) change({ cores: v });
                },
            })) : null,
            row(jsx(DFL.DropdownItem, {
                label: "Priority",
                description: cfg.priority ? "The game's threads get the CPU before background work" : "",
                rgOptions: PRIORITIES,
                selectedOption: cfg.priority || "normal",
                onChange: (o) => change({ priority: o.data === "normal" ? undefined : o.data }),
            })),
        ]),
        st.has_fan === false ? null : section("Fan", [
            row(jsx(DFL.DropdownItem, {
                label: "Fan for this game",
                rgOptions: gameFanOptions(st.fan_curves || {}),
                selectedOption: isRunning ? st.game.fan : gameFanChoice(st, target),
                onChange: (o) => setGameFan(target, o.data).then(refresh),
            })),
        ]),
        Object.keys(cfg).length || gameFanChoice(st, target) !== "global" ? section("", [row(jsx(DFL.ButtonItem, {
            layout: "below",
            onClick: () => { setGamePerf(target, {}).then(() => setGameFan(target, "global")).then(refresh); onBack(); },
            children: "Reset this game",
        }))]) : null,
    ].filter(Boolean) });
}
function gameFanChoice(st, appid) {
    const e = (st.fan_games || {})[String(appid)];
    if (!e) return "global";
    return e.mode === "fixed" ? `fixed-${e.fixed}` : e.curve || "global";
}

function nextCurveName(mine) {
    for (let i = 1; ; i++) if (!mine[`My curve ${i}`]) return `My curve ${i}`;
}

// One page at a time; the last one is remembered.
const TAB_KEY = "handheld-control:tab";
function savedTab() {
    try { return ["power", "fan", "game", "lights", "more"].includes(localStorage.getItem(TAB_KEY)) ? localStorage.getItem(TAB_KEY) : "power"; } catch (e) { return "power"; }
}
// Steam's own tabs, as other Quick Access plugins use: L1/R1 switch pages.
// They need a fixed box to scroll in, and icons so five of them fit.
const TAB_CSS = `
  .hc-tabs > div > div:first-child { background: #0D141C; box-shadow: none; backdrop-filter: none; }
  .hc-tabs [role="tabpanel"] { padding-left: 8px !important; padding-right: 8px !important; }
  .hc-tabs [role="tablist"] { display: flex; flex-wrap: nowrap; justify-content: center; }
  .hc-tabs [role="tab"] { flex: 0 1 auto; min-width: 0; box-sizing: border-box; padding-left: 6px !important;
    padding-right: 6px !important; display: flex !important; align-items: center; justify-content: center; }
  .hc-tabs [role="tab"] svg { display: block; margin: 0; }
  .hc-tabs .hc-tab-content { padding-bottom: 96px; }
`;
const icon = (...paths) => jsx("svg", {
    width: 18, height: 18, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 2,
    strokeLinecap: "round", strokeLinejoin: "round", style: { display: "block" },
    children: paths.map((d, i) => jsx("path", { d }, i)),
});
const TAB_ICONS = {
    power: icon("M13 2 3 14h9l-1 8 10-12h-9l1-8z"),
    fan: icon("M10.827 16.379a6.082 6.082 0 0 1-8.618-7.002l5.412 1.45a6.082 6.082 0 0 1 7.002-8.618l-1.45 5.412a6.082 6.082 0 0 1 8.618 7.002l-5.412-1.45a6.082 6.082 0 0 1-7.002 8.618l1.45-5.412Z", "M12 12v.01"),
    game: icon("M6 11h4", "M8 9v4", "M15 12h.01", "M18 10h.01",
        "M17.32 5H6.68a4 4 0 0 0-3.978 3.59c-.006.052-.01.101-.017.152C2.604 9.416 2 14.456 2 16a3 3 0 0 0 3 3c1 0 1.5-.5 2-1l1.414-1.414A2 2 0 0 1 9.828 16h4.344a2 2 0 0 1 1.414.586L17 18c.5.5 1 1 2 1a3 3 0 0 0 3-3c0-1.545-.604-6.584-.685-7.258-.007-.05-.011-.1-.017-.151A4 4 0 0 0 17.32 5z"),
    lights: icon("M15 14c.2-1 .7-1.7 1.5-2.5 1-.9 1.5-2.2 1.5-3.5A6 6 0 0 0 6 8c0 1 .2 2.2 1.5 3.5.7.7 1.3 1.5 1.5 2.5", "M9 18h6", "M10 22h4"),
    more: icon("M4 21v-7", "M4 10V3", "M12 21v-9", "M12 8V3", "M20 21v-5", "M20 12V3", "M1 14h6", "M9 8h6", "M17 16h6"),
};

// The installer runs as a system unit, so it keeps going if Steam restarts.
// Probe once per mount; the status is polled while the panel is open.
let lastProbe = null;
function InternalStorage({ tablet }) {
    const [probe, setProbe] = useState(lastProbe);
    const [job, setJob] = useState({ state: "idle", line: "" });
    const [err, setErr] = useState("");
    useEffect(() => {
        let live = true;
        if (!lastProbe) {
            installProbe().then((p) => {
                if (!p.error) lastProbe = p;
                if (live) setProbe(p);
            }).catch(() => {});
        }
        const poll = () => installStatus().then((j) => { if (live) setJob(j); }).catch(() => {});
        poll();
        const t = setInterval(poll, 2000);
        return () => { live = false; clearInterval(t); };
    }, []);
    if (!probe || probe.unsupported) return null;
    const start = (gb, home, reinstall) => {
        lastProbe = null;
        setErr("");
        installStart(gb, home, probe.TABLE_FINGERPRINT, reinstall).then((r) => {
            if (r.error) setErr(r.error); else setJob({ state: "running", line: "" });
        }).catch(() => setErr("Could not start the install"));
    };
    const ready = !probe.error && probe.RUNNING_FROM_SD === "1" && (probe.MODE === "fresh" || probe.MODE === "installed");
    const button = row(jsx(DFL.ButtonItem, {
        layout: "below",
        disabled: !ready,
        description: "How much space Android keeps is chosen next",
        onClick: () => DFL.showModal(jsx(InstallModal, { probe, onStart: start })),
        children: "Install to internal storage",
    }));
    const notes = [
        probe.error ? note(probe.error) : null,
        err ? note(err) : null,
        probe.MODE === "occupied" ? note("Other partitions follow userdata. Remove them in the ABL menu (UNINSTALL CFW) first.") : null,
    ];
    let body;
    if (job.state === "running") {
        body = [note("Installing, about 5 to 10 minutes. Don't power off or remove the card."), note(job.line)];
    } else if (job.state === "done") {
        body = [note(tablet
            ? "Install finished. Power off, unplug the USB drive, then power on."
            : "Install finished. Power off, remove the card, then in the ABL menu set Boot source to Internal and boot Linux.")];
    } else if (job.state === "failed") {
        body = [note("Install failed."), note(job.line), button, ...notes];
    } else {
        body = [button, ...notes];
    }
    return section("Internal storage", body);
}

function Content() {
    const withPick = (n) => (n && Date.now() - rgbPick.at < 2500 ? { ...n, rgb: rgbPick.rgb } : n);
    const [st, setStState] = useState(() => withPick(lastState));
    const setSt = (n) => setStState((lastState = n));
    const [shortFps, setShortFps] = useState(shortFpsWanted());
    const [editing, setEditing] = useState(null);
    const [tab, setTab] = useState(savedTab());
    const pickTab = (id) => { setTab(id); setEditing(null); try { localStorage.setItem(TAB_KEY, id); } catch (e) {} };
    // Lights change through konkrd's request socket, which answers before
    // konkrd has saved: show the pick at once and keep a refresh that lands
    // in between from putting the old one back.
    const refresh = useCallback(() => {
        getState().then((n) => setSt(withPick(n))).catch(() => {});
    }, []);
    const lights = (mode, color, brightness) => {
        rgbPick = { rgb: { mode, color, brightness }, at: Date.now() };
        setSt(withPick(lastState));
        return setRgb(mode, color, brightness);
    };
    useEffect(() => {
        refresh();
        const t = setInterval(refresh, 2000);
        return () => clearInterval(t);
    }, [refresh]);

    if (!st) {
        return jsx(DFL.PanelSection, { children: row("Loading…") });
    }
    const prof = PROFILES.find((p) => p.data === st.profile) || PROFILES[1];
    const ownProfile = st.game && st.game.appid && ((st.perf_games || {})[String(st.game.appid)] || {}).profile;
    const gameProf = ownProfile && ownProfile !== st.profile ? PROFILES.find((p) => p.data === ownProfile) : null;
    const fan = st.fan || { mode: "auto", fixed: 50, boost: false };
    const status = [
        st.temp_c != null ? `${st.temp_c} °C` : null,
        st.fan_rpm != null ? `fan ${st.fan_rpm} rpm (${Math.round((st.fan_pwm || 0) / 2.55)}%)` : null,
        st.gpu_mhz != null ? `GPU ${st.gpu_mhz} MHz` : null,
    ].filter(Boolean).join(" · ");

    const tabs = [
        { id: "power", label: "Power" },
        { id: "fan", label: "Fan" },
        { id: "game", label: "Game" },
        { id: "lights", label: "Lights" },
        { id: "more", label: "More" },
    ].filter((t) => t.id !== "fan" || st.has_fan !== false);
    const pages = {
        power: () => [
            section("Profile", [
                row(jsx(DFL.DropdownItem, {
                    label: "Profile",
                    description: prof.desc,
                    rgOptions: PROFILES.map((p) => ({ data: p.data, label: p.label })),
                    selectedOption: st.profile,
                    onChange: (o) => setProfile(o.data).then(refresh),
                })),
            ]),
            st.charge_limit != null || (st.bypass && st.bypass.supported) ? section("Battery", [
                st.charge_limit != null ? row(jsx(LiveSlider, { every: 600,
                    label: "Charge limit",
                    value: st.charge_limit, min: 55, max: 100, step: 5, showValue: true, valueSuffix: " %",
                    onChange: (v) => setChargeLimit(v).then(refresh),
                })) : null,
                st.bypass && st.bypass.supported ? row(jsx(DFL.ToggleField, {
                    label: "Bypass charging",
                    description: st.bypass.on
                        ? `Plugged in, the battery stays at ${st.bypass.level} % and the device runs from the charger`
                        : "Run from the charger and leave the battery alone, for long sessions plugged in (holds at 55 % or more)",
                    checked: !!st.bypass.on,
                    onChange: (v) => setBypass(v).then(refresh),
                })) : null,
            ]) : null,
            section("Frame limit", [
                row(jsx(DFL.ToggleField, {
                    label: "Short frame limit list",
                    description: shortFpsSteps(),
                    checked: shortFps,
                    onChange: (v) => { try { localStorage.setItem(SHORT_FPS_KEY, v ? "1" : "0"); } catch (e) {} setShortFps(v); applyShortFps(v); },
                })),
            ]),
            st.has_dualboot ? section("Restart", [
                st.has_dualboot ? row(jsx(DFL.ButtonItem, {
                    layout: "below",
                    description: st.dualboot_text,
                    onClick: () => bootAndroid(),
                    children: st.dualboot_label || "Restart into Android",
                })) : null,
            ]) : null,
        ],
        fan: () => [section("Fan", fanSection(st, fan, refresh, editing, setEditing))],
        game: () => [jsx(GamePage, { st, refresh }, "game")],
        lights: () => [section("Lighting", [
                row(jsx(DFL.DropdownItem, {
                    label: "Stick lighting",
                    disabled: !st.sticks_led,
                    description: st.sticks_led ? "" : (st.has_mcu_link ? "Needs the controller MCU link (in More)" : "No stick lights found on this device"),
                    rgOptions: [...RGB_PRESETS.map((p, i) => ({ data: i, label: p.label }))
                        .filter((o) => st.has_breath || RGB_PRESETS[o.data].mode !== "breath"),
                        { data: "custom", label: "Custom colour" }],
                    selectedOption: (() => {
                        const i = RGB_PRESETS.findIndex((p) => p.mode === st.rgb.mode && p.color === st.rgb.color);
                        return i >= 0 ? i : st.rgb.mode === "static" ? "custom" : RGB_PRESETS.length - 1;
                    })(),
                    onChange: (o) => {
                        const p = o.data === "custom" ? { mode: "static", color: hueHex(200) } : RGB_PRESETS[o.data];
                        lights(p.mode, p.color, st.rgb.brightness || 160);
                    },
                })),
                st.sticks_led && st.rgb.mode === "static" && !RGB_PRESETS.some((p) => p.color === st.rgb.color) ? row(jsx(LiveSlider, {
                    label: "Colour",
                    value: hexHue(st.rgb.color), min: 0, max: 359, step: 3,
                    onChange: (v) => lights("static", hueHex(v), st.rgb.brightness || 160),
                })) : null,
                st.sticks_led && st.rgb.mode === "static" ? row(jsx(LiveSlider, {
                    label: "Brightness",
                    value: Math.round((st.rgb.brightness || 160) / 2.55), min: 5, max: 100, step: 5,
                    showValue: true, valueSuffix: "%",
                    onChange: (v) => lights(st.rgb.mode, st.rgb.color, Math.round(v * 2.55)),
                })) : null,
                st.has_power_led ? row(jsx(DFL.ToggleField, {
                    label: "Power LED",
                    description: "Charging / full / low-battery colours and profile flashes",
                    checked: st.power_led !== false,
                    onChange: (v) => setPowerLed(v).then(refresh),
                })) : null,
        ])],
        more: () => [
            st.fit_buttons ? section("Buttons", [
                ...[["F13", "KONKR button"], ["F14", "Performance button"]].map(([key, label]) => row(jsx(DFL.DropdownItem, {
                    label,
                    description: (st.buttons || {})[key] === "game"
                        ? "A controller button: bind it per game in Steam's controller settings (shows as a trackpad click)"
                        : "",
                    rgOptions: BUTTON_ACTIONS,
                    selectedOption: (st.buttons || {})[key] || "none",
                    onChange: (o) => setButton(key, o.data).then(refresh),
                }))),
                note("Home = Steam button · right front button = Quick Access · Power: tap to sleep, hold for the power menu"),
            ]) : null,
            st.system ? section("System", [
                row(jsx(DFL.Field, { label: "Version", description: `${st.system.os} · build ${st.system.build}`, focusable: true })),
                row(jsx(DFL.Field, { label: "Kernel", description: st.system.kernel, focusable: true })),
                row(jsx(DFL.ToggleField, {
                    label: "Remote access (SSH)",
                    description: st.system.ssh ? `From a PC: ssh steamos@${st.system.ip || "this device"}`
                        : st.system.has_password ? "Log in from a PC on the same network"
                        : "Set a password for steamos first: SSH logs in with it",
                    checked: !!st.system.ssh,
                    disabled: !st.system.ssh && !st.system.has_password,
                    onChange: (v) => setSsh(v).then(refresh),
                })),
                row(jsx(DFL.ButtonItem, {
                    layout: "below",
                    onClick: () => DFL.showModal(jsx(PasswordModal, { replace: st.system.has_password, onDone: refresh })),
                    children: st.system.has_password ? "Change password" : "Set a password",
                })),
            ]) : null,
            section("Device", [
                st.has_motors ? row(jsx(DFL.ToggleField, {
                    label: "Menu clicks",
                    description: "A light buzz when moving through Steam's menus",
                    checked: st.menu_clicks !== false,
                    onChange: (v) => setMenuClicks(v).then(refresh),
                })) : null,
                st.has_flip ? row(jsx(DFL.ToggleField, {
                    label: "Flip screen",
                    description: "Turn Game Mode the other way up, for controllers that plug into the short side. Applies the next time Game Mode starts (restart the tablet)",
                    checked: !!st.flip,
                    onChange: (v) => setFlip(v).then(refresh),
                })) : null,
                st.has_mcu_link ? row(jsx(DFL.ToggleField, {
                    label: "Controller MCU link",
                    description: "Needed for the KONKR, Performance and Quick Access buttons and stick lighting",
                    checked: st.mcu_enabled,
                    onChange: (v) => setMcu(v).then(() => {
                        toaster.toast({ title: "Zaviya Control", body: v ? "MCU link enabled" : "MCU link disabled" });
                        refresh();
                    }),
                })) : null,
            ]),
            jsx(InternalStorage, { tablet: !!st.tablet }),
        ],
    };
    const header = jsx("div", { style: { fontSize: "12px", opacity: 0.8, textAlign: "center", padding: "4px 0" },
        children: st.daemon ? `${prof.label}${gameProf ? ` → ${gameProf.label} for this game` : ""} · ${status}` : `${st.daemon_name || "konkrd"} is not running` });
    return jsxs("div", {
        className: "hc-tabs",
        style: { height: "95%", width: "300px", position: "fixed", marginTop: "-12px", overflow: "hidden" },
        children: [
            jsx("style", { children: TAB_CSS }),
            jsx(DFL.Tabs, {
                activeTab: tabs.some((t) => t.id === tab) ? tab : "power",
                onShowTab: pickTab,
                tabs: tabs.map((t) => ({
                    id: t.id,
                    title: TAB_ICONS[t.id],
                    content: jsxs("div", { className: "hc-tab-content", children: [header, ...pages[t.id]().filter(Boolean)] }),
                })),
            }),
        ],
    });
}

// Toast whenever the profile or fan boost changes (KONKR button, konkrctl or
// this panel), like Android's on-screen mode switch. Registered at plugin
// load, so it works with Quick Access closed and over games.
const MODE_TOAST = {
    silent: { title: "🌙  Silent", body: "Quiet fan, GPU capped" },
    balanced: { title: "⚖️  Balanced", body: "Full clocks on demand" },
    turbo: { title: "⚡  Turbo", body: "Maximum performance, fan aggressive" },
};
function onMode(profile, boost, profileChanged) {
    const t = profileChanged
        ? MODE_TOAST[profile] || { title: profile, body: "" }
        : { title: boost ? "🌀  Fan boost on" : "🌀  Fan boost off", body: (MODE_TOAST[profile] || {}).title || "" };
    toaster.toast({ title: t.title, body: t.body, duration: 2000, playSound: false, critical: true });
}

var index = definePlugin(() => {
    api.addEventListener("konkr_mode", onMode);
    // Steam may not have its GamescopeService state yet at plugin load.
    let shortFpsTries = 0;
    const shortFpsTimer = setInterval(() => {
        if (!shortFpsWanted() || applyShortFps(true) || ++shortFpsTries > 30) clearInterval(shortFpsTimer);
    }, 2000);
    return {
        name: "Zaviya Control",
        content: jsx(Content, {}),
        icon: jsx("div", { style: { fontWeight: 800 }, children: "H" }),
        alwaysRender: false,
        onDismount() {
            api.removeEventListener("konkr_mode", onMode);
            clearInterval(shortFpsTimer);
            if (shortFpsUnsub) { shortFpsUnsub(); shortFpsUnsub = null; }
        },
    };
});

export { index as default };
