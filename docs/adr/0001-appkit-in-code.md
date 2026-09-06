# ADR-0001: AppKit, built entirely in code

Status: accepted, 2026-09-06

## Decision
The UI is AppKit (`NSWindow`, `NSTableView`, `NSTextView`, `NSSplitView`), constructed in Swift
with no storyboards, xibs, or SwiftUI.

## Why
The product goal is nvALT-level latency: filter a large list on every keystroke, move focus
between three views with the keyboard, and edit text with no lag. `NSTableView` reloads
synchronously with no diffing layer; `NSTextView` is the same TextKit engine nvALT used; key
handling is explicit. SwiftUI's macOS `List` adds identity-diffing cost per keystroke,
`TextEditor` gives little control over key events and attributed text, and focus management
across multiple views is unreliable. A hybrid would put the hard parts in AppKit anyway and add
a bridging layer. Building in code removes Interface Builder files that agents cannot edit
reliably and keeps everything testable headlessly.

## Consequences
More boilerplate. All layout via Auto Layout or manual frames in code. Tests construct
controllers directly rather than clicking.
