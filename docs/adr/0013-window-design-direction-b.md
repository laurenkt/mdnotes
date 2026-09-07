# ADR-0013: Window design direction B, native Settings form, Notes-style dates

Status: accepted, 2026-09-07

## Decision
Main window follows direction B of the design canvas
(https://claude.ai/code/artifact/b192e298-4379-482e-94d5-5e0efc5d7b4f): standard title bar,
search field inset in the content area over a window-background strip with a hairline
beneath, then list, editor, backlinks strip (W-6). Settings is a single-pane native form
(PR-1). Dates use the Notes-style relative format and never truncate (S-9, S-10). Snippets
strip markdown (S-6).

## Why
v1 dropped a standard search field edge-to-edge into a plain stack with no insets, giving a
rounded control in a square slot and an odd focus glow. Three directions were mocked up; the
owner chose B over a toolbar-hosted field (A) and a title-bar-less HUD (C). Preferences was a
hand-laid stack that did not read as a macOS settings window. Dates truncated because the
date label was capped at half the row width.

## Consequences
No custom drawing anywhere; only semantic system colours. The canvas is the visual reference
for the implementing agent's self-review (ADR-0015).
