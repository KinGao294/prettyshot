import AppKit
import SwiftUI

/// Owns the menu bar icon and the F1 popover.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private unowned let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()

        if let button = statusItem.button {
            button.image = BrandImages.menuBarIcon()
            button.toolTip = "PrettyShot"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: MenuPopoverView(coordinator: coordinator))
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        coordinator.permissions.refresh()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }
}

/// F1 · Menu Bar Popover (idle).
@MainActor
struct MenuPopoverView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var hotkeys: HotkeyManager
    @ObservedObject private var permissions: PermissionManager
    @ObservedObject private var pins: PinManager
    @ObservedObject private var history: HistoryStore

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.hotkeys = coordinator.hotkeys
        self.permissions = coordinator.permissions
        self.pins = coordinator.pins
        self.history = coordinator.history
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !permissions.screenCaptureGranted {
                permissionBanner
            }

            section {
                ForEach(CaptureMode.allCases) { mode in
                    MenuRow(symbol: mode.symbol, title: mode.menuTitle, hint: hotkeys.displayString(for: action(for: mode))) {
                        coordinator.startCapture(mode)
                    }
                }
            }

            divider

            section {
                MenuRow(symbol: "clock.arrow.circlepath", title: "历史", hint: hotkeys.displayString(for: .openHistory)) {
                    coordinator.showHistory()
                }
                MenuRow(symbol: "pin", title: "Pin 最近一张", hint: hotkeys.displayString(for: .pinLatest),
                        disabled: history.latest == nil) {
                    coordinator.pinLatest()
                }
                if !pins.pins.isEmpty {
                    if pins.clickThroughCount > 0 {
                        MenuRow(symbol: "cursorarrow.click", title: "恢复 Pin 可点击（\(pins.clickThroughCount)）", hint: "") {
                            pins.disableClickThroughEverywhere()
                        }
                    }
                    MenuRow(symbol: "pin.slash", title: "关闭全部 Pin（\(pins.pins.count)）", hint: "") {
                        pins.closeAll()
                    }
                }
                MenuRow(symbol: "gearshape", title: "设置", hint: "⌘,") {
                    coordinator.showSettings()
                }
            }

            divider

            section {
                MenuRow(symbol: "power", title: "退出 PrettyShot", hint: "⌘Q") {
                    NSApp.terminate(nil)
                }
            }

            Text("快捷键可在设置重映射 · 不占用 ⌘⇧3/4/5")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.ivoryMuted)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 12)
        }
        .frame(width: 296)
        .background(Palette.chrome.opacity(0.92))
        .background(hiddenShortcuts)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("PrettyShot")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.ivory)
                Text("PAPER BLOOM · V0.1")
                    .font(.system(size: 9.5, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(Palette.ivoryMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var permissionBanner: some View {
        Button {
            coordinator.showPermission(detail: nil)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Palette.bloomRose)
                VStack(alignment: .leading, spacing: 2) {
                    Text("需要屏幕录制权限")
                        .font(.system(size: 12, weight: .semibold))
                    Text("点此查看如何在系统设置中开启")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ivoryMuted)
                }
                Spacer()
            }
            .foregroundStyle(Palette.ivory)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.bloomRose.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var divider: some View {
        Rectangle().fill(Palette.borderDark).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 4)
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 2, content: content).padding(.horizontal, 6)
    }

    private var hiddenShortcuts: some View {
        ZStack {
            Button("") { coordinator.showSettings() }.keyboardShortcut(",", modifiers: .command)
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func action(for mode: CaptureMode) -> HotkeyAction {
        switch mode {
        case .region: return .captureRegion
        case .window: return .captureWindow
        case .fullscreen: return .captureFullscreen
        }
    }
}

@MainActor
private struct MenuRow: View {
    let symbol: String
    let title: String
    let hint: String
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hovering ? Palette.bloomRose : Palette.ivory.opacity(0.85))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ivory)
                Spacer()
                if !hint.isEmpty {
                    KeyHint(text: hint)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering && !disabled ? Palette.bloomRose.opacity(0.16) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovering = $0 }
    }
}
