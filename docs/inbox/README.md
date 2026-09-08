# Inbox

Outcomes of `/feedback` and `/milestone` conversations, and seeds captured from the phone,
waiting for the orchestrator to merge them into `docs/PLAN.md` and `docs/SPEC.md` (ADR-0017).
Discussion sessions only ever create files here; they never edit the plan or the spec, so
they can run at any time, in any session or worktree, without disturbing the task in flight.

- `kind: feedback`, `schedule: end-of-current`: tasks land at the end of the milestone that
  holds the next open task (or before a named task).
- `kind: milestone`, `schedule: after-last`: a whole new `## M<n>` section after the last one.
- `kind: seed`: verbatim text from the human, to be grilled by `/feedback` (no topic).

Applied files move to `applied/` with the commit that merged them. Never edit an applied file.
