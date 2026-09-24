# Example plan: add a rate limiter to the API

Fixture for the fellowship skill: the smallest plan shape the skill accepts.

## Global Constraints

- No code file over 500 lines.
- Public API of `pkg/limiter.py` is fixed by the Interfaces blocks below; never change a signature without stopping.
- Commits end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## Stage gates

| gate | passes when | unlocks |
|---|---|---|
| G0 | `pytest tests/test_limiter.py` green; 10k-call benchmark under 50 ms | Stage 1 |
| G1 | full `pytest` green; README documents the new setting | done |

## Stage 0 — the limiter

### Task 0.1: token bucket

**Files:**
- Create: `pkg/limiter.py`
- Test: `tests/test_limiter.py`

**Interfaces:**
- `TokenBucket(rate: float, burst: int)`, `.allow(now: float) -> bool`

- [ ] **Step 1: Tests.** Refill over time, burst cap, deny when empty.
- [ ] **Step 2: Implement.** Pure function of `now`; no threads.

### Task 0.2: benchmark

**Files:**
- Create: `benchmarks/limiter_bench.py`

- [ ] **Step 1: Script.** 10k `allow()` calls, print wall time.

## Stage 1 — wiring and docs

### Task 1.1: middleware

**Files:**
- Modify: `app/middleware.py`
- Test: `tests/test_middleware.py`

**Interfaces:**
- `rate_limit(app, bucket: TokenBucket)`

- [ ] **Step 1: Test.** 429 after burst.
- [ ] **Step 2: Wire.** Read `RATE_LIMIT` from settings.

### Task 1.2: docs

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document `RATE_LIMIT`.**
