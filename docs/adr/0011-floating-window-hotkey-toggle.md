# ADR-0011: Always-floating window, hotkey toggles, close hides

Status: accepted, 2026-09-07

## Decision
The window level is always floating and follows the active Space. The global hotkey toggles
visibility. Closing the window hides it instead of quitting (W-3, W-4, W-5).

## Why
The owner uses the app as a summonable reference and wants it to stay above whatever they are
working in until dismissed. "Float while summoned" and a menu toggle were offered; the owner
chose always-on. With a toggle hotkey, quitting on close would make the toggle pointless, so
close becomes hide.

## Consequences
The window covers other apps whenever visible; the hotkey is the way out. Any sheet, popover
or completion popup must be at a level above `.floating` or it will appear behind the window.
The smoke tests need to assert window level and collection behaviour rather than visual state.
