import AppKit
import SwiftUI

struct QuickOverlayActions {
    /// Returns true when the image landed on the clipboard.
    var copy: () -> Bool
    var annotate: () -> Void
    var save: () -> Void
    var pin: () -> Void
    var dismiss: () -> Void
    /// Deduped captures offer restore; a capture that was just restored offers undo.
    var stickyChip: OverlayStickyChip? = nil
    var onStickyChip: (() -> Void)? = nil
    /// Automatic dismissal stays off while the pointer is over the card.
    var pointerInside: ((Bool) -> Void)? = nil
}

/// ML10 completion chip. The two halves stay separate so the action is a button.
enum OverlayStickyChip: Equatable {
    case deduped
    case restored

    var leading: String {
        switch self {
        case .deduped: return StitchCopy.overlayDeduped
        case .restored: return StitchCopy.overlayRestored
        }
    }

    var actionTitle: String {
        switch self {
        case .deduped: return StitchCopy.restoreSticky
        case .restored: return StitchCopy.undoSticky
        }
    }

    var line: String { leading + StitchCopy.joiner + actionTitle }
}

enum OverlayDismissPolicy {
    /// An automatic hide is allowed only when the pointer is outside the card.
    static func allowsAutomaticDismiss(pointerInside: Bool) -> Bool {
        !pointerInside
    }
}

/// F3 · Quick Access Overlay. Shown after every capture in the bottom-left corner of the active screen.
/// Happy path: hotkey (1) → select (2) → Copy / ↩ / ⌘C (3).
@MainActor
final class QuickOverlayController {
    private var panel: OverlayPanel?
    private var pointerInside = false

    var isVisible: Bool { panel?.isVisible == true }

    func dismissAutomatically() {
        guard OverlayDismissPolicy.allowsAutomaticDismiss(pointerInside: pointerInside) else { return }
        hide()
    }

    func show(image: NSImage, fileURL: URL, actions: QuickOverlayActions) {
        hide()

        pointerInside = false
        var wrapped = actions
        wrapped.dismiss = { [weak self] in
            actions.dismiss()
            self?.hide()
        }
        wrapped.pointerInside = { [weak self] inside in
            self?.pointerInside = inside
        }

        let view = QuickOverlayView(image: image, fileURL: fileURL, actions: wrapped)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.onEscape = wrapped.dismiss

        let visible = NSScreen.underMouse.visibleFrame
        let origin = NSPoint(x: visible.minX + 24, y: visible.minY + 24)
        panel.setFrameOrigin(NSPoint(x: origin.x - 30, y: origin.y))
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

final class OverlayPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
struct QuickOverlayView: View {
    let image: NSImage
    let fileURL: URL
    let actions: QuickOverlayActions

    @State private var copied = false
    @State private var pinned = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            thumbnail

            HStack(spacing: 8) {
                Button(copied ? "已复制" : "Copy") { copy() }
                    .buttonStyle(BloomPrimaryButtonStyle(success: copied, expand: true))
                    .keyboardShortcut(.defaultAction)
                    .help("复制到剪贴板（↩ 或 ⌘C）")

                Button("Annotate", action: actions.annotate)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut("e", modifiers: .command)
                    .help("打开编辑器标注 / 美化（⌘E）")

                Button(saved ? "已保存" : "Save") {
                    actions.save()
                    saved = true
                }
                .buttonStyle(GhostButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
                .help("保存 PNG 到保存文件夹（⌘S）")

                Button {
                    actions.pin()
                    pinned = true
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(IconGhostButtonStyle(active: pinned))
                .keyboardShortcut("p", modifiers: .command)
                .help("Pin 到桌面浮窗（⌘P）")

                Button(action: actions.dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconGhostButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("关闭（Esc）")
            }

            dragHandle
            if let chip = actions.stickyChip {
                HStack(spacing: 0) {
                    Text(chip.leading)
                    Text(StitchCopy.joiner)
                    Button(chip.actionTitle) { actions.onStickyChip?() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.ivory)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.ivoryMuted)
            }
        }
        .padding(12)
        .frame(width: 420)
        .background(FrostedChrome())
        .background(copyShortcut)
        .onHover { inside in actions.pointerInside?(inside) }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xF7F2EA), Color(hex: 0xE8DFD4)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: Palette.charcoal.opacity(0.18), radius: 8, y: 3)
                .padding(14)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .onDrag { dragProvider() }
        .help("拖到其它 App（Finder、聊天、文档…）")
    }

    private var dragHandle: some View {
        HStack(spacing: 8) {
            Capsule().fill(Color.white.opacity(0.28)).frame(width: 28, height: 4)
            Image(systemName: "hand.draw")
                .font(.system(size: 11))
            Text("Drag · 拖动缩略图或此手柄到其它 App")
                .font(.system(size: 11))
        }
        .foregroundStyle(Palette.ivoryMuted)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onDrag { dragProvider() }
    }

    /// ⌘C as a second route to the primary action.
    private var copyShortcut: some View {
        Button("") { copy() }
            .keyboardShortcut("c", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func dragProvider() -> NSItemProvider {
        NSItemProvider(contentsOf: fileURL) ?? NSItemProvider(object: image)
    }

    private func copy() {
        guard actions.copy() else { return }
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }
}
