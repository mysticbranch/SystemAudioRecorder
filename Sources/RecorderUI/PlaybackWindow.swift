import AppKit

/// Handles Space only after the focused responder has had a chance to consume it.
/// Text editing, controls, modified shortcuts, and modal sheets keep normal behavior.
@MainActor
public final class PlaybackWindow: NSWindow {
    public weak var recorder: RecorderModel?

    public override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard event.keyCode == 49, modifiers.isEmpty, !event.isARepeat,
              attachedSheet == nil, !(firstResponder is NSTextView), !(firstResponder is NSControl),
              recorder?.toggleActivePlayback() == true else {
            super.keyDown(with: event)
            return
        }
    }
}
