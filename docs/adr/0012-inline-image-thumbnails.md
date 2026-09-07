# ADR-0012: Inline image thumbnails below the embed line

Status: accepted, 2026-09-07

## Decision
An image embed that resolves to a file gets a display-only thumbnail attachment on the line
below it, at most 240 by 160 pt, click to open in the default app (E-9). Rows show a 34 pt
thumbnail of a note's first image (S-11). Both are generated off the main thread and cached
(PF-8). This reverses v1's I-3.

## Why
The owner wants to see images in notes without a preview pane. Replacing the embed text with
the image (live-preview style) was rejected: toggling attributes as the caret moves is the
classic source of editor lag and undo confusion. Keeping the text and adding a separate
attachment line preserves "the file is exactly what you see" for the text itself.

## Consequences
The text storage carries attachment characters that are not in the file; every path that
reads text out of the view (save, copy, search, link parsing, styling ranges) must go through
one accessor that strips them. PF-3 is now measured with thumbnails present.
