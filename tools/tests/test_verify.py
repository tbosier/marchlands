"""Failure-path tests for the verifier: no Godot or display required."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify import Stage, diagnostics, plan, run_rest, run_stage


class VerifierTests(unittest.TestCase):
    def run_script(self, source, **kwargs):
        stage = Stage("probe", [sys.executable, "-c", source], (r"^DONE$",), **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            return run_stage(stage, Path(directory), dict(os.environ))

    def test_clean_exit_requires_completion(self):
        self.assertTrue(self.run_script("print('DONE')")["passed"])
        result = self.run_script("print('started but never finished')")
        self.assertFalse(result["passed"])
        self.assertTrue(any("missing success marker" in issue for issue in result["issues"]))

    def test_engine_errors_fail_even_with_zero_exit_and_success_marker(self):
        for kind in ["ERROR", "SCRIPT ERROR", "SHADER ERROR", "USER ERROR"]:
            with self.subTest(kind=kind):
                result = self.run_script(f"print('{kind}: bad'); print('DONE')")
                self.assertFalse(result["passed"])
                self.assertEqual(result["returncode"], 0)

    def test_nonzero_exit_still_fails_with_completion_marker(self):
        result = self.run_script("print('DONE'); raise SystemExit(7)")
        self.assertFalse(result["passed"])
        self.assertIn("exit status 7", result["issues"])

    def test_stderr_and_harness_failures_are_not_lost(self):
        result = self.run_script("import sys; print('[harness] FAIL: wrong', file=sys.stderr); print('DONE')")
        self.assertFalse(result["passed"])

    def test_only_known_decoder_errors_are_allowed(self):
        output = ('BEGIN expected decoder diagnostic: full objects are forbidden\n'
                  'ERROR: Condition "!p_allow_objects" is true. Returning: ERR_UNAUTHORIZED\n'
                  'ERROR: Error when trying to decode Variant.\n'
                  'ERROR: Error when trying to encode Variant.\n'
                  'END expected decoder diagnostic\n')
        self.assertEqual(diagnostics(output, True), [])
        self.assertNotEqual(diagnostics(output, False), [])
        for extra in ["SCRIPT ERROR: unrelated bug", "ERROR: unrelated bug", "FAIL lost food"]:
            broken = output.replace("END expected", extra + "\nEND expected")
            self.assertNotEqual(diagnostics(broken, True), [])

    def test_unbounded_diagnostic_suppression_is_rejected(self):
        cases = ["BEGIN expected decoder diagnostic: full objects are forbidden",
                 "END expected decoder diagnostic",
                 "BEGIN expected decoder diagnostic: arbitrary\nEND expected decoder diagnostic",
                 "BEGIN expected decoder diagnostic: full objects are forbidden\n"
                 "BEGIN expected decoder diagnostic: full objects are forbidden\n"
                 "END expected decoder diagnostic"]
        for output in cases:
            with self.subTest(output=output):
                self.assertNotEqual(diagnostics(output, True), [])

    def test_timeout_kills_descendants_and_retains_output(self):
        with tempfile.TemporaryDirectory() as directory:
            flag = Path(directory) / "child-survived"
            child = f"import time; from pathlib import Path; time.sleep(0.6); Path({str(flag)!r}).touch()"
            parent = (f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); "
                      "print('started', flush=True); time.sleep(30)")
            stage = Stage("timeout", [sys.executable, "-c", parent], timeout=0.3)
            result = run_stage(stage, Path(directory), dict(os.environ))
            self.assertFalse(result["passed"])
            self.assertIn("timed out after 0.3s", result["issues"])
            self.assertIn("started", Path(result["log"]).read_text())
            time.sleep(0.65)
            self.assertFalse(flag.exists(), "the grandchild escaped timeout cleanup")

    def test_missing_executable_is_a_reported_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            stage = Stage("missing", [str(Path(directory) / "absent-program")])
            self.assertFalse(run_stage(stage, Path(directory), dict(os.environ))["passed"])

    def test_timeout_force_kills_a_process_that_ignores_termination(self):
        result = self.run_script(
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "print('ready', flush=True); time.sleep(30)", timeout=0.3)
        self.assertFalse(result["passed"])
        self.assertEqual(result["returncode"], -9)
        self.assertLess(result["seconds"], 6)

    def test_gate_termination_stops_active_stage_and_retains_summary(self):
        # Both paths, whatever this machine's default: one stage at a time, and
        # the pool, where the interrupt reaches a thread-run stage.
        for jobs in (1, 2):
            with self.subTest(jobs=jobs):
                self._terminate_gate(jobs)

    def _terminate_gate(self, jobs):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pid_file = root / "stage.pid"
            child = ("import os,time; from pathlib import Path; "
                     f"Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(30)")
            helper = ("import sys; from pathlib import Path; "
                      f"sys.path.insert(0,{str(Path(__file__).resolve().parents[1])!r}); "
                      f"import verify; verify.ROOT=Path({directory!r}); "
                      "verify.shutil.which=lambda _: sys.executable; "
                      f"verify.plan=lambda *_: [verify.Stage('active',[sys.executable,'-c',{child!r}])]; "
                      f"raise SystemExit(verify.main(['--headless','--skip-long-run','--jobs','{jobs}']))")
            gate = subprocess.Popen([sys.executable, "-c", helper],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and (
                        not pid_file.exists() or not pid_file.read_text().isdigit()):
                    time.sleep(0.01)
                self.assertTrue(pid_file.exists() and pid_file.read_text().isdigit(),
                                "stage failed to start")
                gate.send_signal(signal.SIGTERM)
                output, _ = gate.communicate(timeout=6)
                self.assertNotEqual(gate.returncode, 0)
                self.assertIn("Verification interrupted", output)
                summary = json.loads(next(root.glob("artifacts/verification/*/summary.json")).read_text())
                self.assertTrue(summary["interrupted"])
                self.assertFalse(summary["passed"])
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid_file.read_text()), 0)
            finally:
                if gate.poll() is None:
                    gate.kill()
                gate.communicate()
                if pid_file.exists() and pid_file.read_text().isdigit():
                    try:
                        os.killpg(int(pid_file.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_parallel_stages_overlap_and_are_isolated(self):
        """Two one-second stages finish together, each in its own user dir."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            probe = ("import os,time; time.sleep(1.0); "
                     "print('HOME=' + os.environ['MARCHLANDS_GODOT_HOME']); print('DONE')")
            stages = [Stage(name, [sys.executable, "-c", probe], (r"^DONE$",))
                      for name in ("first", "second")]
            results = []
            started = time.monotonic()
            run_rest(stages, 2, root, dict(os.environ), root / "state", results,
                     lambda _result: None, lambda: None)
            self.assertLess(time.monotonic() - started, 1.8, "stages ran one after another")
            self.assertTrue(all(result["passed"] for result in results))
            homes = {Path(r["log"]).read_text().split("HOME=")[1].split()[0] for r in results}
            self.assertEqual(len(homes), 2, "parallel stages shared a Godot user directory")

    def test_parallel_display_stages_get_their_own_server(self):
        """`xvfb-run -a` races when started together; parallel stages are numbered."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            seen = root / "commands"
            seen.mkdir()
            # Stand-in for xvfb-run: record the arguments it was given.
            fake = root / "xvfb-run"
            # printf, not echo: echo would take the "-n" it is meant to record.
            fake.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" > " + str(seen) + "/$$\necho DONE\n")
            fake.chmod(0o755)
            stages = [Stage(name, ["xvfb-run", "-a", "-s", "-screen 0 8x8x24"], (r"^DONE$",))
                      for name in ("one", "two")]
            env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"]}
            results = []
            run_rest(stages, 2, root, env, root / "state", results, lambda _r: None, lambda: None)
            recorded = [path.read_text() for path in seen.iterdir()]
            self.assertEqual(len(recorded), 2)
            self.assertTrue(all("-a" not in line.split() and "-n" in line.split() for line in recorded))
            numbers = {line.split()[line.split().index("-n") + 1] for line in recorded}
            self.assertEqual(len(numbers), 2, "two display stages were given the same server")

    def test_full_gate_includes_graphics_and_endurance(self):
        names = {stage.name for stage in plan(False, False)}
        self.assertTrue({"assets", "python-tests", "sync", "import", "regressions",
                         "save_validation", "save_fingerprint", "navigation", "production", "long_run", "bootstrap",
                         "shaders", "input_check", "ui_check"}.issubset(names))
        partial = {stage.name for stage in plan(True, True)}
        self.assertFalse({"shaders", "input_check", "ui_check", "long_run", "bootstrap"} & partial)


if __name__ == "__main__":
    unittest.main()
