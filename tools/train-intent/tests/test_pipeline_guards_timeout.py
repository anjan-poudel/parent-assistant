"""Guard-timeout regression — the 2026-09-18 GPU-wedge hang.

`subprocess.run(cmd, timeout=...)` is not an escape hatch: on expiry CPython
calls `process.kill()` and then `process.wait()`, and that wait never returns
when the child is stuck in uninterruptible D-state. Live on the training box a
probe watcher stayed pinned inside gpu_snapshot()'s nvidia-smi call for the
whole driver wedge, because the guard could not exit.

These tests pin what the fix must keep:
  - gpu_snapshot()'s return shapes on success and on failure (unchanged);
  - a timed-out probe returns promptly *and* takes the probe's own children
    with it (process-group kill), which is what makes the timeout honest.

D-state itself cannot be staged from userspace (SIGKILL works fine on a healthy
kernel), so the timeout case uses a shim that spawns a background child and then
hangs: that background child outliving the kill is exactly the pre-fix failure.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from pipeline_guards import gpu_snapshot  # noqa: E402


def write_shim(directory: Path, script: str) -> Path:
    """Drop a fake `nvidia-smi` in `directory` — PATH order decides who wins."""
    p = directory / "nvidia-smi"
    p.write_text(script, encoding="utf-8")
    p.chmod(0o755)
    return p


def wait_for(predicate, limit: float = 10.0) -> bool:
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def path_with(directory: Path) -> dict:
    return {"PATH": f"{directory}{os.pathsep}{os.environ['PATH']}"}


class GpuSnapshotContract(unittest.TestCase):
    """The success/failure shapes callers already rely on."""

    def test_success_shape_is_unchanged(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            write_shim(d, "#!/bin/sh\necho '1234, 512'\necho '5678, 128'\n")
            with mock.patch.dict(os.environ, path_with(d)):
                snap = gpu_snapshot()
        self.assertEqual(snap, {"available": True,
                                "processes": [{"pid": 1234, "used_mib": 512},
                                              {"pid": 5678, "used_mib": 128}],
                                "resident_mib": 640})

    def test_missing_binary_keeps_the_sentinel(self):
        with tempfile.TemporaryDirectory() as td:
            with mock.patch.dict(os.environ, {"PATH": td}):
                snap = gpu_snapshot()
        self.assertFalse(snap["available"])
        self.assertIn("FileNotFoundError", snap["reason"])


class GpuSnapshotTimeout(unittest.TestCase):
    """A stuck probe must return the sentinel, promptly, with no survivors."""

    def test_timeout_returns_and_kills_the_whole_group(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            pidfile = d / "pids"
            write_shim(d, "#!/bin/sh\n"
                          "sleep 300 &\n"
                          f'echo "$$ $!" > "{pidfile}"\n'
                          "sleep 300\n")
            with mock.patch.dict(os.environ, path_with(d)):
                # Warm the exec path first: under a sandboxed runner the very
                # first spawn of the process can take seconds to reach the
                # script (observed 1.7s here, 30ms after), which would starve a
                # short timeout before the shim ever wrote its pids. The
                # property under test is "returns without blocking forever",
                # not the exact timeout figure.
                subprocess.run(["/bin/sh", "-c", "true"])
                t0 = time.monotonic()
                snap = gpu_snapshot(timeout=3)
                elapsed = time.monotonic() - t0

            self.assertFalse(snap["available"])
            self.assertIn("TimeoutExpired", snap["reason"])
            self.assertLess(elapsed, 15.0, "guard blocked on a stuck probe")

            self.assertTrue(wait_for(pidfile.exists, 5.0), "shim never started")
            shim_pid, child_pid = (int(x) for x in pidfile.read_text().split())
            self.assertTrue(wait_for(lambda: not pid_alive(shim_pid), 5.0),
                            "the timed-out probe survived")
            self.assertTrue(wait_for(lambda: not pid_alive(child_pid), 5.0),
                            "a child of the timed-out probe survived — "
                            "the process group was not killed")


if __name__ == "__main__":
    unittest.main()
