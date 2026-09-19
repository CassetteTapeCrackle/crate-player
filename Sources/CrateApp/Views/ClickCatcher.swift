import AppKit
import SwiftUI

/// Reports clicks with their count and modifier keys, which SwiftUI's tap gestures
/// expose neither of.
///
/// Sized by whatever it sits on, so putting it over a `Text` before any frame modifier
/// gives a target the width of the glyphs rather than the width of the column.
struct ClickCatcher: NSViewRepresentable {
    let onClick: (Int, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatchingView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatchingView)?.onClick = onClick
    }

    private final class CatchingView: NSView {
        var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?

        override func mouseDown(with event: NSEvent) {
            onClick?(event.clickCount,
                     event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }

        /// Otherwise the first click into an unfocused window is swallowed activating it.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
