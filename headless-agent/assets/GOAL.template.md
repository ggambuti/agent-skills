# Goal

<!-- THE USER'S PROMPT GOES HERE. Written as a brief to a competent
     colleague who cannot ask anything for weeks. Be concrete. -->

(Objective.)

## Definition of Done

Satisfying ALL of these switches the agent from BUILDING to HARDENING —
it does NOT stop the agent. Only the user stops the loop.

- [ ] (Concrete, checkable criterion 1)
- [ ] (Concrete, checkable criterion 2)

## Verification command

Run before every commit; never commit if it fails:

```
make check
```

## Constraints

- Work only on the current local branch. Never push. Never touch main.
- Never modify this file; never create STOP; never delete history in
  PROGRESS.md; PHASE may only change BUILDING -> HARDENING, once.
- Never delete or weaken existing passing tests to make verification pass.
- Missing info or dependencies: record in BLOCKED.md (or ATTENTION.md if
  only the user can resolve it) and work on something else.
- Prefer many small verified commits over large risky ones.
- Max runtime for any single command/test/experiment: 10 minutes
  (`timeout 600`). <!-- raise here explicitly if the project needs it -->

## Priorities (BUILDING phase)

1. Anything that unblocks other work.
2. Core functionality in the Definition of Done.
3. Tests and documentation for what already exists.
