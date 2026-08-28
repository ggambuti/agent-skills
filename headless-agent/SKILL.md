---
name: headless-agent
description: >-
  Set up Claude Code to work unattended toward a goal for days or weeks — perpetually, with no human intervention — surviving 5-hour and weekly rate-limit resets, Anthropic server outages, crashes, and reboots, and never stopping on its own. When the goal is reached it switches to hardening (edge cases, cleanup, double-checking, reports) until the user stops it. Use this skill whenever the user wants Claude Code to run headless, autonomously, overnight, over a weekend or holiday, "while I'm away", "keep working until I'm back", in a loop, as a daemon/service, or complains about long runs dying at rate limits or outages. Also use it when asked to make an agent "never stop", "keep going after finishing", or run without supervision.
---

# Headless perpetual agent

Run Claude Code unattended toward a goal for an arbitrary length of time.
The architecture is a **stateless outer loop over persistent repo state**:
each cycle is a fresh `claude -p` invocation that reads its state from
files in the repo, does one bounded increment, commits, and exits. Nothing
depends on a long-lived session, so rate limits, outages, crashes, and
reboots cost only time, never work or state. Works on Linux (systemd) and
macOS (launchd).

## Non-negotiable design contract

When setting this up (or modifying it), preserve these properties. They
are the entire point of the skill:

1. **The agent never stops itself.** No DONE state, no "goal complete,
   exiting", no self-termination on being stuck. The only stop conditions
   are user actions from outside: a `STOP` file in the repo root, a
   signal, or stopping the service. Never add an exit condition the agent
   itself can trigger, and never instruct the inner agent that finishing
   is possible.
2. **Goal completion is a phase transition, not an ending.** When the
   Definition of Done is satisfied, the agent flips `PHASE` from
   `BUILDING` to `HARDENING` and continues indefinitely on the hardening
   backlog: edge cases, independent double-checking of results, cleanup,
   robustness, reports, documentation — escalating rigor rather than
   inventing scope creep.
3. **Impervious to limits and outages.** Failed cycles (5-hour window,
   weekly quota, API outage, crash) are retried forever with capped
   exponential backoff (default 15 min doubling to a 4 h ceiling, held
   indefinitely). No retry-count limit anywhere — not in the loop, not in
   systemd (`StartLimitIntervalSec=0`, `Restart=always`), not in launchd
   (`KeepAlive` with `SuccessfulExit=false`).
4. **All state lives in the repo, every scrap of work gets committed.**
   Small verified commits during each cycle; if a cycle dies mid-edit the
   loop auto-commits leftovers as a labelled `WIP-CHECKPOINT (UNVERIFIED)`
   so no work is lost and the next cycle starts clean.
5. **Bite-sized work only — no hours-long foreground runs.** Any single
   foreground command is hard-capped (default `timeout 600`). New
   computations run first at toy size, are sanity-checked, then scaled in
   committed steps; long jobs are split into resumable stages. Anything
   legitimately needing more than ~5 minutes is launched **detached**
   (`nohup`, absolute cwd), its PID and ETA recorded in `PROGRESS.md`,
   and harvested in a later cycle — at most 2 heavy detached jobs at
   once. A run that fails after hours is the worst outcome for an
   unattended agent — fail fast at small scale instead.
6. **Delegate long tasks to subagents, with the model matched to task
   complexity.** The main agent is an orchestrator: anything beyond a few
   quick steps goes to a Task-tool subagent with a self-contained brief
   that returns results. haiku for mechanical work, sonnet as the default
   for standard engineering, opus only for genuinely hard reasoning after
   a cheaper attempt has failed. Over a multi-week run this is the
   difference between quota lasting and quota evaporating.

## Files this skill provides

Stage ALL of these together in one kit directory (e.g. `~/agent-kit/`) —
the loop resolves its template, env file, and watcher relative to itself:

- `assets/run-agent.sh` — the loop. Adjust only the config block.
- `assets/GOAL.template.md` — template for the user's goal file.
- `assets/install.sh` — idempotent installer THE USER runs: hard auth
  gate first, then platform service installation (launchd or systemd).
- `assets/com.USER.claude-agent.plist` — launchd template (macOS);
  placeholders filled by install.sh. Encodes the critical semantics in
  comments (SuccessfulExit=false, RunAtLoad, ThrottleInterval,
  caffeinate, explicit PATH/HOME, log files).
- `assets/claude-agent.service` — systemd template (Linux); placeholders
  filled by install.sh.
- `assets/watch.sh` — live pretty-tail of the running cycle's transcript.
- `assets/usage.sh` — per-day token/quota consumption report aggregated
  from the loop's own cycle logs (tokens in/out/cache, notional cost
  including subagent calls, failed cycles, commits).
