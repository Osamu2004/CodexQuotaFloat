import AppKit
import SwiftUI

final class FloatingPanelController: NSObject, NSWindowDelegate {
    private let panel: QuotaPanel
    private let store: QuotaStore

    init(store: QuotaStore) {
        let size = NSSize(width: 316, height: 378)
        let origin = Self.defaultOrigin(for: size)
        let panel = QuotaPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        self.store = store
        super.init()

        panel.title = "Codex 额度"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: FloatingQuotaView(store: store))
        panel.delegate = self
        panel.setFrameAutosaveName("CodexQuotaFloatPanel")
        panel.setContentSize(size)
        panel.alphaValue = store.panelOpacity
        panel.ignoresMouseEvents = store.mousePassthrough

        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        store.visibilityHandler = { [weak self] visible in
            visible ? self?.show() : self?.hide()
        }
        store.passthroughHandler = { [weak self] enabled in
            self?.panel.ignoresMouseEvents = enabled
        }
        store.opacityHandler = { [weak self] opacity in
            self?.panel.alphaValue = opacity
        }
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        store.setPanelVisible(false)
        return false
    }

    private static func defaultOrigin(for size: NSSize) -> NSPoint {
        guard let frame = NSScreen.main?.visibleFrame else {
            return NSPoint(x: 80, y: 80)
        }
        return NSPoint(
            x: frame.maxX - size.width - 24,
            y: frame.maxY - size.height - 24
        )
    }
}

private final class QuotaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseUp {
            snapToVisibleEdge()
        }
    }

    private func snapToVisibleEdge() {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        var target = frame
        let threshold: CGFloat = 28
        let margin: CGFloat = 10

        if abs(frame.minX - visible.minX) < threshold {
            target.origin.x = visible.minX + margin
        } else if abs(frame.maxX - visible.maxX) < threshold {
            target.origin.x = visible.maxX - frame.width - margin
        }

        if abs(frame.minY - visible.minY) < threshold {
            target.origin.y = visible.minY + margin
        } else if abs(frame.maxY - visible.maxY) < threshold {
            target.origin.y = visible.maxY - frame.height - margin
        }

        if target.origin != frame.origin {
            setFrame(target, display: true, animate: true)
            saveFrame(usingName: "CodexQuotaFloatPanel")
        }
    }
}
