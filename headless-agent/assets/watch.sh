#!/bin/sh
# watch.sh — live pretty-tail of the agent's current cycle transcript.
# Usage: watch.sh /path/to/repo [exclude-substring]
# Read-only and Ctrl-C safe: the running agent is unaffected.
#
# Traps encoded here (learned from a real deployment):
# * The Python is fed via a heredoc, NOT an embedded quoted shell
#   string — quotes inside it can then never splice the shell command
#   (single-quoted embedding turns inner apostrophes into silent
#   NameErrors), and no same-quote nested f-strings are used (system
#   python3 may predate 3.12).
# * Pass the setup session's transcript id as the exclude-substring if
#   the watcher tails your interactive conversation instead of the
#   agent's.
# * The LOOP's status lines (cycle starts, backoffs, stuck counter) go
#   to stdout — launchd.out.log or journalctl — not here. This shows
#   the INNER agent's work. Durable views: PROGRESS.md,
#   `git log <base>..<branch>`, and `claude --resume` in the repo to
#   replay a finished cycle read-only.

REPO="${1:?usage: watch.sh /path/to/repo [exclude-substring]}"
EXCLUDE="${2:-}"

# exec: replace this shell with python so there is exactly ONE process.
# Without exec, Ctrl-C can kill the sh wrapper while the heredoc-fed
# python child survives and keeps writing to the terminal (seen in the
# wild; guaranteed over `ssh host watch.sh ...` without a tty, where
# Ctrl-C only kills the local ssh client). One process = one Ctrl-C.
# For remote live watching use:  ssh -t host /path/to/watch.sh <repo>
exec python3 - "$REPO" "$EXCLUDE" <<'PYEOF'
import glob, json, os, sys, time

repo, exclude = sys.argv[1], sys.argv[2]
base = os.path.join(os.path.expanduser("~"), ".claude", "projects")

# Claude Code stores transcripts in a per-project directory derived from
# the repo path. Derive the slug; fall back to the newest project dir.
slug = "".join(c if c.isalnum() else "-" for c in repo).lower().strip("-")
dirs = [d for d in glob.glob(os.path.join(base, "*")) if os.path.isdir(d)]
proj = None
for d in dirs:
    if os.path.basename(d).lower().strip("-") == slug:
        proj = d
        break
if proj is None and dirs:
    proj = max(dirs, key=os.path.getmtime)
if proj is None:
    sys.exit("no transcript directory found under " + base)

def newest():
    fs = [f for f in glob.glob(os.path.join(proj, "*.jsonl"))
          if not (exclude and exclude in os.path.basename(f))]
    return max(fs, key=os.path.getmtime) if fs else None

def render(line):
    try:
        obj = json.loads(line)
    except ValueError:
        return
    msg = obj.get("message") or {}
    content = msg.get("content")
    if not isinstance(content, list):
        return
    for b in content:
        if not isinstance(b, dict):
            continue
        t = b.get("type")
        if t == "text" and msg.get("role") == "assistant":
            txt = (b.get("text") or "").strip()
            if txt:
                print("\n" + txt)
        elif t == "tool_use":
            inp = b.get("input") or {}
            detail = inp.get("command") or inp.get("file_path") or ""
            print("  [%s] %s" % (b.get("name"), str(detail)[:160]))
        elif t == "tool_result":
            c = b.get("content")
            s = c if isinstance(c, str) else json.dumps(c, default=str)
            print("    -> %s" % str(s)[:200])

cur, pos = None, 0
print("watching %s  (Ctrl-C to quit; the agent is unaffected)" % proj)
try:
    while True:
        f = newest()
        if f != cur:                 # hop when a new cycle starts
            cur, pos = f, 0
            name = os.path.basename(cur) if cur else "waiting for transcript..."
            print("\n=== %s ===" % name)
        if cur:
            with open(cur, "r") as fh:
                fh.seek(pos)
                for line in fh:
                    render(line)
                pos = fh.tell()
        time.sleep(2)
except KeyboardInterrupt:
    print("\nwatch stopped (the agent keeps running).")
    sys.exit(0)
PYEOF
