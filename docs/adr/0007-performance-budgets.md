# ADR-0007: Performance budgets are failing tests

Status: accepted, 2026-09-06

## Decision
The budgets in `SPEC.md` section 13 are enforced by XCTest classes named `*PerfTests`, run in
release builds against a 20,000-note synthetic library (five notes of 1 MB). A miss fails the
commit. Budgets are constants in `PerfGate.Budget` and may only change via an ADR.

## Why
The whole reason this project exists is that other apps got slow. The owner's real library is
under 200 notes and under 1 MB, which proves nothing; 20k is roughly 100x and forces the
architecture (off-main-thread I/O, immutable snapshots, paragraph-scoped styling) to be right
from the first milestone rather than retrofitted.

## Consequences
Perf tests are machine-dependent. They are calibrated to the development machine; if they flake
by less than 20 %, the fix is to reduce variance (more iterations, warm-up), not to raise the budget.
