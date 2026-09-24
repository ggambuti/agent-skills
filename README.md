# headless-agent-skills

Claude Code skills for running an agent **unattended toward a goal for days
or weeks**, and for checking in on it while it works.

| Skill | Purpose |
|---|---|
| [`headless-agent`](./headless-agent) | Sets up Claude Code to run as a perpetual, self-healing background loop — survives rate-limit resets, outages, crashes, and reboots, and never stops itself. |
| [`headless-agent-report`](./headless-agent-report) | Read-only status report on a running headless agent: progress, blockers, quota usage, what it did overnight. |
| [`fellowship`](./fellowship) | Runs a gated checkbox plan with a team of long-lived named agents: the session is the PI (gandalf), a lead holds the plan, workers own disjoint file areas, and every agent hands off to a twin when its context half-fills. Fewer total tokens, faster results. |

## How it works (short version)

The architecture is a **stateless outer loop over persistent repo state**.
Each cycle is a fresh `claude -p` invocation that reads its state from files
in the target repo, does one bounded increment of work, commits, and exits.
Nothing depends on a long-lived session, so a rate limit, an API outage, or a
crash costs only time — never work or state. It runs as a systemd service on
Linux or a launchd agent on macOS.

Once the stated goal is reached, the loop doesn't stop — it flips into a
"hardening" phase (edge cases, double-checking, cleanup, docs) and keeps
going until you stop it yourself with a `STOP` file or by stopping the
service.

See `headless-agent/SKILL.md` for the full design contract.

## Prerequisites

- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and authenticated (`claude` on your `PATH`).
- The target project is a **git repo** — the loop's state and work live in commits.
- Linux with `systemd`, or macOS with `launchd`.
- A Claude subscription or API access that supports `claude setup-token` (the installer will walk you through this).

## Installation

Claude Code loads personal skills from `~/.claude/skills/<skill-name>/`.

```bash
git clone <this-repo-url> /tmp/headless-agent-skills
mkdir -p ~/.claude/skills
cp -r /tmp/headless-agent-skills/headless-agent ~/.claude/skills/
cp -r /tmp/headless-agent-skills/headless-agent-report ~/.claude/skills/
rm -rf /tmp/headless-agent-skills
```

Restart Claude Code (or start a new session) and both skills will be
available — Claude will pick them up automatically from natural-language
requests, or you can invoke them by name.

## Usage

**Start a headless run** — from inside the target repo, tell Claude Code
something like:

> "Set this up to run headless overnight toward: <goal>"
> "Keep working on this while I'm away, don't stop until it's done"

This walks through writing a `GOAL.md`, installing the platform service, and
the auth setup gate (`headless-agent/assets/install.sh` refuses to install a
loop that can't authenticate, since that would just poll forever looking
like an outage).

**Check on it** — from any session:

> "How's the headless agent doing?"
> "What did it get done overnight?"
> "Is it stuck?"

This is strictly read-only: it never touches the work branch, state files,
or the verification/build commands, so it can't collide with a cycle that's
mid-run.

## Repo structure

```
headless-agent-skills/
├── README.md
├── headless-agent/
│   ├── SKILL.md              # skill definition + design contract
│   └── assets/
│       ├── install.sh        # idempotent installer (auth gate + service setup)
│       ├── run-agent.sh       # the outer loop itself
│       ├── watch.sh          # live tail of the running loop
│       ├── usage.sh          # quota / cost accounting
│       ├── GOAL.template.md
│       ├── HANDOVER.template.md
│       ├── claude-agent.service        # systemd unit (Linux)
│       └── com.USER.claude-agent.plist # launchd agent (macOS)
└── headless-agent-report/
    ├── SKILL.md
    └── assets/
        └── gather.sh          # evidence-gathering pass for the status report
```

## Notes

- `com.USER.claude-agent.plist` has a `USER`/`__LABEL__` placeholder — the
  installer fills this in per-machine, you shouldn't need to edit it by hand.
- Credentials are never handled by the agent itself — `install.sh` stops and
  gives you explicit manual steps (`claude setup-token`) if auth isn't
  already set up. This is intentional; see the comments at the top of
  `install.sh`.
- Both skills are plain markdown + shell — no build step, nothing to
  compile. Pulling latest is just a `git pull` plus re-copying into
  `~/.claude/skills/`.
