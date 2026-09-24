#!/usr/bin/env python3
"""Run the same Marchlands verification gate locally and in CI (Linux).

Uses committed assets; Blender is only needed to regenerate them. A successful
process exit alone is insufficient: Godot can log a script error and exit zero.
Every test must also reach its own success marker without unexpected errors.
"""

from __future__ import annotations

import argparse
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from dataclasses import dataclass, replace
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
ANSI = re.compile(r"\x1b\[[0-9;]*m")
ERROR = re.compile(r"^\s*(?:(?:SCRIPT |SHADER |USER )?ERROR:|CRASH:|Traceback \()")
FAIL = re.compile(r"^\s*(?:\[harness\]\s*)?FAIL(?:ED)?\b")
DECODER_BEGIN = "BEGIN expected decoder diagnostic: "
DECODER_END = "END expected decoder diagnostic"
DECODER_CASES = {"full objects are forbidden", "invalid compressed bytes"}
DECODER_ERRORS = (
    re.compile(r'^ERROR: Condition "!p_allow_objects" is true\. Returning: ERR_UNAUTHORIZED$'),
    re.compile(r"^ERROR: Error when trying to (?:decode|encode) Variant\.$"),
)
SCENARIOS = (
    "first_road", "regrowth", "construction", "farm_check", "tools_check",
    "industry", "save_load", "upgrade", "households", "stress",
)


# Stages that build what every later stage runs against. They run first, one
# at a time, and a failure among them stops the gate.
SETUP = ("python-tests", "assets", "sync", "import")

# Process groups of stages that are running, so an interrupted parallel gate
# can stop all of them rather than only the one the main thread waited on.
_ACTIVE: set[int] = set()
_ACTIVE_LOCK = threading.Lock()
# Set once the gate is stopping. A stage whose process starts after that (its
# worker was between taking the stage and registering the pid) kills itself.
_STOPPING = threading.Event()


