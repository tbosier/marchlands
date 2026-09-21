#!/usr/bin/env python3
"""Compile the project's shaders and fail if the engine rejected one.

    python3 tools/validators/check_shaders.py [-v] [shader.gdshader ...]

With no arguments it checks every *.gdshader under game/shaders/. Named files
may live anywhere, which is how the checker is tested: point it at a
deliberately broken copy in a scratch directory and it must go red without
anything under game/shaders/ being touched.

Why this exists
---------------
The eighteen harness scenarios run `--headless`, and a headless Godot exits 0
whether or not its shaders compiled. Break water.gdshader and run smoke.json:
the engine prints `SHADER ERROR: Unknown identifier ...`, the scenario prints
ALL CHECKS PASSED, and the process returns 0. The complaint is made and nobody
is listening. Headless also stops at Godot's own shader parser — the dummy
renderer has no graphics driver to hand the result to — so everything past that
parser is never exercised at all.

This runs the shaders through a real OpenGL context instead, via
game/tools/shader_probe.gd, and reads what Godot says about them. Mesa's
llvmpipe under Xvfb is enough, so it wants no GPU and no display of its own.

What is checked, and why not something simpler
----------------------------------------------
  * Godot's diagnostics, its exit status, and that the probe reached its end.
    A failed shader prints `SHADER ERROR:` and `Shader compilation failed.` on
    stderr with an exit status of 0, so the status alone proves nothing;
    equally, a probe that died before finishing has not shown the shader to be
    good. All three have to hold.

    Rather than list the phrases the engine uses, any line the engine prefixes
    with `ERROR:` (or `SHADER ERROR:`, `USER ERROR:`, `SCRIPT ERROR:`) counts.
    The probe loads one shader and draws one quad, so there is nothing else in
    the run for an error to be about — and a clean run measurably prints none,
    only a V-Sync warning. An allowlist of wordings would have covered the
    parser's messages and missed the driver stage's, which are worded
    differently and are the half a headless run never reaches.

  * The uniforms the engine ended up with, against the `uniform` lines in the
    source. A shader Godot's parser rejected exposes none of them. This
    corroborates the diagnostics rather than standing in for them: the list is
    built by that same parser, so it says nothing about whether the driver
    accepted the generated GLSL.

  * That the shaders and the GDScript driving them still agree about names.
    `set_shader_parameter()` on a name the shader does not declare is silently
    ignored: rename a uniform and the game keeps running, keeps compiling, and
    quietly draws with the default. Nothing else in the build would say a word.

What is deliberately *not* checked is the picture. A broken spatial shader is
widely said to draw magenta; on Godot 4.7's Compatibility renderer it draws an
ordinary lit grey whose variation across the test quad measured lower than the
water shader's own, so there is no threshold that tells them apart.
"""

from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
GAME_DIR = os.path.join(REPO_ROOT, "game")
SHADER_DIR = os.path.join(GAME_DIR, "shaders")
SCRIPT_DIR = os.path.join(GAME_DIR, "scripts")
PROBE = "res://tools/shader_probe.gd"

USAGE = "usage: check_shaders.py [-v] [shader.gdshader ...]"

# Generous, because this is a Godot start-up plus a software-rendered draw on a
# machine that may be doing several other things at once. It bounds a hang; it
# is not a performance target.
TIMEOUT_S = 180

# Godot prefixes everything it considers an error with one of these. See the
# module docstring for why this is a prefix test and not a list of the phrases
# the engine happens to use today.
GODOT_ERROR_RE = re.compile(r"^\s*(?:SHADER |USER |SCRIPT )?ERROR:|^\s*CRASH:")

# `uniform [lowp|mediump|highp] <type> <name>` with an optional `: hint` and an
# optional `= default`. Not anchored to the start of a line: two declarations
# can share one, and the second would otherwise go unseen and unchecked.
UNIFORM_RE = re.compile(
    r"\b(global\s+|instance\s+)?uniform\s+"
    r"(?:lowp\s+|mediump\s+|highp\s+)?"
    r"\w+\s+(\w+)\s*(?:\[[^\]]*\])?\s*(?::[^;=]*)?(=)?")

