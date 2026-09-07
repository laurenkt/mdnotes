# Issues

The queue for problems noticed outside the task at hand: flaky gates, bugs, debt. Protocol is
ADR-0016. The orchestrator drains open entries here before taking the next plan task, one
fresh subagent and one commit per entry, so nothing noticed is lost and nothing rots.

Rules:

- A task subagent that notices a problem outside its task fixes it in place only when it is
  in code the task already changes, is a few lines, and is covered by the commit's tests
  (named in the commit message). Otherwise it **records it here and does not fix it**, in the
  same commit as its task: `scripts/record-issue.sh <kind> <where> <text>`.
- Kinds: `flaky` (a gate that failed then passed; `check.sh` records these itself), `bug`
  (observed wrong behaviour against `SPEC.md`), `debt` (something that will bite: duplication,
  a missing test, a workaround).
- An entry must be one-commit sized. If the fixing subagent finds it is larger, it adds a task
  at the top of the current milestone in `PLAN.md` describing the work, marks the entry `[x]`
  with `-> M<n>.<k>`, and commits that.
- Fixing an entry means: reproduce (a test that fails), fix, mark `[x]`, commit as
  `I-<n>: <summary>`. A flaky entry is fixed by reducing variance (warm-up, iterations, isolating
  the subject), never by raising a budget (ADR-0007).
- Entries are never deleted or edited except to mark them done or redirect them to a plan task.

Format: `- [ ] I-<n> <kind> \`<where>\` (<date>): <what was seen, and how to reproduce if known>`

- [ ] I-1 flaky `perf gates` (2026-09-07): the full gate failed once on the v2 spec commit and
      passed unchanged on rerun; the failing class was not captured. Add warm-up and enough
      iterations to every `*PerfTests` class that the median is stable across three consecutive
      runs on an idle machine, and make each perf test print its median so future flake entries
      carry the number.
