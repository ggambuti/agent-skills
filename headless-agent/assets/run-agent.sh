#!/usr/bin/env bash
# run-agent.sh — perpetual unattended Claude Code loop.
#
# DESIGN CONTRACT (do not weaken when customizing):
#   1. The loop NEVER decides to stop. It exits only when the USER stops it:
#      a STOP file in the repo root, SIGTERM/SIGINT, or stopping the service.
#   2. Every cycle is a fresh `claude -p` invocation; all state lives in the
#      repo, so any crash/outage/limit costs nothing but time.
#   3. Failures (rate limits — 5-hour or weekly — outages, crashes) are
#      retried FOREVER with capped backoff. A quota that resets in 3 days
#      is just 3 days of periodic polling.
#   4. Reaching the goal is not a stop condition: the agent switches to a
#      HARDENING phase (edge cases, cleanup, cross-checks, reports) and
#      keeps going until the user returns.
#
# Usage:  ./run-agent.sh /path/to/repo [branch]
# Stop:   touch STOP in the repo   (or systemctl --user stop claude-agent)

set -u

# ---------------- configuration ----------------
REPO="${1:?usage: run-agent.sh /path/to/repo [branch] [model]}"
BRANCH="${2:-agent-work}"        # local work branch; never pushed
MODEL="${3:-sonnet}"             # ORCHESTRATOR model (alias or full id).
                                 # The orchestrator routes, commits, and
                                 # delegates; heavy reasoning goes to
                                 # subagents (tiered in the prompt), so a
                                 # mid-tier default is deliberate.
MAX_TURNS=50                     # per-cycle cap
SLEEP_OK=60                      # pause between successful cycles (s)
SLEEP_FAIL=900                   # first pause after a failed cycle (s)
SLEEP_FAIL_MAX=14400             # backoff ceiling: 4 h between polls,
                                 # held indefinitely (rides out multi-day
                                 # weekly-quota exhaustion)
STUCK_SOFT=5                     # no-commit successful cycles before the
                                 # loop injects an "unstick" instruction.
                                 # NON-FATAL: the loop never halts itself.
SERVICE_NAME="claude-agent"      # systemd unit name (for the operator card)
VERIFY_CMD="make check"          # verification gate (for the operator card;
                                 # the binding definition stays in GOAL.md)
KIT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$KIT_DIR/HANDOVER.template.md"

# Headless auth: source a chmod-600 env file written BY THE USER (never
# by an agent), containing: export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
# This is the reliable route under launchd/systemd (the macOS keychain
# is not); install.sh gates installation on this actually working.
[ -f "$KIT_DIR/env.sh" ] && . "$KIT_DIR/env.sh"
ALLOWED_TOOLS='Task,Read,Edit,Write,Grep,Glob,Bash(git *),Bash(make *),Bash(python3 *),Bash(pytest *),Bash(timeout *)'
# ------------------------------------------------

cd "$REPO" || exit 1
mkdir -p logs
LOGDIR="$REPO/logs"

# Keep loop-internal files out of git so WIP checkpoints capture only
# real work (uses .git/info/exclude to avoid touching tracked files):
for pat in logs/ STOP PHASE HANDOVER.md; do
  grep -qxF "$pat" .git/info/exclude 2>/dev/null || echo "$pat" >> .git/info/exclude
done

git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || git branch "$BRANCH"
git checkout -q "$BRANCH"

[ -f PROGRESS.md ]  || printf '# Progress log\n\n' > PROGRESS.md
[ -f BLOCKED.md ]   || printf '# Blocked items\n\n' > BLOCKED.md
[ -f ATTENTION.md ] || printf '# Items needing human attention\n\n' > ATTENTION.md
[ -f PHASE ]        || printf 'BUILDING\n' > PHASE

# ---- platform-specific operator commands (for the card and journal) ----
if [ "$(uname)" = "Darwin" ]; then
  SVC_LABEL="com.$(id -un).claude-agent"
  STATUS_CMD="launchctl print gui/\$(id -u)/$SVC_LABEL | grep -E 'state|pid'"
  STOP_NOW_CMD="launchctl bootout gui/\$(id -u)/$SVC_LABEL"
  LOG_TAIL_CMD="tail -f $KIT_DIR/launchd.out.log"
  RESTART_CMD="rm -f $REPO/STOP && $KIT_DIR/install.sh $REPO $BRANCH $MODEL"
else
  STATUS_CMD="systemctl --user status $SERVICE_NAME | head -5"
  STOP_NOW_CMD="systemctl --user stop $SERVICE_NAME"
  LOG_TAIL_CMD="journalctl --user -u $SERVICE_NAME -f"
  RESTART_CMD="rm -f $REPO/STOP && systemctl --user start $SERVICE_NAME"
fi