# Both quote styles, because GDScript accepts either and a checker that knew
# only one would quietly stop checking a file somebody had reformatted.
SHADER_LOAD_RE = re.compile(r"""load\(\s*["']res://shaders/([\w.]+)["']\s*\)""")
SET_PARAM_RE = re.compile(r"""set_shader_parameter\(\s*["'](\w+)["']""")
DICT_KEY_RE = re.compile(r"""["'](\w+)["']\s*:""")


def display_path(path: str) -> str:
    """Repo-relative where that is shorter, absolute where it is not.

    A scratch copy of a shader in $TMPDIR is a normal thing to check — it is
    how this checker is tested — and relpath renders those as a ladder of
    `../../..` that says nothing about where the file actually is.
    """
    rel = os.path.relpath(path, REPO_ROOT)
    return path if rel.startswith("..") else rel


class Report:
    """PASS/WARN/FAIL lines for one shader, rendered like validate_assets.py."""

    def __init__(self, name: str):
        self.name = name
        self.lines: list[tuple[str, str]] = []

    def check(self, ok: bool, message: str, warn_only: bool = False):
        if ok:
            self.lines.append(("PASS", message))
        else:
            self.lines.append(("WARN" if warn_only else "FAIL", message))
        return ok

    def warn(self, message: str):
        self.lines.append(("WARN", message))

    def note(self, message: str):
        self.lines.append(("INFO", message))

    @property
    def failed(self) -> bool:
        return any(level == "FAIL" for level, _ in self.lines)

    @property
    def warned(self) -> bool:
        return any(level == "WARN" for level, _ in self.lines)

    def render(self, verbose: bool) -> str:
        body = [f"    {level}: {message}" for level, message in self.lines
                if verbose or level not in ("PASS", "INFO")]
        status = "FAIL" if self.failed else ("WARN" if self.warned else "OK")
        head = f"  [{status:>4}] {self.name}"
        return head + "\n" + "\n".join(body) if body else head


def strip_shader_comments(src: str) -> str:
    """Blank out // and /* */ so prose about uniforms is not read as code.

    Both shaders explain themselves at length and both discuss their own
    uniforms in that prose; scanning the raw text invents uniforms that do not
    exist and then reports the GDScript as failing to set them.

    Each comment becomes a space rather than nothing, because deleting one
    outright welds its neighbours together: `uniform/* note */float x;` comes
    back as `uniformfloat x;` and the declaration disappears.
    """
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", " ", src)


def strip_gdscript_comments(src: str) -> str:
    """Blank out `#` comments in GDScript, without touching strings.

    Quote-aware on purpose, in both directions. A regex cutting at every `#`
    would truncate a line holding a colour literal like "#8a6f4a" and lose
    whatever followed it. And a commented-out `set_shader_parameter(...)` left
    in the source would otherwise be counted as though the call were still
    live — which is exactly the state where this check needs to notice that
    nothing is setting a uniform any more.
    """
    out: list[str] = []
    quote = ""
    i = 0
    while i < len(src):
        ch = src[i]
        if quote:
            if ch == "\\" and i + 1 < len(src):
                out.append(src[i:i + 2])
                i += 2
                continue
            if src.startswith(quote, i):
                out.append(quote)
                i += len(quote)
                quote = ""
                continue
        elif ch in "\"'":
            quote = src[i:i + 3] if src.startswith(ch * 3, i) else ch
            out.append(quote)
            i += len(quote)
            continue
        elif ch == "#":
            while i < len(src) and src[i] != "\n":
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def declared_uniforms(src: str) -> dict[str, bool]:
    """Every material uniform the source declares, and whether it has a default.

    `global uniform` and `instance uniform` are skipped: Godot does not return
    those from get_shader_uniform_list(), so counting them here would report
    them as lost in compilation on a shader that had compiled perfectly well.
    """
    found: dict[str, bool] = {}
    for scope, name, default in UNIFORM_RE.findall(strip_shader_comments(src)):
        if not scope:
            found[name] = bool(default)
    return found