- `assets/HANDOVER.template.md` — operator-card template. run-agent.sh
  regenerates `HANDOVER.md` from it at every launch with the real,
  platform-correct values (including a useful-commands table). Never
  hand-write this card; edit the template if wording must change.

## Setup procedure

1. **Gather from the user:** target repo path, branch name (created if
   missing; all work stays local, never pushed), the goal, the
   verification command, and the ORCHESTRATOR MODEL (default: sonnet).
   The model is the third argument everywhere: `run-agent.sh <repo>
   <branch> <model>` and `install.sh <repo> <branch> <model>`, accepting
   an alias (haiku/sonnet/opus) or a full model id. Explain the default:
   the orchestrator routes, commits, and delegates — heavy reasoning
   already goes to subagents tiered by the prompt — so a mid-tier
   orchestrator is usually right, and pinning it explicitly also makes
   token burn predictable (an unpinned CLI may default to the most
   expensive model). To SEE the model: it is pinned in the service file,
   printed in the heartbeat line and on the operator card, and what
   actually ran (orchestrator + subagents) is in `usage.sh`'s per-model
   breakdown or `jq '.modelUsage' logs/cycle-*.json`. To CHANGE it
   mid-run: stop gracefully (`touch STOP`), re-run install.sh with the
   new model argument. If there is no verification command, help the
   user create even a minimal one first.

2. **Stage the kit:** copy all assets into `~/agent-kit/` (or similar),
   `chmod +x` the scripts, set `SERVICE_NAME` and `VERIFY_CMD` in
   run-agent.sh's config block, and scope `ALLOWED_TOOLS` to the project
   (keep `Task` and `Bash(timeout *)` — removing them silently disables
   the delegation and runtime-cap rules).

3. **Headless auth — hard gate, before anything else.** Probe it
   YOURSELF now, in a minimal service-like environment (a probe in the
   user's interactive shell can pass spuriously via session credentials
   while the service then fails on its first cycle; an expired OAuth
   token can look fine interactively while `claude -p` fails with
   "OAuth session expired and could not be refreshed"):

   ```sh
   env -i HOME="$HOME" PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin \
     sh -c '. ~/agent-kit/env.sh 2>/dev/null; claude -p "Reply with exactly: AUTH-OK" --model haiku' \
     | grep -q AUTH-OK
   ```

   If it fails, have the USER run `claude setup-token` (browser OAuth
   flow) and write the printed `sk-ant-oat01-…` token to
   `~/agent-kit/env.sh` (`export CLAUDE_CODE_OAUTH_TOKEN=…`,
   `chmod 600`). run-agent.sh sources this file at startup; install.sh
   re-probes and refuses to install while auth is broken. You never see
   or handle the token — you build the mechanism and give verbatim
   commands. Do not rely on the macOS keychain: it is not a reliable
   credential source under launchd.

4. **Prove the commit gate green.** The loop forbids committing when
   verification fails, so **a red baseline deadlocks the loop from
   cycle 1**. Run the full verification command once during setup; if
   anything fails, root-cause it before installing. Watch out for
   environment/architecture mismatches (e.g. an x86_64/Rosetta venv
   Python with a native arm64 compiler → dlopen "incompatible
   architecture"; fix with an explicit `-arch` flag in a compiler
   wrapper — `arch -x86_64 c++` does NOT work, the shim re-execs
   natively). If the tree contains uncommitted user WIP with failing
   tests, do not let it poison the gate: exclude it from the
   verification command, record it in GOAL.md as a warm-up task, and
   never discard it (the WIP-checkpoint keeps it safe).

5. **Install the service — via install.sh, run BY THE USER.** You may
   be blocked from `launchctl`/`systemctl` or `~/Library/LaunchAgents`
   by permission policy, and persistent-service installation should be
   user-approved anyway. install.sh is idempotent (re-running after
   fixing auth is the natural retry path): auth probe → platform branch
   → lint/copy → restart service. macOS notes: `launchctl bootstrap
   gui/$(id -u) <plist>` / `bootout` to stop; no journalctl — the loop
   heartbeat goes to `launchd.out.log` (stdout), errors to
   `launchd.err.log`; `caffeinate -is` holds off sleep on AC power
   only — the user must leave the machine plugged in (lid open, or a
   desktop). Linux: `loginctl enable-linger` is mandatory.

