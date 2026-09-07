# ADR-0014: Templates as files with a path header, invoked by `@name` in the search field

Status: accepted, 2026-09-07

## Decision
Templates are `.md` files in `templates/` with a `---` header declaring `path`, using
`{{date:FORMAT}}`, `{{title}}` and `{{cursor}}` tokens. A query starting with `@` lists
templates and Enter creates or opens the expanded path. A File menu submenu mirrors it.
There are no per-template shortcuts and no daily-note feature (section 15).

## Why
The owner wanted daily notes but, on reflection, as one instance of a general mechanism: a
template that can decide its own filename. Putting invocation in the search field keeps the
one-field model that defines the app; a picker window and per-template hotkeys were offered
and declined. `@` cannot start a note title in practice, so it is a safe mode prefix.

## Consequences
A literal `@` at the start of a query can no longer search for it. Template mode reuses the
list, so the list needs a second row kind. Idempotent open-if-exists is what makes `@daily`
work as "today's note".