def find_godot() -> str:
    """The same search order tools/build.sh uses: PATH, then tools/vendor/."""
    if os.environ.get("GODOT"):
        return os.environ["GODOT"]
    found = shutil.which("godot")
    if found:
        return found
    vendored = os.path.join(REPO_ROOT, "tools", "vendor", "godot")
    return vendored if os.access(vendored, os.X_OK) else ""


def probe_command(shader_path: str) -> tuple[list[str], str]:
    """The argv that compiles one shader, and a word for how it will run.

    Godot only builds a shader when it has a real driver to build it for, so
    this deliberately does *not* pass --headless: that is the dummy renderer,
    and the dummy renderer is precisely the hole this checker fills.

    Xvfb is preferred over an inherited DISPLAY even where both exist. Trusting
    DISPLAY means trusting that the variable still points at a server that will
    accept a connection — a forwarded session that has since closed sets it
    every bit as convincingly as a live desktop does — and there is no way back
    to Xvfb once that choice has been made. Going to Xvfb every time also means
    the shaders are compiled by llvmpipe everywhere, so a shader that passes on
    a workstation passes in CI for the same reason rather than by luck.
    """
    godot_env = os.path.join(REPO_ROOT, "tools", "godot_env.sh")
    argv = [
        godot_env,
        "--path", GAME_DIR,
        "--rendering-driver", "opengl3",
        # No sound card on a build machine, and ALSA's complaints about that
        # land on stderr next to the shader diagnostics being read here.
        "--audio-driver", "Dummy",
        "--resolution", "320x240",
        "--script", PROBE,
        "--", shader_path,
    ]
    xvfb = shutil.which("xvfb-run")
    if xvfb:
        # Xvfb provides X11 even when the parent desktop advertises Wayland.
        argv[1:1] = ["--display-server", "x11"]
        return [xvfb, "-a", "-s", "-screen 0 320x240x24"] + argv, "Xvfb"
    if os.environ.get("DISPLAY"):
        return argv, "the display already attached"
    return argv, ""


def run_probe(shader_path: str) -> tuple[str, int]:
    """Compile one shader in its own Godot, returning its output and status."""
    argv, _how = probe_command(shader_path)
    # Its own process group, so that a timeout can take the whole tree down.
    # subprocess kills the child it started, which here is the xvfb-run
    # wrapper; Godot and the X server beneath it are grandchildren and would be
    # left running on the build machine, holding a display number each.
    proc = None
    completed = False
    pending_signal = None
    previous_handlers = {}

    def interrupted(signum, _frame):
        nonlocal pending_signal
        # A signal can arrive inside Popen before it returns the child handle.
        # Remember it until the handle exists, then follow the same cleanup
        # path; raising here would lose the newly created process group.
        pending_signal = signum
        if proc is not None:
            if signum == signal.SIGINT:
                raise KeyboardInterrupt
            raise SystemExit(128 + signum)

    def stop_probe():
        # Ignore repeat interrupts while killing/reaping the detached group.
        # Its ID is the original PID even if the wrapper has already exited
        # and only its grandchildren still hold the captured stdout open.
        for signum in previous_handlers:
            signal.signal(signum, signal.SIG_IGN)
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return proc.communicate()[0] or ""

    try:
        # The verification gate sends SIGTERM to this checker's group, but
        # each probe is deliberately in its own session. Coordinate shutdown
        # so terminating the checker also removes its Xvfb/Godot children.
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous_handlers[signum] = signal.signal(signum, interrupted)
        proc = subprocess.Popen(
            argv, cwd=REPO_ROOT,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            start_new_session=True,
            env={**os.environ, "GODOT": find_godot()})
        if pending_signal is not None:
            interrupted(pending_signal, None)
        try:
            output, _ = proc.communicate(timeout=TIMEOUT_S)
        except subprocess.TimeoutExpired:
            output = stop_probe()
            completed = True
            # Preserve the existing timeout report and failure status.
            return f"{output}\n[timed out after {TIMEOUT_S}s]", -1
        completed = True
        return output, proc.returncode
    finally:
        try:
            if proc is not None and not completed:
                output = stop_probe()
                if output:
                    print(output, end="", file=sys.stderr, flush=True)
        finally:
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)


