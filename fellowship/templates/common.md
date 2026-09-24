## Token rules (everyone)

- Nobody re-reads the plan. The lead reads it once; workers receive only their task text.
- Reports are ≤ your report limit, numbers not narration. Never summarise the plan or spec back to anyone.
- If a `ponytail` skill exists, workers write code with it. If `caveman`/`cavecrew` exist, everyone reports with them. Domain prose the plan asks for (docs, method notes) is exempt.
- Targeted test commands per step. Full suites only at gates, once, in the background.
- Continue an agent with SendMessage. Never spawn a fresh agent for a task; the only sanctioned respawn is the handoff twin below.
- Independent tool calls in one message. Independent tasks on disjoint areas in parallel.
- Long runs (heavy tests, physics cards) go in the background; nobody polls; wait for the completion notification.

## Context handoff (you are `{name}` or one of its twins)

Names: `{name}` is generation 1; its twin is `{name}-2`, then `{name}-3`. Your handoff file is `{handoff_dir}/<your full name>.md`.

Your context window is {context_window} tokens. Hand off when you have used {handoff_at} of it = {handoff_tokens} tokens. Read your usage from any token counter visible to you (remaining-token figures, context-usage notices). If no counter is visible, hand off after {handoff_tasks} completed tasks instead.

When the threshold is crossed: FINISH the task you are on (commit, report). Take nothing new. Then, at that task boundary:

1. Write `{handoff_dir}/<your full name>.md`, all sections present, terse:

   ```
   # Handoff <your name> → <twin name>
   role/prompt summary: (3 lines: purpose, areas, report limit)
   done: task ids + commit hashes
   in progress: none
   next: the task id queued for you, if known
   decisions: what was decided and why, one line each
   environment: exact commands that work (build, test, import tricks), traps hit
   open doubts: anything the twin should ask {pi} or the lead about
   last report: your last message to your counterpart, verbatim
   ```

2. SendMessage {counterparts} one notice, ≤ 5 lines: your name, the twin's name, the handoff path, "stopping". Then stop (return).
3. {pi} spawns the twin with this same prompt file plus "read the handoff first; continue from `next`". The twin's first report to its counterpart is one line: handoff read, task it is starting.

Never hand off mid-task. Never delete a handoff file. If you are a twin, read your predecessor's handoff before anything else.
