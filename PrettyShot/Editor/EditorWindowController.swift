import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let document: EditorDocument
    var onClose: ((EditorWindowController) -> Void)?

    init(document: EditorDocument, actions: EditorActions) {
        self.document = document
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PrettyShot Editor"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 860, height: 540)
        window.contentViewController = NSHostingController(rootView: EditorView(doc: document, actions: actions))
        window.setContentSize(Self.initialContentSize(for: document))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    /// Size the window around the shot (plus rail + drawer), within the visible screen.
    private static func initialContentSize(for document: EditorDocument) -> NSSize {
        let visible = NSScreen.underMouse.visibleFrame
        let imageWidth = CGFloat(document.original.width) / document.scale
        let imageHeight = CGFloat(document.original.height) / document.scale
        let width = min(max(imageWidth + 60 + 264 + 140, 960), visible.width * 0.9)
        let height = min(max(imageHeight + 56 + 140, 620), visible.height * 0.9)
        return NSSize(width: width, height: height)
    }
}
