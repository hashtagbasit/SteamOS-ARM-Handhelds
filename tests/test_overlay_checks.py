"""Hardware-free checks of the overlay trees: device tables, UCM files, units, syntax."""
import itertools
import json
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

try:
    import tomllib
except ImportError:  # Python < 3.11
    tomllib = None
try:
    import yaml
except ImportError:
    yaml = None

ROOT = Path(__file__).resolve().parents[1]
OVERLAYS = sorted(p for p in ROOT.glob("*-overlay") if p.is_dir())
BINARY_SUFFIXES = {".so", ".png", ".jpg", ".svg", ".ico", ".gz", ".xz", ".bin", ".pyc", ".ttf",
                   ".otf", ".woff", ".woff2", ".mp3", ".ogg", ".wav", ".webp", ".gif", ".zip"}
VENDORS = "retroidpocket|ayn|ayaneo|konkr|mangmi|redmagic"
COMPAT_TOKEN = re.compile(r"(?:^|[^A-Za-z0-9_-])((?:%s),(?:\([^()]*\)|[A-Za-z0-9._-]*))" % VENDORS)


def overlay_files():
    for ov in OVERLAYS:
        for dirpath, _dirs, files in os.walk(ov):
            for name in files:
                p = Path(dirpath) / name
                if p.is_file() and not p.is_symlink() and p.suffix not in BINARY_SUFFIXES:
                    yield p


def first_line(p):
    try:
        with open(p, "rb") as f:
            return f.readline(200).decode("utf-8", "replace")
    except OSError:
        return ""


def read(p):
    return p.read_text(encoding="utf-8", errors="replace")


def rel(p):
    return str(p.relative_to(ROOT))


def script_files():
    for p in overlay_files():
        if first_line(p).startswith("#!"):
            yield p
    for p in itertools.chain((ROOT / "scripts").glob("*"), ROOT.glob("make-steamos-*.sh")):
        if p.is_file() and first_line(p).startswith("#!"):
            yield p


def expand(token):
    """'vendor,(a|b)' -> ['vendor,a', 'vendor,b']; plain tokens stay as they are."""
    m = re.search(r"\(([^()]*)\)", token)
    if not m:
        return [token]
    return [token[:m.start()] + alt + token[m.end():] for alt in m.group(1).split("|")]


class DeviceTreeCompatibles(unittest.TestCase):
    """Every compatible string a script matches has to be in a device table."""

    @classmethod
    def setUpClass(cls):
        cls.known = set()
        for p in overlay_files():
            text = read(p)
            if p.suffix == ".toml":
                cls.known.update(re.findall(r'dt\.compatible\s*=\s*"([^"]+)"', text))
            elif p.suffix in (".yaml", ".yml") and "inputplumber" in rel(p):
                cls.known.update(re.findall(r"value:\s*([a-z0-9]+,[A-Za-z0-9._-]+)", text))

    def test_tables_are_not_empty(self):
        self.assertGreater(len(self.known), 20)

    def test_script_matches_exist_in_tables(self):
        pattern = COMPAT_TOKEN
        problems, checked = [], 0
        for p in itertools.chain(script_files(), (q for q in overlay_files() if q.suffix == ".service")):
            for n, line in enumerate(read(p).splitlines(), 1):
                if "compatible" not in line.lower() or line.lstrip().startswith("#"):
                    continue
                for tok in pattern.findall(line):
                    for one in expand(tok):
                        checked += 1
                        name = one.rstrip("$")
                        if name.endswith(",") or name.split(",", 1)[1] == "":
                            problems.append(f"{rel(p)}:{n}: '{one}' matches a whole vendor, name the boards")
                        elif name not in self.known:
                            problems.append(f"{rel(p)}:{n}: '{name}' is in no device table")
        self.assertGreater(checked, 5)
        self.assertEqual(problems, [])

    def test_whole_vendor_match_is_reported(self):
        pattern = COMPAT_TOKEN
        self.assertEqual(pattern.findall("grep -q '^retroidpocket,' compatible"), ["retroidpocket,"])

    def test_table_entries_are_unique_per_soc(self):
        for ov in OVERLAYS:
            seen = {}
            for p in ov.rglob("*.toml"):
                for c in re.findall(r'dt\.compatible\s*=\s*"([^"]+)"', read(p)):
                    self.assertNotIn(c, seen, f"{c} in {rel(p)} and {seen.get(c)}")
                    seen[c] = rel(p)


def top_level_sections(text):
    """(keyword, name) of the Section* blocks at brace depth 0, comments ignored."""
    out, depth = [], 0
    for raw in text.splitlines():
        line = raw.split("#", 1)[0]
        if depth == 0:
            m = re.match(r'\s*(Section[A-Za-z]*)\s*(?:\.\s*"([^"]*)")?', line)
            if m:
                out.append((m.group(1), m.group(2) or ""))
        depth += line.count("{") - line.count("}")
    return out


