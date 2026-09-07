# ADR-0010: System fonts, size adjustable, no family preference

Status: accepted, 2026-09-07

## Decision
Prose uses the system font, code uses the system monospaced font, both at one size. The font
family preference is removed and its stored value deleted on first launch. Size is set with
Cmd-plus, Cmd-minus and Cmd-0, persisted (E-8, E-2).

## Why
The owner does not want to configure fonts and had ended up with a family they disliked and
no obvious way back. Apple's own fonts at the system size are the correct default for a
native app; the only thing worth adjusting is size, and the platform convention for that is
the View menu zoom shortcuts, not a settings field.

## Consequences
Settings shrinks to two rows. `EditorStyler` now changes font family for code tokens, which
is the one exception to "styling never changes layout metrics".
