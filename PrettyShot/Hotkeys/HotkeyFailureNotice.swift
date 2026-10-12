import AppKit
import SwiftUI

/// Generic copy for hotkeys that failed to register at launch. Manual edits in Settings do not use this notice.
struct HotkeyFailureNoticeContent: Equatable {
    var title: String
    var detail: String

    struct Item: Equatable {
        var shortcut: String
        var title: String
        var registrationFailedTitle: String?
        var registrationFailedDetail: String?
    }

    static let singleDetail = "在那之前可以从菜单栏使用。"
    static let multipleDetail = "请到「设置 › 快捷键」更换。"
    static let changeButton = "去更换"
    static let laterButton = "稍后"
    static let autoDismiss: TimeInterval = 8
    /// Shown on a menu shortcut capsule while that binding failed to register.
    static let inactiveCapsule = "未生效"

    static func make(items: [Item]) -> HotkeyFailureNoticeContent? {
        guard !items.isEmpty else { return nil }
        if items.count == 1, let item = items.first {
            let prefix = item.shortcut.isEmpty ? "" : "\(item.shortcut) "
            let genericTitle = "\(prefix)被其他 App 占用，\(item.title)快捷键暂不可用"
            return HotkeyFailureNoticeContent(
                title: item.registrationFailedTitle ?? genericTitle,
                detail: item.registrationFailedDetail ?? singleDetail
            )
        }
        return HotkeyFailureNoticeContent(
            title: "\(items.count) 个快捷键被其他 App 占用",
            detail: multipleDetail
        )
    }
}

@MainActor
struct HotkeyFailureNotice: View {
    let content: HotkeyFailureNoticeContent
    let onChange: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(content.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.charcoal)
                .fixedSize(horizontal: false, vertical: true)
            if !content.detail.isEmpty {
                Text(content.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(HotkeyFailureNoticeContent.changeButton, action: onChange)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.bloomDeep)
                Button(HotkeyFailureNoticeContent.laterButton, action: onLater)
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.ivory)
                .shadow(color: Color.black.opacity(0.16), radius: 14, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.borderLight, lineWidth: 1)
        )
        .padding(16)
    }
}

/// Lightweight panel. Auto-hides after 8 seconds; the menu-bar dot stays until registration succeeds.
@MainActor
final class HotkeyFailureNoticePresenter {
    static let shared = HotkeyFailureNoticePresenter()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ content: HotkeyFailureNoticeContent, onChange: @escaping @MainActor () -> Void) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let view = HotkeyFailureNotice(
            content: content,
            onChange: { [weak self] in
                self?.hide()
                onChange()
            },
            onLater: { [weak self] in
                self?.hide()
            }
        )
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

        let visible = NSScreen.underMouse.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - 12,
            y: visible.maxY - size.height - 8
        ))
        panel.orderFrontRegardless()
        self.panel = panel

        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(HotkeyFailureNoticeContent.autoDismiss * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
