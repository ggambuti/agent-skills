#!/usr/bin/env python3
"""render.py team.toml [--out DIR]
render.py --files plan.md

Validates a fellowship team spec, prints the team table, and writes one
self-contained prompt file per spawned role to <handoff_dir>/prompts/<name>.md
(or --out DIR). Exit 1 on validation errors. Stdlib only.
--files lists every path named in the plan's **Files:** blocks, per stage, so the
PI can write worker areas from real paths without reading the plan.
"""
import fnmatch
import re
import sys
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATES = HERE.parent / "templates"

# ponytail: update when models change
CONTEXT = {"fable": 1_000_000, "opus": 1_000_000, "sonnet": 1_000_000, "haiku": 200_000}
REPORT = {"pi": 10, "lead": 15, "worker": 12}
POOLS = {
    "pi": ["gandalf", "galadriel", "sauron"],
    "lead": ["aragorn", "legolas", "gimli", "boromir", "faramir", "eomer"],
    "worker": ["frodo", "sam", "merry", "pippin", "bilbo", "thorin", "balin", "dwalin", "fili", "kili",
               "dori", "nori", "ori", "oin", "gloin", "bifur", "bofur", "bombur"],
}


def section(text, heading):
    """Body of '## heading' up to the next '## '."""
    m = re.search(rf"^## {re.escape(heading)}\s*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    return m.group(1).strip() if m else None


def plan_files(plan):
    """{stage: {path, ...}} from every '**Files:**' block under each '## Stage N'."""
    out, stage = {}, None
    for line in plan.splitlines():
        m = re.match(r"^## Stage (\d+)", line)
        if m:
            stage = int(m.group(1))
            out.setdefault(stage, set())
        elif stage is not None:
            m = re.match(r"^- (?:Create|Modify|Test|Delete|Read)[^:]*: `([^`]+)`", line)
            if m:
                out[stage].add(m.group(1))
    return out


def covers(area, path):
    a = area.rstrip("/")
    return fnmatch.fnmatch(path, area) or path == a or path.startswith(a + "/")


def area_prefix(a):
    return a.split("*", 1)[0].rstrip("/")


def overlap(a, b):
    a, b = area_prefix(a), area_prefix(b)
    return a == b or a.startswith(b + "/") or b.startswith(a + "/") or not a or not b


class Strict(dict):
    def __missing__(self, k):
        raise KeyError(f"unfilled placeholder {{{k}}}")


def bullets(items):
    return "\n".join(f"- {x}" for x in items) if items else "- none"


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--files":
        for stage, files in sorted(plan_files(Path(argv[1]).read_text()).items()):
            print(f"stage {stage}:")
            for f in sorted(files):
                print(f"  {f}")
        return 0
    toml_path = Path(argv[0]).resolve()
    out = Path(argv[argv.index("--out") + 1]) if "--out" in argv else None
    spec = tomllib.loads(toml_path.read_text())
    errors, warnings = [], []

    workdir = Path(spec["workdir"])
    if not workdir.is_absolute():
        workdir = (toml_path.parent / workdir).resolve()
    plan_path = workdir / spec["plan"]
    if not plan_path.exists():
        return die([f"plan not found: {plan_path}"])
    plan = plan_path.read_text()
    plan_stages = sorted({int(s) for s in re.findall(r"^## Stage (\d+)", plan, re.M)})
    gc, gates = section(plan, "Global Constraints"), section(plan, "Stage gates")
    if gc is None:
        errors.append("plan lacks '## Global Constraints'")
    if gates is None:
        errors.append("plan lacks '## Stage gates'")
    if not plan_stages:
        errors.append("plan has no '## Stage N' headings")
    if not re.search(r"^### Task .*\n(?:.*\n)*?- \[[ x]\]", plan, re.M):
        errors.append("plan has no '### Task' with checkbox steps")

    roles = spec.get("roles", [])
    names = [r["name"] for r in roles]
    if len(set(names)) != len(names):
        errors.append("duplicate role names")
    by_kind = {k: [r for r in roles if r.get("kind") == k] for k in ("pi", "lead", "worker")}
    if len(by_kind["pi"]) != 1:
        errors.append("exactly one role must have kind = 'pi'")
    if not by_kind["lead"]:
        errors.append("at least one lead required")
    for r in roles:
        if r.get("kind") not in POOLS:
            errors.append(f"{r['name']}: kind must be pi|lead|worker")
            continue
        if r.get("model") not in CONTEXT:
            errors.append(f"{r['name']}: model must be one of {sorted(CONTEXT)}")
        if r["name"] not in POOLS[r["kind"]]:
            warnings.append(f"{r['name']}: not in the {r['kind']} name pool {POOLS[r['kind']]}")
        r.setdefault("report_limit", REPORT[r["kind"]])
        r.setdefault("context_window", CONTEXT.get(r.get("model"), 1_000_000))
        r.setdefault("handoff_at", 0.5)
        r.setdefault("handoff_tasks", 6)
        r.setdefault("purpose", "")
        r.setdefault("stages", plan_stages)
    if errors:
        return die(errors)

    pi = by_kind["pi"][0]
    leads, workers = by_kind["lead"], by_kind["worker"]
    if len(leads) == 1:
        for w in workers:
            w.setdefault("lead", leads[0]["name"])
    owned = [s for l in leads for s in l["stages"]]
    if sorted(owned) != sorted(set(owned)):
        errors.append("two leads own the same stage")
    for s in plan_stages:
        if s not in owned:
            errors.append(f"stage {s} owned by no lead")
        if not any(s in w["stages"] for w in workers):
            errors.append(f"stage {s} covered by no worker")
    lead_names = {l["name"]: l for l in leads}
    for w in workers:
        if not w.get("areas"):
            errors.append(f"{w['name']}: worker needs areas")
        if w.get("lead") not in lead_names:
            errors.append(f"{w['name']}: lead '{w.get('lead')}' unknown")
        elif not set(w["stages"]) <= set(lead_names[w["lead"]]["stages"]):
            errors.append(f"{w['name']}: stages {w['stages']} not within lead {w['lead']}'s {lead_names[w['lead']]['stages']}")
    for stage, files in plan_files(plan).items():
        for f in sorted(files):
            if not any(stage in w["stages"] and any(covers(a, f) for a in w.get("areas", [])) for w in workers):
                errors.append(f"stage {stage} file {f} covered by no worker")
    for i, a in enumerate(workers):
        for b in workers[i + 1:]:
            if set(a["stages"]) & set(b["stages"]):
                for x in a.get("areas", []):
                    for y in b.get("areas", []):
                        if overlap(x, y):
                            errors.append(f"{a['name']} and {b['name']} share stages and overlapping areas: {x} / {y}")
    if errors:
        return die(errors)

    handoff_dir = spec.get("handoff_dir", ".claude/handoffs")
    handoff_abs = Path(handoff_dir) if Path(handoff_dir).is_absolute() else workdir / handoff_dir
    out = out or handoff_abs / "prompts"
    common_t = (TEMPLATES / "common.md").read_text()
    base = dict(
        pi=pi["name"], goal=spec.get("goal", ""), workdir=str(workdir), branch=spec.get("branch", ""),
        plan=spec["plan"], spec=spec.get("spec", "none"), concurrency=spec.get("concurrency", 2),
        handoff_dir=str(handoff_abs), global_constraints=gc, stage_gates=gates,
        escalation=bullets(spec.get("escalation", [])), notes=spec.get("notes", "").strip() or "none",
    )
    out.mkdir(parents=True, exist_ok=True)
    for r in leads + workers:
        v = Strict(base, **r)
        v["stages"] = ", ".join(map(str, r["stages"]))
        v["handoff_tokens"] = int(r["handoff_at"] * r["context_window"])
        if r["kind"] == "lead":
            mine = [w for w in workers if w["lead"] == r["name"]]
            v["workers"] = "| name | model | stages | areas |\n|---|---|---|---|\n" + "\n".join(
                f"| {w['name']} | {w['model']} | {', '.join(map(str, w['stages']))} | {', '.join(w['areas'])} |" for w in mine)
            v["counterparts"] = f"`{pi['name']}` and every worker of yours"
        else:
            v["areas"] = bullets(r["areas"])
            v["counterparts"] = f"`{r['lead']}` and `{pi['name']}`"
        v["common"] = common_t.format_map(v)
        text = (TEMPLATES / f"{r['kind']}.md").read_text().format_map(v)
        (out / f"{r['name']}.md").write_text(text)

    print("| name | kind | model | stages | lead | areas / purpose |\n|---|---|---|---|---|---|")
    for r in [pi] + leads + workers:
        detail = ", ".join(r.get("areas", [])) or r["purpose"]
        print(f"| {r['name']} | {r['kind']} | {r['model']} | {', '.join(map(str, r['stages']))} | {r.get('lead', '')} | {detail} |")
    print(f"\nconcurrency {spec.get('concurrency', 2)}; handoff at {[(r['name'], int(r['handoff_at']*r['context_window'])) for r in leads + workers]}")
    print(f"prompts written to {out}")
    for w in warnings:
        print("warning:", w, file=sys.stderr)
    return 0


def die(errors):
    for e in errors:
        print("error:", e, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
