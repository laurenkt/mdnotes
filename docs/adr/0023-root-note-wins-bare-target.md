# ADR-0023: A bare link target names the root note of that path

Status: accepted, 2026-09-23 (Q6)

## Decision
A bare wikilink target that is exactly a root note's relative path names that note:
`[[foo]]` resolves to the root `foo.md` whenever one exists, even when other notes share the
title. Only when no root note matches is the target read as a title under K-2's existing
rules (the single candidate, else the most recently modified one, styled ambiguous). Copy
Link (R-4) on a root note keeps writing `[[Title]]`, which now always names it. Backlinks
(K-6) and link opening (K-3) follow the same resolution.

## Why
For a root note the relative path without `.md` is the bare title, so K-2's "give the
relative path" instruction produced a link that resolved by modification time and could land
on a same-titled note in a subfolder, flipping as either was edited (I-13). Reading the bare
target as a root path first needs no new syntax, makes the link stable, and treats the root
note as K-2 already treats the others: named by its relative path.

## Consequences
An existing bare `[[foo]]` that reached a newer `daily/foo` now reaches the root `foo`; notes
elsewhere that share a root note's title need their path, as K-2 already demands. The
rejected alternatives were a root-anchored `[[/foo]]`, allowing `[[foo.md]]`, and accepting
the gap.
