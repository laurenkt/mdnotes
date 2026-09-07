# ADR-0008: Query words containing `/` match the note's relative path

Status: accepted, 2026-09-07

## Decision
A query word that contains `/` is matched, case-insensitively, as a substring of the note's
relative path without the `.md` extension (for example `daily/foo` for `daily/foo.md`) in
addition to the title and body. Words without `/` are unchanged: they match title or body only
(S-2, ADR-0003). Ordering is unchanged: a path match counts as a title match for S-3.

Two rules derived while shipping M2.6a are confirmed:

- C-1 also treats a query equal (ignoring case) to a note's relative path without `.md` as
  naming that note. An exact-path note wins over other notes with the same title; among
  title-only matches the most recently modified opens, as K-2 does for ambiguous links.
- C-3 also rejects, inline, queries that cannot make a listable note: an empty segment
  (`a//b`, `/a`, `a/`), a `.` or `..` segment, a segment starting with `.` (L-3), and a first
  segment of `Trash` or `templates` (L-3).

## Why
C-4 keeps the query after creation so the list still shows the new note. For a nested query
the new note's title (L-5) is only the last segment and its body is empty, so under S-2 alone
the kept query lists nothing and the note cannot be selected. Matching path-form words against
the path makes C-1 open, C-4 list, and K-2 path-qualified links agree on what a `/` in the
input means. Scoping the rule to words that contain `/` keeps the common flat query on the
same code path, so PF-2 is unaffected for it. The alternatives were to rewrite the field's
text to the new title after creation (Enter would mutate what was typed, and the shorter title
may list other notes) or to leave nested notes reachable only through the editor.

## Consequences
The search index carries the lowercase relative path alongside the title. Tests for S-2 gain
path-form cases. Q1 in `docs/QUESTIONS.md` is answered by this ADR; M2.6b implements it.