6. **Brief the user (mandatory, never skip).** The operator card is
   generated DETERMINISTICALLY: at every launch run-agent.sh regenerates
   `HANDOVER.md` from the template with the actual platform-correct
   commands, including a useful-commands table (live watcher, heartbeat
   log, PHASE/PROGRESS/ATTENTION/BLOCKED, git views, service status,
   `claude --resume`, stop/resume). Show its contents to the user and
   confirm they know the three essentials: verify/repair auth, check
   progress, stop it. Point them at `watch.sh <repo>` for live viewing
   (it tails the newest cycle transcript; if it picks up your setup
   conversation instead, pass that transcript's id as the
   exclude-substring) and at the durable views: `PROGRESS.md`,
   `git log <base>..<branch>`, `claude --resume`.

7. **Explain every user-input step.** Whenever a step needs the human
   (auth token, running install.sh, password-gated fixes), state:
   (1) exactly what to run, verbatim; (2) why you cannot do it yourself;
   (3) how to verify it worked; (4) what failure looks like.

8. **Dry run before departure** (do not skip): run 24 h attended.
   Verify it survives one rate-limit reset; kill the script and confirm
   the service restarts it; reboot and confirm it resumes; confirm
   commits land only on the chosen branch; break the code deliberately
   and confirm no verified commit happens; read `PROGRESS.md` to check
   it picks sensible increments. Sharpen `GOAL.md` now if not.

## How the inner agent is instructed (already encoded in run-agent.sh)

The cycle prompt enforces: one bounded increment per cycle; the
bite-sized-work rules (10-minute foreground cap via `timeout`, toy-size
first, incremental scaling, resumable stages, detached `nohup` launch +
later harvest for anything over ~5 minutes, stop-and-debug on
nonsensical output); subagent delegation with complexity-matched models
(haiku/sonnet/opus, escalating only on concrete failure); commit after
every logical unit, gated on the verification command; dated entries in
`PROGRESS.md`; blocked issues documented in `BLOCKED.md` after 3 stuck
cycles and then *moving on to different work*; user-only questions parked
in `ATTENTION.md` without waiting for an answer; the BUILDING→HARDENING
transition; and the absolute rule that there is no state in which the
agent has nothing to do — running out of ideas means increasing rigor,
never stopping.

Stuck handling is deliberately **soft**: after 5 consecutive successful
cycles with no commit, the loop injects an "unstick" addendum (diagnose
in `ATTENTION.md`, pick the smallest task that yields one verified
commit) — it never halts. Failed cycles (rate limits, outages) never
count as stuck.

## Repo state files (created automatically)

| File | Meaning |
|---|---|
| `GOAL.md` | The brief. Agent never modifies it. |
| `PHASE` | `BUILDING` or `HARDENING`. One transition, agent-written. |
| `PROGRESS.md` | Append-only dated log of every cycle's work. Auto-rotated past `PROGRESS_MAX_LINES` so cycles don't re-read days of history. |
| `progress-archive/` | Older `PROGRESS.md` chunks moved here on rotation. Git-tracked, full history preserved. |
| `BLOCKED.md` | Issues the agent parked after repeated failures. |
| `ATTENTION.md` | Things only the user can resolve; agent continues anyway. |
| `HANDOVER.md` | Operator card, regenerated at every launch. Loop-internal. |
| `STOP` | Created by the USER only. Sole stop mechanism besides the service. |
| `logs/` | Per-cycle JSON output and stderr, plus detached-job logs. |

Kit-directory files: `env.sh` (user-written credentials, chmod 600),
`launchd.out.log` / `launchd.err.log` (macOS service logs),
`auth-probe.err` (installer's last probe stderr).

## When the user returns

`cat PHASE`, read `ATTENTION.md` and `BLOCKED.md`, read `PROGRESS.md`
top to bottom, then review the branch like an external PR:
`git log --stat main..<branch>` and
`git log --oneline --grep='WIP-CHECKPOINT'` for unverified leftovers.
Re-run the full verification before merging or cherry-picking. Then stop
the loop: `touch STOP` (current cycle finishes) or the platform's
immediate stop from `HANDOVER.md`.

## Failure modes to warn the user about

- **Sleep kills everything silently.** `caffeinate` covers AC-powered
  idle/system sleep only; lid-close on battery still sleeps a laptop.
  Always-on box, plugged in.
- **Expired or spuriously-verified auth** looks like an eternal outage:
  endless 4 h retry polls, auth errors in `logs/*.err`. The minimal-env
  probe + env.sh route + install.sh gate exist to prevent this; if it
  happens anyway, only the user can fix it (`claude setup-token`, update
  env.sh, re-run install.sh).
- **A red verification baseline deadlocks the loop from cycle 1.** The
  gate must be proven green during setup.
- **Hardening drift**: over very long runs the hardening phase can
  over-polish. Accepted trade-off of "never stop"; the verification gate
  plus "never regress the Definition of Done" bounds the damage, and
  everything is reviewable commits on one branch.
- **API-key billing** with no spend cap can get expensive over weeks;
  never set that up without a cap.
