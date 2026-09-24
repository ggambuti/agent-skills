---
name: fellowship
description: Use when the user wants a plan executed by a team of agents ("spawn a team", "assemble the fellowship", "run this plan with a team", "PI / lead / workers"), hands over a checkbox plan with stage gates and asks for fast or minimal-token execution, or complains that long agent runs lose work when contexts fill up.
---

# Fellowship

The session is the PI: a wizard who never picks up a sword. It interviews the user, proposes a team in one table, gets approval, spawns long-lived named agents, and then only decides gates and answers escalations. Leads hold the plan and dispatch tasks verbatim; workers edit disjoint file areas. Every agent hands its work to a twin when its context half-fills. The point is fewer total tokens and faster results, so the PI's own context is the resource to protect.

## Casting

| kind | pool | count |
|---|---|---|
| pi (the session) | gandalf (default), galadriel, sauron | exactly 1 |
| lead | aragorn, legolas, gimli, boromir, faramir, eomer | 1; more only when the plan splits into conceptually different branches, each lead owning its own stages |
| worker | frodo, sam, merry, pippin, bilbo; thorin, balin, dwalin, fili, kili, dori, nori, ori, oin, gloin, bifur, bofur, bombur | one per disjoint file area |

Twins: `frodo` → `frodo-2` → `frodo-3`. Models per the Agent tool enum: fable, opus, sonnet, haiku. Cheap workers on sonnet or haiku; opus only where the task needs judgement.

## PI checklist

1. **Plan gate.** No plan with `## Global Constraints`, `## Stage gates`, `## Stage N` sections and `### Task` checkboxes? Do not spawn anything. Run superpowers:brainstorming, then superpowers:writing-plans, asking as many questions as it takes until goals, gates and constraints are unambiguous. Only a finished plan proceeds.
2. **Interview**, one AskUserQuestion call, 3 to 5 questions, everything else defaulted: (a) goal, plan, spec, workdir, branch; (b) how much domain reasoning the run needs and where (sets lead and worker models); (c) does the work branch into unrelated sub-efforts (sets the number of leads); (d) repo traps for `notes`; (e) what is already done. Do not ask which files change: `python3 scripts/render.py --files <plan>` lists every path the plan names, per stage. Worker areas come from that list, never from memory or prose.
3. **Write `team.toml`** in the workdir's handoff dir. `example/team.toml` is the schema, every key commented. Run `python3 scripts/render.py <team.toml>`: it validates (including that every plan file falls in some worker's area), writes one prompt file per agent, prints the table.
4. **Propose the table** to the user as printed, plus the handoff thresholds line. Ask for approval. Edits: change the toml, re-render, re-show. Never spawn before a yes.
5. **Read the spec once** if the pi role lists it. Read nothing else: not the plan, not source, not tests.
6. **Spawn** every lead and every worker now, background, named, `Agent(name=<name>, model=<model>, prompt="You are <name>. Read <prompt path> fully and follow it.")`. Workers report "ready" to their lead and wait; the lead enforces concurrency. A worker whose message to its lead fails says so in its return; relay once and note it.
7. **Run loop.** Do nothing until a message arrives. Gate passed → one line: pass. Gate failed → you do not judge the result: if the plan names the next move (a fallback, a re-run with other seeds) answer with that in one line; otherwise forward the lead's numbers to the user in ≤ 10 lines and relay the answer. Escalation → same rule: answer from the spec in ≤ report_limit lines when the spec settles it, else ask the user. Handoff notice → step 8. Anything else → ignore.
8. **Handoff twin.** `Agent(name=<name>-<n+1>, model=<same>, prompt="You are <name>-<n+1>, twin of <name>. Read <prompt path>, then <handoff path>; continue from `next`." + answers to its `open doubts`, if any)`. Tell the lead the new name. A lead's twin: tell every worker of that lead.
9. **Finish.** Lead reports final commit hash, evidence files, handoff files. Report to the user in ≤ 10 lines. Stop.

## Validation the script enforces

Exactly one pi; ≥ 1 lead; each stage owned by one lead and covered by ≥ 1 worker; every path in the plan's `**Files:**` blocks falls in the area of a worker serving that stage; every worker has areas and a lead, its stages within its lead's; workers sharing a stage have disjoint areas; models in the enum; the plan has the four required shapes. Off-pool names only warn.

## Spec block, defaults

`handoff_at` 0.5 of `context_window` (fable/opus/sonnet 1,000,000; haiku 200,000; table in `scripts/render.py`); `handoff_tasks` 6 when no token counter is visible; `report_limit` 10 pi, 15 lead, 12 worker; `concurrency` 2; `handoff_dir` `.claude/handoffs`; `notes` free text carried verbatim into every prompt; `escalation` the only reasons any agent may stop and ask.

## Red flags for the PI

| Thought | Reality |
|---|---|
| "Go means go, skip the interview" | Team shape is the user's call. Table first, spawn after a yes. |
| "I'll guess the paths for the areas" | `render.py --files` prints the plan's real paths. Areas from there only. |
| "A separate lead doubles the context" | The lead's context is where the plan lives. Yours costs more per token and must stay small. |
| "The worker should read the spec for context" | Task text verbatim carries Files, Interfaces, Steps. That is its context. |
| "I'll look at the diff / rerun the test myself" | You never open source or run tests. The lead reviews; a failed gate is a one-line decision or an escalation to the user. |
| "Hand off now at 70%, mid-task" | Finish the task, then hand off by protocol. Never mid-task, never composed by you from `git diff`. |
| "Spawn a fresh worker for this task" | Continue with SendMessage. The only respawn is the twin. |
| "The lead said 3.4σ, let me reason about the physics" | If it matches an escalation condition, decide from the spec in ≤ 10 lines or ask the user. Do not investigate. |

## Files

- `templates/lead.md`, `templates/worker.md`, `templates/common.md` (token rules, handoff protocol, handoff-file schema). Placeholders in `{braces}`; the script fails on any left unfilled.
- `scripts/render.py` renders and validates; `scripts/test_render.py` is the self-check.
- `example/`: fixture plan, `team.toml`, and the generated prompts under `handoffs/prompts/` (regenerate with `python3 scripts/render.py example/team.toml`).
