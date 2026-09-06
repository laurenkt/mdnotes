# ADR-0005: Wikilinks resolve by basename first, path when ambiguous

Status: accepted, 2026-09-06

## Decision
`[[foo]]` resolves to the unique note titled `foo` anywhere in the tree. When several notes
share a title, `[[folder/foo]]` disambiguates; a bare ambiguous link resolves to the most
recently modified candidate and is styled as ambiguous.

## Why
Existing links in the library and Obsidian's behaviour both follow this rule, and nested
folders (for future daily notes) make path-always links long and unfriendly. Forbidding
collisions would break weekly daily-note names.

## Consequences
The link index is keyed by lowercase title with a list of candidates per key. Rename must
consider both title-form and path-form references.
