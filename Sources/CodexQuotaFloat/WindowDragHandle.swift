import AppKit
import SwiftUI

/// Gives the floating panel a reliable drag target even when its entire
/// background is occupied by an interactive SwiftUI hosting view.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

final class DragView: NSView {
    private var mouseDownLocation: NSPoint?
    private var startingOrigin: NSPoint?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        startingOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let mouseDownLocation, let startingOrigin else { return }
        let location = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: startingOrigin.x + location.x - mouseDownLocation.x,
            y: startingOrigin.y + location.y - mouseDownLocation.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        startingOrigin = nil
        window?.saveFrame(usingName: "CodexQuotaFloatPanel")
    }
}
