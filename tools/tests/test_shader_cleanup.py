"""Shader cancellation must not leave detached display/probe processes alive."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
sys.path.insert(0, str(TOOLS / "validators"))

import check_shaders
from verify import Stage, run_stage


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux process-group regression")
class ShaderCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.ids = self.directory / "probe-pids"
        self.ready = self.directory / "probe-ready"

    def probe_source(self, *, wrapper_exits=False):
        child = ("import time; from pathlib import Path; "
                 f"Path({str(self.ready)!r}).touch(); time.sleep(30)")
        return ("import os,subprocess,sys,time; from pathlib import Path; "
                f"child=subprocess.Popen([sys.executable,'-c',{child!r}]); "
                f"Path({str(self.ids)!r}).write_text(str(os.getpid())+' '+str(child.pid)); "
                "print('probe started',flush=True); "
                + ("sys.exit(0)" if wrapper_exits else "time.sleep(30)"))

    def checker_source(self, *, wrapper_exits=False):
        return ("import sys; "
                f"sys.path.insert(0,{str(TOOLS / 'validators')!r}); "
                "import check_shaders as checker; "
                f"command=[sys.executable,'-c',{self.probe_source(wrapper_exits=wrapper_exits)!r}]; "
                "checker.probe_command=lambda _: (command,'test'); "
                "checker.find_godot=lambda: sys.executable; "
                "checker.run_probe('unused')")

    @staticmethod
    def alive(pid):
        try:
            # A killed grandchild may remain a zombie briefly until reaped by
            # its new parent. It cannot retain a display or keep doing work.
            stat = Path(f"/proc/{pid}/stat").read_text()
            return stat[stat.rfind(")") + 2:].split()[0] != "Z"
        except FileNotFoundError:
            return False

    def assert_probe_stopped(self):
        self.assertTrue(self.ids.exists(), "fixture never started its probe")
        pids = [int(value) for value in self.ids.read_text().split()]
        deadline = time.monotonic() + 2
        while any(self.alive(pid) for pid in pids) and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertFalse([pid for pid in pids if self.alive(pid)],
                         "detached probe or its grandchild survived cleanup")

    def clean_fixture(self, checker=None):
        if checker is not None and checker.poll() is None:
            checker.kill()
            checker.wait()
        if self.ids.exists():
            group = int(self.ids.read_text().split()[0])
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_success_keeps_output_status_and_signal_handlers(self):
        command = [sys.executable, "-c", "print('probe output'); raise SystemExit(7)"]
        before = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        with patch.object(check_shaders, "probe_command", return_value=(command, "test")):
            output, status = check_shaders.run_probe("unused")
        self.assertEqual((output, status), ("probe output\n", 7))
        self.assertEqual(before, {sig: signal.getsignal(sig) for sig in before})

    def test_interrupt_during_process_creation_keeps_the_child_handle(self):
        original_popen = subprocess.Popen
        children = []

        def start_then_interrupt(*args, **kwargs):
            child = original_popen(*args, **kwargs)
            children.append(child)
            # Deliver cancellation before run_probe receives Popen's return
            # value: it must remember the signal, then kill/reap this child.
            os.kill(os.getpid(), signal.SIGTERM)
            return child

        command = [sys.executable, "-c", "import time; time.sleep(30)"]
        before = signal.getsignal(signal.SIGTERM)
        with patch.object(check_shaders, "probe_command", return_value=(command, "test")), \
                patch.object(check_shaders.subprocess, "Popen", side_effect=start_then_interrupt):
            with self.assertRaises(SystemExit) as cancelled:
                check_shaders.run_probe("unused")
        self.assertEqual(cancelled.exception.code, 128 + signal.SIGTERM)
        self.assertEqual(signal.getsignal(signal.SIGTERM), before)
        self.assertEqual(len(children), 1)
        self.assertIsNotNone(children[0].returncode)
        self.assertFalse(self.alive(children[0].pid))

    def test_timeout_kills_group_after_wrapper_already_exited(self):
        # The wrapper exits immediately, but its child holds stdout open.
        # Looking up the group through getpgid(wrapper_pid) can no longer work
        # once Popen has reaped that wrapper; its original PID remains the PGID.
        command = [sys.executable, "-c", self.probe_source(wrapper_exits=True)]
        self.addCleanup(self.clean_fixture)
        with patch.object(check_shaders, "probe_command", return_value=(command, "test")), \
                patch.object(check_shaders, "TIMEOUT_S", 0.5):
            output, status = check_shaders.run_probe("unused")
        self.assertEqual(status, -1)
        self.assertIn("probe started", output)
        self.assertIn("timed out after 0.5s", output)
        self.assert_probe_stopped()

    def test_sigterm_and_keyboard_interrupt_clean_detached_children(self):
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum):
                self.ready.unlink(missing_ok=True)
                checker = subprocess.Popen([sys.executable, "-c", self.checker_source()],
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           text=True, start_new_session=True)
                self.addCleanup(self.clean_fixture, checker)
                deadline = time.monotonic() + 5
                while not self.ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(self.ready.exists(), "fixture did not become ready")
                checker.send_signal(signum)
                output, _ = checker.communicate(timeout=5)
                self.assertNotEqual(checker.returncode, 0)
                self.assertIn("probe started", output, "cancelled probe lost its partial output")
                self.assert_probe_stopped()

    def test_verifier_timeout_reaches_detached_shader_group(self):
        self.addCleanup(self.clean_fixture)
        stage = Stage("shader-timeout", [sys.executable, "-c", self.checker_source()],
                      timeout=0.5)
        result = run_stage(stage, self.directory, dict(os.environ))
        self.assertFalse(result["passed"])
        self.assertIn("timed out after 0.5s", result["issues"])
        self.assertIn("probe started", Path(result["log"]).read_text())
        self.assert_probe_stopped()


if __name__ == "__main__":
    unittest.main()