def check_shader(shader_path: str, verbose: bool) -> tuple[Report, set[str]]:
    """Compile one shader; return its report and the uniforms it really has."""
    rep = Report(display_path(shader_path))
    with open(shader_path, encoding="utf-8") as handle:
        source = handle.read()

    # The probe compiles from source text, so the Shader it builds carries no
    # resource path and a relative `#include` has nothing to resolve against.
    # Compiling it anyway would check a different body of code from the one the
    # game loads and then report the result as though it were the same.
    if re.search(r"^\s*#include\b", strip_shader_comments(source), re.MULTILINE):
        rep.check(False, "shader has no #include (the probe cannot resolve one "
                         "against a resource path this Shader does not have)")
        return rep, set()

    declared = declared_uniforms(source)
    output, status = run_probe(shader_path)

    # A first run can lose a race inside xvfb-run, which picks a display number
    # by looking for a free lock file and only then starts a server on it; two
    # checks running at once can pick the same one. That failure leaves no
    # probe output whatever, which is distinguishable from a shader that failed
    # to compile, so it is worth exactly one retry.
    if "PROBE_UNIFORMS" not in output:
        output, status = run_probe(shader_path)

    lines = [ln.rstrip() for ln in output.splitlines()]
    if verbose:
        for line in lines:
            if line.startswith("OpenGL API "):
                rep.note(line.strip())
            elif line.startswith("PROBE_PIXELS "):
                rep.note("rendered mean rgb " + line.split(" ", 1)[1])

    # All three, not any one of them. The exit status is 0 even for a shader
    # the engine rejected outright, so on its own it proves nothing; but a
    # probe that crashed or timed out before printing its last line has not
    # shown the shader to be good either, and its markers being present is no
    # comfort while the process behind them went down.
    #
    # The marker test has no trailing space in it because a shader the parser
    # rejected reports an *empty* uniform list, and the line is then the marker
    # and nothing else. Matching "PROBE_UNIFORMS " filed every broken shader
    # under "the probe did not finish" — wrong, and the least informative of
    # the three things this could have said about it.
    finished = ("PROBE_DONE" in lines
                and any(ln.startswith("PROBE_UNIFORMS") for ln in lines)
                and status == 0)
    if not rep.check(finished,
                     f"probe ran to completion (godot exited {status})"):
        for line in output.strip().splitlines()[-12:]:
            rep.warn("godot: " + line)
        return rep, set()

    complaints = [ln.strip() for ln in lines
                  if not ln.startswith("PROBE_") and GODOT_ERROR_RE.search(ln)]
    rep.check(not complaints, "engine reported no error")
    for line in complaints:
        rep.warn("godot: " + line)

    compiled: set[str] = set()
    for line in lines:
        if line.startswith("PROBE_UNIFORMS"):
            _, _, names = line.partition(" ")
            compiled = set(names.split(",")) if names.strip() else set()

    missing = sorted(set(declared) - compiled)
    rep.check(not missing,
              f"all {len(declared)} declared uniform(s) survived compilation"
              + (f" (lost: {missing})" if missing else ""))
    return rep, compiled


