#!/usr/bin/env python3
"""status.py team.toml EVENT... [--md]

Keeps <handoff_dir>/status.json and prints the roster card (HTML for the
inline widget tool; --md for a markdown table). Events:

  init                     roster from the toml, everyone idle
  spawn NAME               NAME active ("spawned"); a twin NAME-2 gets its own row
  msg NAME NOTE...         NAME active with a note, e.g. msg sam working 2.1
  stop NAME TOKENS [NOTE]  NAME idle; TOKENS = cumulative figure from its completion notification
  handoff NAME TWIN        NAME handed off, TWIN active ("reading handoff")
  done NAME                NAME finished for the run
  gate G1 passed|failed    header
  stage N                  header
  show                     print only
"""
import json
import sys
import tomllib
from pathlib import Path

DOT = {"active": "var(--fill-success)", "idle": "var(--border-strong)", "handoff": "var(--fill-warning)",
       "done": "var(--border-strong)", "pi": "var(--fill-accent)"}


def fmt(n):
    return f"{n/1e6:.1f}M" if n >= 1e6 else f"{n//1000}k" if n >= 1000 else str(n)


def stages(r):
    s = r.get("stages")
    if not s:
        return "all"
    return f"{s[0]}–{s[-1]}" if len(s) > 2 and s == list(range(s[0], s[-1] + 1)) else ", ".join(map(str, s))


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    md = "--md" in argv
    argv = [a for a in argv if a != "--md"]
    toml_path = Path(argv[0]).resolve()
    spec = tomllib.loads(toml_path.read_text())
    workdir = Path(spec["workdir"])
    if not workdir.is_absolute():
        workdir = (toml_path.parent / workdir).resolve()
    hd = spec.get("handoff_dir", ".claude/handoffs")
    state_path = (Path(hd) if Path(hd).is_absolute() else workdir / hd) / "status.json"
    ev, args = (argv[1], argv[2:]) if len(argv) > 1 else ("show", [])

    if ev == "init" or not state_path.exists():
        state = {"title": spec.get("goal", "fellowship"), "stage": None, "gate": "", "agents": {}}
        for r in spec["roles"]:
            kind = r["kind"]
            state["agents"][r["name"]] = {"kind": kind, "model": r["model"], "stages": stages(r),
                                         "status": "pi" if kind == "pi" else "idle",
                                         "note": "PI" if kind == "pi" else "not spawned", "tokens": 0}
    else:
        state = json.loads(state_path.read_text())
    ag = state["agents"]

    def row(name):
        if name not in ag:  # twin: inherit from base name
            base = ag[name.rsplit("-", 1)[0]]
            ag[name] = {**base, "status": "idle", "note": "", "tokens": 0}
        return ag[name]

    if ev == "spawn":
        row(args[0]).update(status="active", note="spawned")
    elif ev == "msg":
        row(args[0]).update(status="active", note=" ".join(args[1:]))
    elif ev == "stop":
        row(args[0]).update(status="idle", tokens=int(args[1]), note=" ".join(args[2:]) or "idle")
    elif ev == "handoff":
        row(args[0]).update(status="handoff", note=f"handed off → {args[1]}")
        row(args[1]).update(status="active", note="reading handoff")
    elif ev == "done":
        row(args[0]).update(status="done", note="done")
    elif ev == "gate":
        state["gate"] = f"gate {args[0]} {args[1]}"
    elif ev == "stage":
        state["stage"] = int(args[0])
    elif ev not in ("init", "show"):
        print(__doc__, file=sys.stderr)
        return 1
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state, indent=1))

    total = fmt(sum(a["tokens"] for a in ag.values()))
    head = " · ".join(x for x in [f"stage {state['stage']}" if state["stage"] is not None else "", state["gate"], f"{total} tokens"] if x)
    if md:
        print(f"**{state['title']}** — {head}\n\n| agent | model | stages | status | tokens |\n|---|---|---|---|---:|")
        for n, a in ag.items():
            print(f"| {n} | {a['model']} | {a['stages']} | {a['note']} | {fmt(a['tokens'])} |")
        return 0
    dim = 'color:var(--text-muted);'
    rows = "".join(
        f'<tr style="border-top:0.5px solid var(--border);{dim if a["status"] in ("done", "handoff") else ""}">'
        f'<td style="padding:6px 0;"><span style="display:inline-block;width:8px;height:8px;border-radius:50%;'
        f'background:{DOT[a["status"]]};margin-right:8px;"></span>{n}</td><td>{a["model"]}</td><td>{a["stages"]}</td>'
        f'<td>{a["note"]}</td><td style="text-align:right;">{fmt(a["tokens"])}</td></tr>' for n, a in ag.items())
    print(f'<h2 class="sr-only">Fellowship roster: {len(ag)} agents, {head}.</h2>'
          f'<div style="background:var(--surface-2);border:0.5px solid var(--border);border-radius:12px;padding:1rem 1.25rem;">'
          f'<div style="display:flex;justify-content:space-between;align-items:baseline;margin-bottom:12px;">'
          f'<span style="font-size:15px;font-weight:500;">{state["title"]}</span>'
          f'<span style="font-size:13px;color:var(--text-secondary);">{head}</span></div>'
          f'<table style="width:100%;font-size:13px;border-collapse:collapse;table-layout:fixed;">'
          f'<tr style="color:var(--text-secondary);"><td style="padding:4px 0;width:130px;">agent</td><td style="width:70px;">model</td>'
          f'<td style="width:60px;">stages</td><td>status</td><td style="text-align:right;width:70px;">tokens</td></tr>{rows}</table></div>')
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