# ---- operator card: regenerated at EVERY launch so it is always correct ----
# Deterministic substitution from the template; never hand-edited, never
# invented. If HANDOVER.md needs different wording, edit the template.
if [ -f "$TEMPLATE" ]; then
  H_REPO_PATH="$REPO" H_BRANCH="$BRANCH" H_SERVICE_NAME="$SERVICE_NAME" \
  H_HOSTNAME="$(hostname)" H_VERIFY_CMD="$VERIFY_CMD" H_KIT_DIR="$KIT_DIR" \
  H_MODEL="$MODEL" \
  H_GENERATED_AT="$(date)" H_STATUS_CMD="$STATUS_CMD" \
  H_STOP_NOW_CMD="$STOP_NOW_CMD" H_LOG_TAIL_CMD="$LOG_TAIL_CMD" \
  H_RESTART_CMD="$RESTART_CMD" \
  python3 - "$TEMPLATE" > HANDOVER.md <<'PYSUB'
import os, re, sys
t = open(sys.argv[1]).read()
t = re.sub(r"(?s)<!--.*?-->\n?", "", t)
for k, v in os.environ.items():
    if k.startswith("H_"):
        t = t.replace("{" + k[2:] + "}", v)
print(t, end="")
PYSUB
  echo "[agent] operator card regenerated: $REPO/HANDOVER.md"
else
  echo "[agent] WARNING: $TEMPLATE not found; HANDOVER.md not regenerated." >&2
fi

# Stable operator summary in the journal at every launch:
echo "[agent] check progress:  cat $REPO/PHASE ; tail -30 $REPO/PROGRESS.md ; cat $REPO/ATTENTION.md"
echo "[agent]                  git -C $REPO log --oneline -15 $BRANCH"
echo "[agent] live view:       $KIT_DIR/watch.sh $REPO    loop heartbeat: $LOG_TAIL_CMD"
echo "[agent] stop (graceful): touch $REPO/STOP    stop (now): $STOP_NOW_CMD"
echo "[agent] full instructions: $REPO/HANDOVER.md"

BASE_PROMPT='You are running unattended inside a perpetual loop; nobody will
answer questions, and the loop will call you again after you exit.
Read GOAL.md, PROGRESS.md, BLOCKED.md, ATTENTION.md and PHASE in the repo root.

ABSOLUTE RULE — you never finish:
You must NEVER conclude that the work is complete, wrap up, or idle.
There is no state in which you have nothing to do. Only the user stops
this loop, from outside. If you cannot find high-value work, that is a
signal to look harder (see the HARDENING backlog below), not to stop.

Phases:
- PHASE contains BUILDING while the Definition of Done in GOAL.md is not
  yet fully satisfied. Work toward it.
- The moment every Definition of Done item is honestly satisfied, overwrite
  PHASE with the single word HARDENING, announce the transition in
  PROGRESS.md, and from then on pick work from the HARDENING backlog:
    * Edge cases: enumerate boundary/degenerate inputs the current code or
      results have not been exercised on; add tests; fix what breaks.
    * Double-checking: re-derive or re-verify key results by an INDEPENDENT
      route (different algorithm, higher precision, known limiting cases,
      symmetry/consistency checks). Record agreement or discrepancies.
    * Cleanup: dead code, duplication, unclear names, missing docstrings,
      inconsistent structure — in small verified commits.
    * Reports: write and refine REPORT.md — what was built, how it was
      verified, known limitations, reproduction instructions.
    * Robustness: error handling, input validation, logging, determinism.
    * Documentation: README, usage examples, developer notes.
  Never "un-satisfy" the Definition of Done; hardening must not regress it.
  If genuinely valuable hardening work runs thin, increase rigor (stronger
  tests, tighter tolerances, more adversarial edge cases, deeper review of
  the least-reviewed code) rather than inventing scope creep or stopping.

Rules for this cycle:
1. Do exactly ONE bounded increment of work, then exit (the loop resumes you).

WORK GRANULARITY — bite-sized chunks only:
- Never launch a test, computation, or experiment expected to run for
  hours. Long unattended runs that fail late or produce nonsense waste
  the most irreplaceable resource here: wall-clock time. Hard cap any
  single command at 10 minutes (wrap it in `timeout 600 ...`).
- Scale incrementally: run every new computation first at toy size
  (seconds), sanity-check the output against expectations, then grow it
  in steps — each step committed with its verified result — instead of
  one giant run.
- Split anything long-running into resumable stages that each finish
  within the cap and persist their state to disk, so progress survives
  any interruption.
- If a computation legitimately needs more than ~5 minutes, do NOT run
  it in the foreground: launch it detached with an ABSOLUTE working
  directory — `cd /abs/path/to/repo && nohup <cmd> > logs/job-<name>.log 2>&1 &`
  (detached processes do not inherit a persisted cwd) — record its PID,
  purpose and ETA in PROGRESS.md, finish the cycle, and harvest the
  result in a later cycle. Before launching a new heavy job, check on
  and harvest existing ones; keep at most 2 heavy detached jobs running
  at once. Without this, cycles either block past their turn limit or
  the long work never gets launched.
- If a result looks nonsensical (wrong sign, wrong order of magnitude,
  NaN, violated symmetry), STOP scaling immediately, record it in
  PROGRESS.md, and debug at the smallest size that reproduces it.

