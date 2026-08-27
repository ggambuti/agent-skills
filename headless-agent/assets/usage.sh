#!/bin/sh
# usage.sh — token/quota consumption report for the headless agent.
# Aggregates the per-cycle result JSONs the loop already writes to
# <repo>/logs/ into a per-day table: cycles, tokens (in/out/cache-read),
# notional cost, and commits produced.
#
# Usage: usage.sh /path/to/repo [branch]
# Notes:
# * total_cost_usd is CUMULATIVE per cycle across all steps, including
#   subagent (haiku/sonnet/opus) calls — on a subscription you do not
#   pay it, but it is the best single proxy for quota consumption.
# * Failed cycles (rate limit, outage) leave empty/invalid JSONs; they
#   are counted separately, not silently dropped.
# * For time-of-day views across ALL Claude Code activity on the
#   machine, `npx ccusage@latest daily` reads the same transcripts.

REPO="${1:?usage: usage.sh /path/to/repo [branch]}"
BRANCH="${2:-agent-work}"

python3 - "$REPO" "$BRANCH" <<'PYEOF'
import glob, json, os, re, subprocess, sys

repo, branch = sys.argv[1], sys.argv[2]
logdir = os.path.join(repo, "logs")

days = {}   # day -> dict of counters
models = {} # model -> dict of counters (from modelUsage, when present)
failed = 0

def day_of(path):
    # filenames: cycle-<n>-YYYYMMDD-HHMMSS.json
    m = re.search(r"(\d{8})-\d{6}\.json$", os.path.basename(path))
    if m:
        d = m.group(1)
        return "%s-%s-%s" % (d[0:4], d[4:6], d[6:8])
    return "unknown"

for f in sorted(glob.glob(os.path.join(logdir, "cycle-*.json"))):
    d = days.setdefault(day_of(f), dict(cycles=0, fail=0, inp=0, out=0,
                                        cache=0, cost=0.0))
    try:
        obj = json.load(open(f))
        u = obj.get("usage") or {}
        d["cycles"] += 1
        d["inp"]   += u.get("input_tokens", 0) or 0
        d["out"]   += u.get("output_tokens", 0) or 0
        d["cache"] += u.get("cache_read_input_tokens", 0) or 0
        d["cost"]  += obj.get("total_cost_usd", 0.0) or 0.0
        for name, mu in (obj.get("modelUsage") or {}).items():
            m = models.setdefault(name, dict(inp=0, out=0, cost=0.0))
            m["inp"]  += mu.get("inputTokens", mu.get("input_tokens", 0)) or 0
            m["out"]  += mu.get("outputTokens", mu.get("output_tokens", 0)) or 0
            m["cost"] += mu.get("costUSD", mu.get("cost_usd", 0.0)) or 0.0
    except (ValueError, OSError):
        d["fail"] += 1
        failed += 1

# commits per day on the work branch
commits = {}
try:
    out = subprocess.run(
        ["git", "-C", repo, "log", "--date=short", "--pretty=%ad", branch],
        capture_output=True, text=True, check=True).stdout
    for line in out.split():
        commits[line] = commits.get(line, 0) + 1
except subprocess.CalledProcessError:
    pass

hdr = ("day", "cycles", "failed", "commits", "tok_in", "tok_out",
       "cache_read", "cost_usd")
rows = []
tot = dict(cycles=0, fail=0, inp=0, out=0, cache=0, cost=0.0, com=0)
for day in sorted(days):
    d = days[day]
    c = commits.get(day, 0)
    rows.append((day, d["cycles"], d["fail"], c, d["inp"], d["out"],
                 d["cache"], "%.2f" % d["cost"]))
    tot["cycles"] += d["cycles"]; tot["fail"] += d["fail"]
    tot["inp"] += d["inp"]; tot["out"] += d["out"]
    tot["cache"] += d["cache"]; tot["cost"] += d["cost"]; tot["com"] += c
rows.append(("TOTAL", tot["cycles"], tot["fail"], tot["com"], tot["inp"],
             tot["out"], tot["cache"], "%.2f" % tot["cost"]))

widths = [max(len(str(r[i])) for r in rows + [hdr]) for i in range(len(hdr))]
fmt = "  ".join("%%%ds" % w for w in widths)
print(fmt % hdr)
print(fmt % tuple("-" * w for w in widths))
for r in rows:
    print(fmt % r)

if models:
    print("\nPer-model breakdown (which models actually ran):")
    for name in sorted(models):
        m = models[name]
        print("  %-40s in=%-10d out=%-10d cost=%.2f"
              % (name, m["inp"], m["out"], m["cost"]))

if not days:
    print("\nno cycle logs found in %s (has the loop run yet?)" % logdir)
elif failed:
    print("\n%d cycle(s) had no parseable result (rate limit/outage/crash)"
          "\n— normal during quota waits; see logs/*.err for details." % failed)
print("\nNote: cost_usd is a notional quota proxy on subscriptions"
      " (includes subagent calls).")
PYEOF
