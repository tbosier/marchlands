#!/usr/bin/env python3
"""Run the same Marchlands verification gate locally and in CI (Linux).

Uses committed assets; Blender is only needed to regenerate them. A successful
process exit alone is insufficient: Godot can log a script error and exit zero.
Every test must also reach its own success marker without unexpected errors.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
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
        ("husbandry", r"^Husbandry regression failures: 0$"),
        ("world_sizes", r"^World size failures: 0$"),
        ("bridges", r"^Bridge regression failures: 0$"),
        ("trade", r"^Trade regression failures: 0$"),
        ("connections", r"^Connections regression failures: 0$"),
    ]:
        stages.append(Stage(name, headless_godot + ["--script", f"res://tests/{name}.gd"],
                            (marker,), expected_decoders=name == "save_validation"))
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
        for name, resolution in [("input_check", "1600x900"), ("ui_check", "793x900")]:
            stages.append(Stage(name, display + godot + ["--display-server", "x11",
                                "--rendering-driver", "opengl3", "--audio-driver", "Dummy",
                                "--resolution", resolution, "--fixed-fps", "5", "--",
                                f"--harness=tools/scenes/{name}.json"],
                                (r"^\[harness\] ALL CHECKS PASSED$",), timeout=300))
    return stages


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--headless", action="store_true",
                        help="partial gate: omit real-driver shaders and viewport tests")
    parser.add_argument("--skip-long-run", action="store_true",
                        help="partial gate: omit the multi-seed endurance test")
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
        for stage in plan(args.headless, args.skip_long_run):
            print(f"RUN  {stage.name} (timeout {stage.timeout:g}s)", flush=True)
            result = run_stage(stage, output_dir, env)
            results.append(result)
            summary_path.write_text(json.dumps(summary, indent=2) + "\n")
            print(f"{'PASS' if result['passed'] else 'FAIL'} {stage.name} ({result['seconds']:.1f}s)", flush=True)
            if not result["passed"]:
                for issue in result["issues"][:12]:
                    print("  " + issue, flush=True)
                print("  log: " + result["log"], flush=True)
                # Setup failures make all dependent Godot results meaningless.
                if stage.name in {"python-tests", "assets", "sync", "import"}:
                    break
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
