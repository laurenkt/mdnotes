# Open questions

Append-only log. When a task cannot proceed without a decision that `SPEC.md` does not make,
add an entry here, mark the task `[?]` in `PLAN.md`, and move to the next task that does not
depend on it. The human answers by editing the entry and, if needed, `SPEC.md` via an ADR.

Format:

```
## Q<n>: <one-line question>            (task: M?.?, date)
Context: what was being attempted and why the spec is insufficient.
Options: the choices seen, with a recommendation.
Answer: (left blank for the human)
```

## Q1: After Enter on a nested path (`daily/foo`), what should the list show and select?   (task: M2.6b, 2026-09-06)
Context: C-4 says the search field keeps the query "so the list still shows the new note".
That holds for a flat title: the words of `foo bar` are substrings of the title `foo bar`
(S-2). It cannot hold for a nested query: `daily/foo` creates `daily/foo.md` whose title is
`foo` (L-5) and whose body is empty, and the word `daily/foo` is a substring of neither, so
the kept query lists nothing and the new note cannot be selected in the list. The same gap
applies to C-1 opening an existing `daily/foo.md` by its path.
M2.6a ships this interim behaviour: the file and folders are created (C-2), the editor shows
the new note empty and focused, the query is kept, and the list selection is cleared because
the note is not listed. Two related rules were derived rather than decided, and are flagged
here for review: (a) C-1 also treats a query equal (ignoring case) to a note's path without
`.md` as naming that note, so `daily/foo` opens `daily/foo.md` rather than writing an empty
file over it; the exact-path note wins over other notes with the same title, and among title
matches the most recently modified opens (as K-2 does for ambiguous links). (b) C-3 also
rejects, inline, queries that cannot make a listable note: an empty segment (`a//b`, `/a`,
`a/`), a `.` or `..` segment, a segment starting with `.` (hidden, L-3), and a first segment
of `Trash` or `templates` (L-3).
Options:
  1. Match query words against the note's relative path (without `.md`) as well as its
     title, so `daily/foo` lists `daily/foo.md`. Changes S-2 and touches the index (ADR).
  2. After a nested create, replace the field's text with the new title (`foo`) so the list
     shows it. Changes C-4's "keeps the query".
  3. Accept the interim behaviour: nested notes are reachable through the editor only until
     the query changes. No spec change, but C-4 is knowingly unmet for nested paths.
  Recommendation: option 1, scoped to path-form matching only when a query word contains `/`,
  so flat queries are unchanged and PF-2 is unaffected for the common case.
Answer:
