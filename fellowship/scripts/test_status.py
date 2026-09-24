#!/usr/bin/env python3
"""Self-check for status.py: a short run's events produce the right card."""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
EX = HERE.parent / "example"

with tempfile.TemporaryDirectory() as tmp:
    toml = Path(tmp) / "team.toml"
    toml.write_text((EX / "team.toml").read_text().replace('workdir = "."', f'workdir = "{EX}"').replace(
        'handoff_dir = "handoffs"', f'handoff_dir = "{tmp}"'))

    def ev(*args):
        r = subprocess.run([sys.executable, HERE / "status.py", toml, *args], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        return r.stdout

    out = ev("init")
    assert "gandalf" in out and "not spawned" in out and "0 tokens" in out
    ev("spawn", "aragorn"); ev("spawn", "frodo"); ev("stage", "0")
    ev("msg", "frodo", "working", "0.1")
    out = ev("stop", "frodo", "48000", "0.1 committed")
    assert "48k" in out and "0.1 committed" in out and "stage 0" in out
    ev("gate", "G0", "passed")
    out = ev("handoff", "frodo", "frodo-2")
    assert "handed off → frodo-2" in out and "reading handoff" in out and "gate G0 passed" in out
    state = json.loads((Path(tmp) / "status.json").read_text())
    assert state["agents"]["frodo-2"]["model"] == "sonnet" and state["agents"]["frodo"]["status"] == "handoff"
    md = ev("show", "--md")
    assert md.startswith("**") and "| frodo-2 | sonnet |" in md and "48k" in md
    assert subprocess.run([sys.executable, HERE / "status.py", toml, "bogus"], capture_output=True).returncode == 1
print("test_status: ok")
