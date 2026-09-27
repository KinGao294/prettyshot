import AppKit
import SwiftUI

/// Light, non-blocking toast (DESIGN §5.2): ivory surface, charcoal text, auto-hides, click to dismiss.
@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()

    enum Style {
        case info, success, error

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: return Palette.muted
            case .success: return Palette.softMint
            case .error: return Palette.bloomDeep
            }
        }
    }

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ message: String, style: Style = .info, duration: TimeInterval = 2.2) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let view = ToastView(message: message, style: style) { [weak self] in self?.hide() }
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host

        let screen = NSScreen.underMouse
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24))
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
private struct ToastView: View {
    let message: String
    let style: ToastPresenter.Style
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.tint)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.charcoal)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Palette.ivory)
                .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
        )
        .overlay(Capsule(style: .continuous).strokeBorder(Palette.borderLight, lineWidth: 1))
        .padding(16) // room for the shadow inside the borderless panel
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

extension NSScreen {
    /// The screen currently containing the mouse pointer (falls back to main / first).
    static var underMouse: NSScreen {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
