import AppKit

/// The main window (W-1). A `flagsChanged` event reaches the first responder alone, so with
/// the search field or the list focused the editor would never hear Command go down or up
/// while the pointer rests on a link; the window hands every modifier change to the editor's
/// hover itself whatever has focus (ED-12, I-12). With the editor focused the event already
/// reaches it through `super`, so it is not handed on twice.
public final class MainWindow: NSWindow {
    /// The editor whose Cmd-hover follows every modifier change in this window.
    public weak var modifierHoverView: EditorTextView?

    public override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        guard event.type == .flagsChanged, let editor = modifierHoverView, firstResponder !== editor else { return }
        editor.modifiersDidChange(event.modifierFlags)
    }
}
