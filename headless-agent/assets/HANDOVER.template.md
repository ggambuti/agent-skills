# Headless agent — operator card

<!-- TEMPLATE: do not fill this in by hand. run-agent.sh regenerates
     HANDOVER.md from this file at every launch, substituting the
     {PLACEHOLDERS} with the actual, platform-correct configuration, so
     every command below is always valid for this installation. -->

Repo: {REPO_PATH}
Branch: {BRANCH}
Kit: {KIT_DIR}
Machine: {HOSTNAME}
Verification gate: {VERIFY_CMD}
Orchestrator model: {MODEL}  (subagents pick haiku/sonnet/opus per task)
Card generated: {GENERATED_AT} (regenerated at every loop launch)

## Authentication (the #1 failure mode — verify BEFORE leaving)

The loop sources {KIT_DIR}/env.sh at startup, which must contain a
long-lived token you created yourself:

    claude setup-token        # browser OAuth flow; prints sk-ant-oat01-...
    printf 'export CLAUDE_CODE_OAUTH_TOKEN=%s\n' 'sk-ant-oat01-PASTE' > {KIT_DIR}/env.sh
    chmod 600 {KIT_DIR}/env.sh

Prove it works in a minimal (service-like) environment — a test in your
own terminal can pass spuriously:

    env -i HOME="$HOME" PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin \
      sh -c '. {KIT_DIR}/env.sh 2>/dev/null; claude -p "Reply with exactly: AUTH-OK" --model haiku'

If auth expires mid-run the loop CANNOT fix it: it looks like a
permanent outage (endless retry polls; auth errors in
{REPO_PATH}/logs/*.err and {KIT_DIR}/launchd.err.log). Only you can fix
it: redo the three commands above, then run {RESTART_CMD}

## Useful commands

| Command | What it shows / does |
|---|---|
| `{KIT_DIR}/watch.sh {REPO_PATH}` | Live pretty-tail of the running cycle (Ctrl-C safe, agent unaffected) |
| `{LOG_TAIL_CMD}` | Loop heartbeat: cycle starts, backoffs, checkpoints, stuck counter |
| `cat {REPO_PATH}/PHASE` | Current phase: BUILDING or HARDENING |
| `tail -30 {REPO_PATH}/PROGRESS.md` | Dated log of what each cycle accomplished |
| `cat {REPO_PATH}/ATTENTION.md` | Things the agent decided only you can resolve |
| `cat {REPO_PATH}/BLOCKED.md` | Issues parked after repeated failed attempts |
| `git -C {REPO_PATH} log --oneline -15 {BRANCH}` | Commits the agent has produced |
| `git -C {REPO_PATH} log --oneline --grep=WIP-CHECKPOINT` | Unverified auto-checkpoints — review with care |
| `ls -t {REPO_PATH}/logs/ \| head` | Per-cycle JSON result + stderr files (newest first) |
| `{KIT_DIR}/usage.sh {REPO_PATH} {BRANCH}` | Token/quota consumption per day: cycles, tokens, notional cost, commits |
| `{STATUS_CMD}` | Is the service alive |
| `claude --resume` (run in {REPO_PATH}) | Replay a finished cycle as a readable conversation (read-only) |

Healthy: recent commits, dated PROGRESS.md entries, heartbeat lines like
"cycle N starting". A long run of "sleeping 14400s (retrying forever)"
is quota exhaustion or an outage (both self-resolving) — unless the
error logs show auth failures, which need you (see above).

## Stop it (the ONLY ways it stops — it never stops on its own)

    touch {REPO_PATH}/STOP      # graceful: current cycle finishes,
                                # loop exits, service stays down
    {STOP_NOW_CMD}              # immediate: kills the loop now

Resume later (also how to CHANGE THE MODEL — pass a different one as
the third argument, e.g. append " opus" or edit the command):

    {RESTART_CMD}

## When you're back — review checklist

1. cat {REPO_PATH}/PHASE, read ATTENTION.md, BLOCKED.md, then
   PROGRESS.md fully.
2. Review the branch like an external PR:
       git -C {REPO_PATH} log --stat main..{BRANCH}
       git -C {REPO_PATH} log --oneline --grep=WIP-CHECKPOINT
3. Re-run the full verification ({VERIFY_CMD}) yourself before merging
   or cherry-picking anything.
4. Stop the loop (above); archive {REPO_PATH}/logs/ if you want history.
