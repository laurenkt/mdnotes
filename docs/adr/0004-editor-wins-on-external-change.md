# ADR-0004: On external change, the editor's unsaved text wins

Status: accepted, 2026-09-06

## Decision
When the open note changes on disk while the editor has unsaved edits, the editor keeps its
text and overwrites disk at the next autosave. No conflict copy is written. When the editor is
clean, the disk version is loaded silently.

## Why
The owner's explicit preference: "just blast the changes". The library is iCloud-synced, so
spurious rewrites are common and conflict files would accumulate. The autosave window is
300 ms, so the amount of external change that can be lost is small and the user is by
definition actively editing that note.

## Consequences
Concurrent editing of one note from two machines will lose one side's changes. Accepted.