def parameter_tables(src: str, known: set[str]) -> set[str]:
    """Uniform names a script sets through a dictionary rather than by hand.

    `set_shader_parameter("world_size", …)` is easy to read off; the ten
    terrain colours are not, because terrain.gd holds them in a dictionary and
    loops over its keys, so the only thing at the call site is a variable.
    Those ten are the names most likely to be renamed and least likely to be
    noticed, since a misspelt one is a no-op the game never reports.

    A dictionary is taken to be addressed at the shader when at least one of
    its string keys is a uniform of a shader this file loads. That is what
    keeps an unrelated dictionary — a lookup of building types, say — out of
    the check, while a table where nine keys of ten still match and the tenth
    has been renamed is caught on the tenth. The limit of the heuristic is a
    table in which *every* key was renamed at once: with nothing left matching,
    the table stops being recognised and goes unchecked. Doing better means
    following the variable at the call site back to the material it belongs to,
    which is a GDScript dataflow problem rather than a grep.
    """
    text = strip_gdscript_comments(src)
    tables: set[str] = set()
    starts: list[int] = []
    quote = ""
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if text.startswith(quote, i):
                i += len(quote)
                quote = ""
                continue
        elif ch in "\"'":
            # Braces inside a string are not syntax. A "}" in a format string
            # closed a dictionary early and dropped every key after it.
            quote = text[i:i + 3] if text.startswith(ch * 3, i) else ch
            i += len(quote)
            continue
        elif ch == "{":
            starts.append(i)
        elif ch == "}" and starts:
            keys = set(DICT_KEY_RE.findall(text[starts.pop() + 1:i]))
            if keys & known:
                tables |= keys
        i += 1
    return tables


def check_gdscript_agreement(
        compiled: dict[str, tuple[str, set[str]]]) -> Report:
    """Cross-check the names GDScript uses against the names shaders declare.

    `compiled` maps a shader's *file name* to where it came from and to the
    uniforms it actually compiled to. Keying on the bare file name is what lets
    this run when the checker has been aimed at a copy of the shaders somewhere
    else: GDScript says `load("res://shaders/terrain.gdshader")`, and the copy
    being compiled is still the terrain shader.

    A script is skipped unless *every* shader it loads was checked in this run.
    Checking water.gdshader on its own otherwise reported terrain.gd's six
    terrain parameters as names nobody had declared: six failures, in a run
    where nothing at all was wrong.

    A script that loads two shaders is checked against the union of their
    uniforms, because terrain.gd builds both materials and deciding which of
    them a given call belongs to means following the variable it is called on.
    The union still catches a name belonging to neither, which is what a rename
    produces; it would not catch a parameter moved from one of the two
    materials to the other.

    Both directions are mistakes no other check in the build would catch,
    because neither is an error at runtime. Setting a parameter the shader does
    not declare is a silent no-op, and a uniform with no default that nobody
    sets is a silent default — the white placeholder texture for a sampler, or
    a world_size of nought that folds the whole terrain into a single texel.
    """
    rep = Report("<gdscript agreement>")
    uniforms = {name: names for name, (_path, names) in compiled.items()}
    defaults = {}
    for name, (path, _names) in compiled.items():
        with open(path, encoding="utf-8") as handle:
            defaults[name] = declared_uniforms(handle.read())

    assigned: dict[str, set[str]] = {name: set() for name in uniforms}
    covered: set[str] = set()
    checked_files = 0
    for root, _dirs, files in os.walk(SCRIPT_DIR):
        for fname in sorted(files):
            if not fname.endswith(".gd"):
                continue
            path = os.path.join(root, fname)
            with open(path, encoding="utf-8") as handle:
                src = strip_gdscript_comments(handle.read())
            loaded = sorted(set(SHADER_LOAD_RE.findall(src)))
            if not loaded:
                continue
            rel = os.path.relpath(path, REPO_ROOT)
            unchecked = [s for s in loaded if s not in uniforms]
            if unchecked:
                rep.note(f"{rel} skipped: it also loads {unchecked}, "
                         f"which this run did not compile")
                continue
            checked_files += 1
            known: set[str] = set()
            for shader in loaded:
                known |= uniforms[shader]
                covered.add(shader)
            used = set(SET_PARAM_RE.findall(src)) | parameter_tables(src, known)
            for shader in loaded:
                assigned[shader] |= used
            for key in sorted(used):
                rep.check(key in known,
                          f"{rel} sets \"{key}\", which "
                          f"{' + '.join(loaded)} declare(s)")

    if checked_files == 0:
        rep.note("no GDScript loads these shaders; nothing to cross-check")
        return rep

    for shader in sorted(covered):
        for name, has_default in sorted(defaults[shader].items()):
            if has_default or name not in uniforms[shader]:
                continue
            rep.check(name in assigned[shader],
                      f"{shader}'s \"{name}\" has no default, so GDScript "
                      f"must set it")
    return rep