def stop_active() -> None:
    """Terminate every running stage's process group, then force the rest.

    A second Ctrl-C during the grace period skips straight to the force."""
    _STOPPING.set()
    with _ACTIVE_LOCK:
        groups = list(_ACTIVE)
    for group in groups:
        try:
            os.killpg(group, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and groups:
            groups = [g for g in groups if _alive(g)]
            time.sleep(0.05)
    except KeyboardInterrupt:
        pass
    with _ACTIVE_LOCK:
        groups = list(_ACTIVE)
    for group in groups:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass


_DISPLAY_LOCK = threading.Lock()
_DISPLAYS_TAKEN: set[int] = set()


def claim_display(start: int = 300) -> int:
    """A free X display number, not in use by this gate or anything else.

    Numbered servers instead of `xvfb-run -a` because -a races when several
    stages start together; checked against the X lock files so a gate in
    another checkout, or any other X server, is not trodden on."""
    with _DISPLAY_LOCK:
        number = start
        while (number in _DISPLAYS_TAKEN or Path(f"/tmp/.X{number}-lock").exists()
               or Path(f"/tmp/.X11-unix/X{number}").exists()):
            number += 1
        _DISPLAYS_TAKEN.add(number)
        return number


def release_display(number: int) -> None:
    with _DISPLAY_LOCK:
        _DISPLAYS_TAKEN.discard(number)


def _alive(group: int) -> bool:
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False


@dataclass(frozen=True)
class Stage:
    name: str
    command: list[str]
    success: tuple[str, ...] = ()
    timeout: float = 180
    expected_decoders: bool = False


def diagnostics(output: str, expected_decoders: bool = False) -> list[str]:
    """Allow only known decoder errors inside the negative test's exact markers."""
    errors = []
    block = None
    for raw in ANSI.sub("", output).splitlines():
        line = raw.strip()
        if line.startswith(DECODER_BEGIN):
            case = line.removeprefix(DECODER_BEGIN)
            if not expected_decoders or block is not None or case not in DECODER_CASES:
                errors.append("unexpected/nested diagnostic marker: " + line)
            block = case
        elif line == DECODER_END:
            if block is None or not expected_decoders:
                errors.append("unmatched diagnostic marker: " + line)
            block = None
        elif ERROR.match(line):
            allowed = (expected_decoders and block == "full objects are forbidden"
                       and any(pattern.fullmatch(line) for pattern in DECODER_ERRORS))
            if not allowed:
                errors.append(line)
        elif FAIL.match(line):
            errors.append(line)
    if block is not None:
        errors.append("unterminated expected diagnostic block")
    return errors


def run_stage(stage: Stage, output_dir: Path, env: dict[str, str],
              cwd: Path = ROOT) -> dict:
    started = time.monotonic()
    log = output_dir / (stage.name + ".log")
    issues = []
    returncode = None
    # Write directly to a file to retain partial output if the gate is killed
    # and avoid buffering a long-running simulation's entire output in RAM.
    with log.open("w", encoding="utf-8") as stream:
        try:
            process = subprocess.Popen(stage.command, cwd=cwd, env=env,
                                       stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            with _ACTIVE_LOCK:
                _ACTIVE.add(process.pid)
            if _STOPPING.is_set():
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                returncode = process.wait(timeout=stage.timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
                # Give checkers time to reap their separately grouped probes,
                # then kill any remaining members (including wrapper children).
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    process.poll()  # Reap the leader; a checker may outlive it.
                    try:
                        os.killpg(process.pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.05)
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                if isinstance(exc, KeyboardInterrupt):
                    raise
                issues.append(f"timed out after {stage.timeout:g}s")
                returncode = process.returncode
            finally:
                with _ACTIVE_LOCK:
                    _ACTIVE.discard(process.pid)
        except OSError as exc:
            issues.append(str(exc))
            stream.write(str(exc) + "\n")
    output = ANSI.sub("", log.read_text(encoding="utf-8", errors="replace"))
    if returncode != 0:
        issues.append(f"exit status {returncode}")
    issues.extend(diagnostics(output, stage.expected_decoders))
    for pattern in stage.success:
        if not re.search(pattern, output, re.MULTILINE):
            issues.append("missing success marker: " + pattern)
    return {"name": stage.name, "passed": not issues, "returncode": returncode,
            "seconds": round(time.monotonic() - started, 2), "log": str(log),
            "issues": issues}


def plan(headless: bool, skip_long_run: bool) -> list[Stage]:
    python = sys.executable
    godot = [str(ROOT / "tools/godot_env.sh"), "--path", str(ROOT / "game")]
    headless_godot = godot + ["--headless", "--audio-driver", "Dummy"]
    stages = [
        Stage("python-tests", [python, "-m", "unittest", "discover", "-s", "tools/tests"],
              (r"^Ran [1-9][0-9]* tests? in ", r"^OK$")),
        Stage("assets", [python, "tools/validators/validate_assets.py"],
              (r"^=== [1-9][0-9]* passed, 0 failed, [0-9]+ with warnings ===$",)),
        Stage("sync", [str(ROOT / "tools/build.sh"), "sync"]),
        Stage("import", headless_godot + ["--import"], timeout=300),
    ]
    for name, marker in [
        ("regressions", r"^Regression failures: 0$"),
        ("save_validation", r"^Save validation: [1-9][0-9]* rejected fixtures; 0 failures$"),
        ("save_fingerprint", r"^Save fingerprint regression failures: 0$"),
        ("navigation", r"^Navigation regression failures: 0$"),
        ("production", r"^Production regression failures: 0$"),
        ("roads_research", r"^Road research regression failures: 0$"),
        ("market", r"^Market regression failures: 0$"),
        ("world_presentation", r"^World presentation regression failures: 0$"),
        ("soldier", r"^Soldier regression failures: 0$"),
        ("campaign", r"^Campaign regression failures: 0$"),
        ("game_integration", r"^Game integration regression failures: 0$"),
        ("military_equipment", r"^Military equipment regression failures: 0$"),
        ("conscription", r"^Conscription regression failures: 0$"),
        ("soldier_injuries", r"^Soldier injury regression failures: 0$"),
        ("detailed_wounds", r"^Detailed wound regression failures: 0$"),
        ("field_medicine", r"^Field medicine regression failures: 0$"),
        ("frontier_security", r"^Frontier security regression failures: 0$"),
        ("scouting", r"^Scouting regression failures: 0$"),
        ("water", r"^Water regression failures: 0$"),
        ("husbandry", r"^Husbandry regression failures: 0$"),
        ("world_sizes", r"^World size failures: 0$"),
        ("spawn_layouts", r"^Spawn layout regression failures: 0$"),
        ("building_placement", r"^Building placement regression failures: 0$"),
        ("bridges", r"^Bridge regression failures: 0$"),
        ("trade", r"^Trade regression failures: 0$"),
        ("connections", r"^Connections regression failures: 0$"),
    ]:
        stages.append(Stage(name, headless_godot + ["--script", f"res://tests/{name}.gd"],
                            (marker,), timeout=300 if name in ("spawn_layouts", "campaign") else 180,
                            expected_decoders=name == "save_validation"))
    for name in SCENARIOS:
        stages.append(Stage(name, headless_godot + ["--fixed-fps", "60", "--",
                            f"--harness=tools/scenes/{name}.json"],
                            (r"^\[harness\] ALL CHECKS PASSED$",), timeout=300))
    if not skip_long_run:
        stages.append(Stage("long_run", headless_godot +
                            ["--script", "res://tests/long_run.gd"],
                            (r"^Long-run failures: 0$",), timeout=1200))
        stages.append(Stage("bootstrap", headless_godot +
                            ["--script", "res://tests/bootstrap.gd"],
                            (r"^Bootstrap failures: 0$",), timeout=1200))
    if not headless:
        stages.append(Stage("shaders", [str(ROOT / "tools/build.sh"), "shaders"],
                            (r"^=== [1-9][0-9]* passed, 0 failed, [0-9]+ with warnings ===$",),
                            timeout=420))
        display = ["xvfb-run", "-a", "-s", "-screen 0 1600x1000x24"]
        stages.append(Stage("expansion_ui", display + godot + ["--display-server", "x11",
                            "--rendering-driver", "opengl3", "--audio-driver", "Dummy",
                            "--resolution", "1280x720", "--script", "res://tests/expansion_ui.gd"],
                            (r"^Expansion UI regression failures: 0$",), timeout=300))
        stages.append(Stage("society_ui", display + godot + ["--display-server", "x11",
                            "--rendering-driver", "opengl3", "--audio-driver", "Dummy",
                            "--resolution", "1280x720", "--script", "res://tests/society_ui.gd"],
                            (r"^Society UI regression failures: 0$",), timeout=300))
        stages.append(Stage("connections_ui", display + godot + ["--display-server", "x11",
                            "--rendering-driver", "opengl3", "--audio-driver", "Dummy",
                            "--resolution", "1280x720", "--script", "res://tests/connections_ui.gd"],
                            (r"^Connections UI regression failures: 0$",), timeout=300))
        stages.append(Stage("visual_ui", display + godot + ["--display-server", "x11",
                            "--rendering-driver", "opengl3", "--audio-driver", "Dummy",
                            "--resolution", "1280x720", "--script", "res://tests/visual_ui.gd"],
                            (r"^Visual UI regression failures: 0$",), timeout=300))
        stages.append(Stage("terrain_fertility", display + godot + ["--display-server", "x11",
                            "--rendering-driver", "opengl3", "--audio-driver", "Dummy",
                            "--resolution", "320x240", "--script", "res://tests/terrain_fertility.gd"],
                            (r"^Terrain fertility failures: 0$",), timeout=180))
        for name, marker in [("fog_presentation", r"^Fog presentation failures: 0$"),
                             ("scouting_ui", r"^Scouting UI regression failures: 0$"),
                             ("water_ui", r"^Water UI regression failures: 0$"),
                             ("well_visual", r"^Well visual regression failures: 0$")]:
            stages.append(Stage(name, display + godot + ["--display-server", "x11",
                                "--rendering-driver", "opengl3", "--audio-driver", "Dummy",
                                "--resolution", "1280x720", "--script", f"res://tests/{name}.gd"],
                                (marker,), timeout=300))
        for name, resolution in [("input_check", "1600x900"), ("ui_check", "793x900")]:
            stages.append(Stage(name, display + godot + ["--display-server", "x11",
                                "--rendering-driver", "opengl3", "--audio-driver", "Dummy",
                                "--resolution", resolution, "--fixed-fps", "5", "--",
                                f"--harness=tools/scenes/{name}.json"],
                                (r"^\[harness\] ALL CHECKS PASSED$",), timeout=300))
    return stages


def default_jobs() -> int:
    """About a third of the machine's threads, up to eight: each stage is one
    Godot process, and the display stages add an Xvfb and a software renderer."""
    return max(1, min(8, (os.cpu_count() or 2) // 3))


# The last complete gate's stage durations, longest first, so the slowest
# stages start at once instead of finishing last. Unknown stages count as a
# minute.
def _expected_seconds() -> dict[str, float]:
    runs = sorted((ROOT / "artifacts/verification").glob("*/summary.json"), reverse=True)
    for path in runs:
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if data.get("complete_gate") and len(data.get("results", [])) > 40:
            return {item["name"]: float(item["seconds"]) for item in data["results"]}
    return {}


def run_rest(stages: list[Stage], jobs: int, output_dir: Path, env: dict[str, str],
             state_dir: Path, results: list, report, save) -> None:
    """Run the post-setup stages, `jobs` at a time.

    In parallel each stage gets its own Godot user directory, so two tests that
    write the same save slot cannot read each other's file, and each display
    stage gets its own Xvfb server number rather than racing `xvfb-run -a` for
    the next free one. Timeouts grow with the load: a stage sharing the CPU with
    seven others runs slower than it does alone.
    """
    if jobs <= 1:
        for stage in stages:
            print(f"RUN  {stage.name} (timeout {stage.timeout:g}s)", flush=True)
            result = run_stage(stage, output_dir, env)
            results.append(result)
            save()
            report(result)
        return
    expected = _expected_seconds()
    stages = sorted(stages, key=lambda stage: -expected.get(stage.name, 60.0))
    scale = min(2.5, 1.0 + 0.25 * (jobs - 1))
    prepared = []
    for stage in stages:
        prepared.append((replace(stage, timeout=stage.timeout * scale),
                         {**env, "MARCHLANDS_GODOT_HOME": str(state_dir / "parallel" / stage.name)}))

    def run_one(stage: Stage, stage_env: dict[str, str]) -> dict:
        command = list(stage.command)
        display = -1
        if command and command[0] == "xvfb-run" and "-a" in command:
            display = claim_display()
            at = command.index("-a")
            command[at:at + 1] = ["-n", str(display)]
        try:
            return run_stage(replace(stage, command=command), output_dir, stage_env)
        finally:
            if display >= 0:
                release_display(display)
    print(f"running {len(prepared)} stages, {jobs} at a time (timeouts x{scale:g})", flush=True)
    pool = ThreadPoolExecutor(max_workers=jobs)
    pending = set()
    try:
        for stage, stage_env in prepared:
            pending.add(pool.submit(run_one, stage, stage_env))
        while pending:
            # Short waits keep the main thread able to take the interrupt that
            # SIGTERM and Ctrl-C raise.
            done, pending = wait(pending, timeout=0.5, return_when=FIRST_COMPLETED)
            for future in done:
                result = future.result()
                results.append(result)
                save()
                report(result)
    except KeyboardInterrupt:
        pool.shutdown(wait=False, cancel_futures=True)
        stop_active()
        raise
    pool.shutdown(wait=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--headless", action="store_true",
                        help="partial gate: omit real-driver shaders and viewport tests")
    parser.add_argument("--skip-long-run", action="store_true",
                        help="partial gate: omit the multi-seed endurance test")
    parser.add_argument("--jobs", type=int, default=default_jobs(),
                        help="stages run at once after setup (default %(default)s; 1 = serial)")
    args = parser.parse_args(argv)
    needed = [name for name in ["rsync"] if not shutil.which(name)]
    if not args.headless:
        needed += [name for name in ["xvfb-run", "Xvfb", "xauth"] if not shutil.which(name)]
    godot = os.environ.get("GODOT") or shutil.which("godot") or str(ROOT / "tools/vendor/godot")
    if not shutil.which(godot):
        needed.append("godot (or set GODOT)")
    if needed:
        print("Missing verification dependencies: " + ", ".join(needed), file=sys.stderr)
        return 2

    # Never replace interactive quicksaves or overlap imports from another gate.
    state_dir = ROOT / ".godot-home/verification"
    state_dir.mkdir(parents=True, exist_ok=True)
    lock = (state_dir / "gate.lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("Another verification gate is already running in this checkout.", file=sys.stderr)
        lock.close()
        return 2
    output_dir = ROOT / "artifacts/verification" / (time.strftime("%Y%m%d-%H%M%S") + f"-{os.getpid()}")
    output_dir.mkdir(parents=True)
    partial = args.headless or args.skip_long_run
    env = {**os.environ, "GODOT": godot, "MARCHLANDS_GODOT_HOME": str(state_dir / "user"),
           "LIBGL_ALWAYS_SOFTWARE": "1", "PYTHONUNBUFFERED": "1"}
    results = []
    summary = {"complete_gate": not partial, "results": results, "passed": False}
    summary_path = output_dir / "summary.json"
    print(f"{'PARTIAL' if partial else 'FULL'} verification; logs: {output_dir}", flush=True)

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    previous_term = signal.signal(signal.SIGTERM, interrupted)
    try:
        stages = plan(args.headless, args.skip_long_run)
        setup = [stage for stage in stages if stage.name in SETUP]
        rest = [stage for stage in stages if stage.name not in SETUP]

        def report(result: dict) -> None:
            print(f"{'PASS' if result['passed'] else 'FAIL'} {result['name']} ({result['seconds']:.1f}s)", flush=True)
            if not result["passed"]:
                for issue in result["issues"][:12]:
                    print("  " + issue, flush=True)
                print("  log: " + result["log"], flush=True)

        setup_ok = True
        for stage in setup:
            print(f"RUN  {stage.name} (timeout {stage.timeout:g}s)", flush=True)
            result = run_stage(stage, output_dir, env)
            results.append(result)
            summary_path.write_text(json.dumps(summary, indent=2) + "\n")
            report(result)
            if not result["passed"]:
                # Setup failures make all dependent Godot results meaningless.
                setup_ok = False
                break
        if setup_ok:
            run_rest(rest, args.jobs, output_dir, env, state_dir, results, report,
                     lambda: summary_path.write_text(json.dumps(summary, indent=2) + "\n"))
        summary["passed"] = (len(results) == len(plan(args.headless, args.skip_long_run))
                             and all(item["passed"] for item in results))
    except KeyboardInterrupt:
        summary["interrupted"] = True
        print("Verification interrupted; partial logs retained.", flush=True)
    finally:
        summary_path.write_text(json.dumps(summary, indent=2) + "\n")
        lock.close()
        signal.signal(signal.SIGTERM, previous_term)
    print(f"{'PASS' if summary['passed'] else 'FAIL'} {'partial' if partial else 'full'} verification: "
          f"{sum(item['passed'] for item in results)}/{len(results)} stages; {summary_path}", flush=True)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