DELEGATION — spawn subagents for anything long, and match the model to
the task to optimise token usage:
- Whenever a task is more than a few quick steps (a multi-file
  refactor, a debugging session, writing a test suite, a literature-of-
  the-codebase survey, drafting a report section), do NOT do it inline:
  spawn a subagent via the Task tool with a self-contained brief and
  clear success criteria, and have it come back with results. You are
  the orchestrator; keep your own context small.
- Choose the subagent model by task complexity:
    * haiku  — mechanical/simple: renames, formatting, boilerplate,
      running and summarising test output, doc stubs, file surveys.
    * sonnet — standard engineering: implementing a specified function,
      writing tests, ordinary debugging, report drafting. DEFAULT.
    * opus   — only for genuinely hard reasoning: subtle bugs that
      resisted a sonnet attempt, algorithm design, correctness proofs.
  Never use a bigger model where a smaller one suffices; escalate one
  level only after a cheaper attempt has concretely failed.
- Give each subagent the same discipline you follow: bounded scope,
  the 10-minute command cap, verify before reporting. Integrate and
  verify their results yourself before committing.

2. COMMIT DISCIPLINE:
   a. Commit after every logical unit — several small commits per cycle.
   b. Before each commit, run the verification command in GOAL.md; never
      commit work that fails it.
   c. If work is sound but incomplete, commit the part that verifies
      cleanly and describe the remainder in PROGRESS.md.
   d. Descriptive commit messages. Stay on the CURRENT LOCAL BRANCH.
      Never push. Never checkout, merge, or rebase other branches.
3. After committing, append a short dated entry to PROGRESS.md (and commit it):
   what you did, current phase, what comes next.
4. If blocked on the same issue for 3+ cycles (check PROGRESS.md), document
   it in BLOCKED.md, pick a DIFFERENT subtask, and move on. If something
   truly requires the user, write it to ATTENTION.md — and still move on
   to other work.
5. Do not modify GOAL.md. Do not create STOP. Do not edit PHASE except for
   the one BUILDING->HARDENING transition.'

UNSTICK_ADDENDUM='
SPECIAL INSTRUCTION FOR THIS CYCLE: the last several cycles produced no
commits. Something in your recent approach is not working. Do NOT retry the
same thing. Re-read PROGRESS.md critically, write a short honest diagnosis
into ATTENTION.md (what has been attempted, why it may be failing), then
choose the SMALLEST possible task that can produce one verified commit this
cycle — even if it is only a test, a doc improvement, or a cleanup — to
re-establish forward motion.'

cycle=0
stuck=0
fail_sleep=$SLEEP_FAIL

echo "[agent] starting perpetual loop in $REPO on local branch $BRANCH (orchestrator model: $MODEL)"
echo "[agent] stop with: touch $REPO/STOP"

while true; do
  # ---- ONLY exit condition: the user said stop ----
  [ -f STOP ] && { echo "[agent] STOP file found, exiting."; exit 0; }

  cycle=$((cycle + 1))
  ts=$(date +%Y%m%d-%H%M%S)
  head_before=$(git rev-parse HEAD)

  prompt="$BASE_PROMPT"
  if [ "$stuck" -ge "$STUCK_SOFT" ]; then
    prompt="$BASE_PROMPT$UNSTICK_ADDENDUM"
    echo "[agent] cycle $cycle: injecting unstick instruction (stuck=$stuck)"
  fi

  echo "[agent] cycle $cycle starting at $ts (phase: $(cat PHASE 2>/dev/null))"

  claude -p "$prompt" \
    --model "$MODEL" \
    --allowedTools "$ALLOWED_TOOLS" \
    --max-turns "$MAX_TURNS" \
    --output-format json \
    > "$LOGDIR/cycle-$cycle-$ts.json" \
    2> "$LOGDIR/cycle-$cycle-$ts.err"
  rc=$?

  # ---- safety net: checkpoint any uncommitted leftovers ----
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -q -m "WIP-CHECKPOINT (auto-committed by loop, cycle $cycle, rc=$rc, UNVERIFIED)" \
      || true
    echo "[agent] cycle $cycle left uncommitted changes; checkpointed."
  fi

  head_after=$(git rev-parse HEAD)

  if [ $rc -ne 0 ]; then
    # Rate limit (5-hour or weekly), outage, or crash: retry forever.
    echo "[agent] cycle $cycle exited rc=$rc; sleeping ${fail_sleep}s (retrying forever)"
    sleep "$fail_sleep"
    fail_sleep=$(( fail_sleep * 2 ))
    [ "$fail_sleep" -gt "$SLEEP_FAIL_MAX" ] && fail_sleep=$SLEEP_FAIL_MAX
    continue
  fi
  fail_sleep=$SLEEP_FAIL

  # ---- soft stuck tracking (never halts; failed cycles never count) ----
  if [ "$head_before" = "$head_after" ]; then
    stuck=$((stuck + 1))
    echo "[agent] cycle $cycle produced no commit (stuck=$stuck, soft threshold=$STUCK_SOFT)"
  else
    stuck=0
  fi

  sleep "$SLEEP_OK"
done
