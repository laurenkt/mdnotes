# ADR-0015: UI tasks render snapshots and the implementing agent inspects them

Status: accepted, 2026-09-07

## Decision
Any task that changes a window's appearance renders it to PNG from its smoke test, in light
and dark appearance, and the agent looks at the PNGs and compares them with the spec and the
design canvas before committing, recording what it checked in the commit message (V-1).
Snapshots are build products and are not committed.

## Why
v1's spec was structural and its gates caught behaviour, not looks; the result worked and
looked janky. v2 is mostly visual. Sending snapshots to the owner at milestones was offered
and declined; the owner will review by running the app at tags. Self-review is the cheapest
check that still puts eyes on the pixels before a commit.

## Consequences
Smoke tests gain a rendering helper. Reference images are not stored, so this catches
"obviously wrong", not regressions; the owner's review at tags remains the final check.