def find_shaders() -> list[str]:
    """Every .gdshader under game/shaders/, nested ones included.

    os.walk rather than os.listdir: a shader filed under game/shaders/effects/
    would otherwise never be compiled by the one target whose whole job is to
    compile the shaders, and nothing anywhere would say so.
    """
    found = []
    for root, _dirs, files in os.walk(SHADER_DIR):
        found += [os.path.join(root, f)
                  for f in files if f.endswith(".gdshader")]
    return sorted(found)


def main() -> int:
    verbose = False
    wanted: list[str] = []
    for arg in sys.argv[1:]:
        if arg in ("-v", "--verbose"):
            verbose = True
        elif arg.startswith("-"):
            # Quietly dropping an unrecognised flag is how a CI invocation
            # comes to check the default shaders while whoever wrote it
            # believes it is checking the ones they named.
            print(f"unknown option: {arg}", file=sys.stderr)
            print(USAGE, file=sys.stderr)
            return 2
        else:
            wanted.append(arg)

    if wanted:
        shaders = [os.path.abspath(p) for p in wanted]
        # Naming a file that does not exist must not silently check something
        # else and exit clean; the asset validator learned that the hard way.
        for path in shaders:
            if not os.path.isfile(path):
                print(f"No such shader: {path}", file=sys.stderr)
                return 2
    else:
        shaders = find_shaders()
    if not shaders:
        print("No shaders found.", file=sys.stderr)
        return 2

    if not find_godot():
        print("error: godot not found. Install it (pacman -S godot) or place a",
              file=sys.stderr)
        print("       binary at tools/vendor/godot.", file=sys.stderr)
        return 2

    # Settle how the shaders will be compiled before announcing anything, so
    # that a machine with neither Xvfb nor a display says why it cannot run
    # instead of printing a header with a hole in it and then dying.
    _argv, how = probe_command(shaders[0])
    if not how:
        print("error: no xvfb-run and no DISPLAY. This check has to compile the",
              file=sys.stderr)
        print("       shaders against a real GL driver; a headless run would",
              file=sys.stderr)
        print("       pass them without looking. Install xvfb (pacman -S",
              file=sys.stderr)
        print("       xorg-server-xvfb) or run it under an X session.",
              file=sys.stderr)
        return 2

    print(f"\n=== Marchlands shader compilation: {len(shaders)} shader(s), "
          f"OpenGL on {how} ===\n")

    reports = []
    compiled: dict[str, tuple[str, set[str]]] = {}
    # One Godot per shader; game/tools/shader_probe.gd explains why a single
    # run cannot say which of two shaders an error belongs to.
    for path in shaders:
        rep, names = check_shader(path, verbose)
        reports.append(rep)
        if not rep.failed:
            compiled[os.path.basename(path)] = (path, names)
    if compiled:
        reports.append(check_gdscript_agreement(compiled))

    for rep in reports:
        print(rep.render(verbose))

    failed = [r.name for r in reports if r.failed]
    warned = [r.name for r in reports if r.warned and not r.failed]
    print(f"\n=== {len(reports) - len(failed)} passed, {len(failed)} failed, "
          f"{len(warned)} with warnings ===")
    if failed:
        print(f"failed: {failed}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
