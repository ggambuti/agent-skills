#!/usr/bin/env python3
"""Self-check: render the example, assert prompts are complete, and bad specs fail."""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
EX = HERE.parent / "example"


def run(toml, out):
    return subprocess.run([sys.executable, HERE / "render.py", toml, "--out", out], capture_output=True, text=True)


with tempfile.TemporaryDirectory() as tmp:
    r = run(EX / "team.toml", tmp)
    assert r.returncode == 0, r.stderr
    prompts = sorted(p.name for p in Path(tmp).iterdir())
    assert prompts == ["aragorn.md", "frodo.md", "sam.md"], prompts
    for p in Path(tmp).iterdir():
        t = p.read_text()
        assert not re.search(r"\{[a-z_]+\}", t), f"unfilled placeholder in {p.name}"
        assert "Co-Authored-By" in t and "| G0 |" in t and "pkill" in t, p.name  # constraints, gates, notes carried
        committed = EX / "handoffs" / "prompts" / p.name
        assert committed.read_text() == t, f"{committed} stale: run render.py example/team.toml"
    frodo = (Path(tmp) / "frodo.md").read_text()
    assert "500000 tokens" in frodo and "`aragorn`" in frodo and "- pkg/" in frodo
    sam = (Path(tmp) / "sam.md").read_text()
    assert "100000 tokens" in sam  # haiku: 200k window, handoff at 0.5
    files = subprocess.run([sys.executable, HERE / "render.py", "--files", EX / "plan.md"], capture_output=True, text=True).stdout
    assert "stage 1:\n  README.md\n  app/middleware.py" in files, files
    assert "| gandalf | pi |" in r.stdout and "| sam | worker | haiku |" in r.stdout

    src = (EX / "team.toml").read_text()
    bad = {
        "two pis": src.replace('name = "aragorn"\nkind = "lead"', 'name = "aragorn"\nkind = "pi"'),
        "overlapping areas": src.replace('areas = ["benchmarks/", "README.md"]', 'areas = ["pkg/limiter.py"]'),
        "bad model": src.replace('model = "haiku"', 'model = "gpt"'),
        "uncovered file": src.replace('areas = ["pkg/", "app/", "tests/"]', 'areas = ["pkg/", "tests/"]'),
        "uncovered stage": src.replace("stages = [0, 1]\nareas = [\"pkg/", "stages = [0]\nareas = [\"pkg/").replace(
            'stages = [0, 1]\nareas = ["benchmarks/', 'stages = [0]\nareas = ["benchmarks/'),
    }
    for label, text in bad.items():
        p = Path(tmp) / "bad.toml"
        p.write_text(text.replace('workdir = "."', f'workdir = "{EX}"'))
        r = run(p, tmp)
        assert r.returncode == 1 and "error:" in r.stderr, (label, r.stdout, r.stderr)
print("test_render: ok")