class UcmConfigs(unittest.TestCase):
    def test_no_duplicate_sections(self):
        problems = []
        files = [p for p in overlay_files() if p.suffix == ".conf" and "ucm2" in p.parts]
        self.assertTrue(files)
        for p in files:
            seen = set()
            for sec in top_level_sections(read(p)):
                if sec in seen:
                    problems.append(f"{rel(p)}: duplicate {sec[0]}.\"{sec[1]}\"")
                seen.add(sec)
        self.assertEqual(problems, [])

    def test_braces_balance(self):
        problems = []
        for p in overlay_files():
            if p.suffix == ".conf" and "ucm2" in p.parts:
                text = re.sub(r"#[^\n]*", "", read(p))
                if text.count("{") != text.count("}"):
                    problems.append(rel(p))
        self.assertEqual(problems, [])

    def test_detector_finds_a_duplicate(self):
        text = 'SectionDevice."Speaker" {\n Value { A "1" }\n}\nSectionDevice."Speaker" {\n}\n'
        secs = top_level_sections(text)
        self.assertEqual(len(secs), len(set(secs)) + 1)


EXEC = re.compile(r"^(Exec(?:Start|StartPre|StartPost|Stop|StopPost|Reload|Condition))\s*=\s*(.*)$")
# Executables the units name that are built into the image or ship with the base.
OWN_PREFIXES = ("/usr/lib/steamos-arm/", "/usr/lib/konkr/", "/usr/share/konkr-update/",
                "/usr/lib/steamos-sm8650/", "/usr/share/steamos-arm/")
OWN_NAMES = re.compile(r"^(sm8550-|steamos-arm-|konkr|zaviya|odin3)")


def unit_commands(p):
    text = read(p).replace("\\\n", " ")
    for n, line in enumerate(text.splitlines(), 1):
        m = EXEC.match(line.strip())
        if not m:
            continue
        cmd = m.group(2).lstrip("-@+!:")
        if cmd:
            yield n, cmd.split()[0]


class SystemdUnits(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = {"/" + str(p.relative_to(ov)) for ov in OVERLAYS for p in ov.rglob("*") if p.is_file() or p.is_symlink()}
        # Built or installed by the image scripts rather than kept in an overlay.
        cls.built = set()
        for p in itertools.chain((ROOT / "scripts").glob("*"), ROOT.glob("make-steamos-*.sh")):
            if p.is_file():
                cls.built.update(re.findall(r"(/usr/[A-Za-z0-9_./-]+)", read(p)))

    def test_own_executables_exist(self):
        problems = []
        units = [p for p in overlay_files() if p.suffix in (".service", ".path", ".timer", ".socket")]
        self.assertGreater(len(units), 10)
        for p in units:
            for n, exe in unit_commands(p):
                if not exe.startswith("/"):
                    continue
                own = exe.startswith(OWN_PREFIXES) or OWN_NAMES.match(os.path.basename(exe))
                if own and exe not in self.files and exe not in self.built:
                    problems.append(f"{rel(p)}:{n}: {exe} is in no overlay")
        self.assertEqual(problems, [])

    def test_enable_links_point_at_units(self):
        problems = []
        for ov in OVERLAYS:
            for p in ov.rglob("*.wants"):
                for link in p.iterdir():
                    if link.is_symlink() and not link.name.startswith("."):
                        t = os.readlink(link)
                        if t == "/dev/null":
                            continue
                        dest = Path(t) if t.startswith("/") else (link.parent / t)
                        if t.startswith("/"):
                            dest = ov / t.lstrip("/")
                        if not dest.exists() and ("/" + str(dest.relative_to(ov))) not in self.files:
                            problems.append(f"{rel(link)} -> {t}")
        self.assertEqual(problems, [])


class ShellAndPythonSyntax(unittest.TestCase):
    def test_shell_scripts_parse(self):
        problems, count = [], 0
        for p in script_files():
            shebang = first_line(p)
            if re.search(r"\b(ba)?sh\b", shebang):
                shell = "bash" if "bash" in shebang else "sh"
                count += 1
                r = subprocess.run([shell, "-n", str(p)], capture_output=True, text=True)
                if r.returncode:
                    problems.append(f"{rel(p)}: {r.stderr.strip().splitlines()[:1]}")
        self.assertGreater(count, 50)
        self.assertEqual(problems, [])

    def test_python_scripts_compile(self):
        problems, count = [], 0
        py = [p for p in overlay_files() if p.suffix == ".py" or "python" in first_line(p)]
        py += [p for p in (ROOT / "scripts").glob("*.py")]
        for p in py:
            count += 1
            try:
                compile(p.read_bytes(), str(p), "exec", dont_inherit=True)
            except SyntaxError as e:
                problems.append(f"{rel(p)}: {e}")
        self.assertGreater(count, 5)
        self.assertEqual(problems, [])


class DataFilesParse(unittest.TestCase):
    def test_toml(self):
        if tomllib is None:
            self.skipTest("tomllib needs Python 3.11")
        for p in (q for q in overlay_files() if q.suffix == ".toml"):
            with self.subTest(file=rel(p)):
                tomllib.loads(read(p))

    def test_yaml(self):
        if yaml is None:
            self.skipTest("PyYAML missing")
        for p in (q for q in overlay_files() if q.suffix in (".yaml", ".yml")):
            with self.subTest(file=rel(p)):
                yaml.safe_load(read(p))

    def test_json(self):
        for p in (q for q in overlay_files() if q.suffix == ".json"):
            with self.subTest(file=rel(p)):
                json.loads(read(p))


if __name__ == "__main__":
    unittest.main()
