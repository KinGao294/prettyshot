import AppKit
import SwiftUI

/// Click → press a new combo. Esc cancels, ⌫ clears (disables) the action.
/// Global hotkeys are suspended while a new combo is being captured, so the current one can be entered again.
@MainActor
struct ShortcutRecorder: View {
    let id: HotkeyBindingID
    @ObservedObject var hotkeys: HotkeyManager

    @State private var isListening = false
    @State private var monitor: Any?
    @State private var message: String?
    @State private var messageIncludesHint = false

    init(action: HotkeyAction, hotkeys: HotkeyManager) {
        self.id = .builtin(action)
        self.hotkeys = hotkeys
    }

    init(id: HotkeyBindingID, hotkeys: HotkeyManager) {
        self.id = id
        self.hotkeys = hotkeys
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    isListening ? stop() : start()
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(isListening ? Palette.bloomDeep : Palette.charcoal)
                        .frame(minWidth: 110)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isListening ? Palette.bloomRose.opacity(0.15) : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(isListening ? Palette.bloomRose : Palette.borderLight, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("点击后按下新的快捷键；Esc 取消，⌫ 清除")

                if hotkeys.shortcut(for: id) != hotkeys.defaultShortcut(for: id) {
                    Button {
                        stop()
                        apply(hotkeys.setShortcut(hotkeys.defaultShortcut(for: id), for: id))
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("恢复默认 \(hotkeys.defaultShortcut(for: id)?.displayString ?? "")")
                }
            }

            if let error = displayedError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.bloomDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stop() }
    }

    private var label: String {
        if isListening { return "请按下快捷键…" }
        return hotkeys.shortcut(for: id)?.displayString ?? "未设置"
    }

    private var displayedError: String? {
        if let message {
            return messageIncludesHint ? withHint(message) : message
        }
        guard let registered = hotkeys.registrationMessage(for: id) else { return nil }
        return withHint(registered)
    }

    private func withHint(_ base: String) -> String {
        guard let hint = hotkeys.inlineFailureHint(for: id), !hint.isEmpty else { return base }
        return "\(base) \(hint)"
    }

    private func start(preserveMessage: Bool = false) {
        if !preserveMessage {
            message = nil
            messageIncludesHint = false
        }
        isListening = true
        hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        guard isListening else { return }
        isListening = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hotkeys.resume()
    }

    private func apply(_ error: ShortcutValidationError?) {
        guard let error else {
            message = nil
            messageIncludesHint = false
            return
        }
        message = error.errorDescription
        switch error {
        case .inUseByOtherApp:
            messageIncludesHint = true
            NSSound.beep()
            start(preserveMessage: true)
        case .registrationFailed:
            messageIncludesHint = true
        default:
            messageIncludesHint = false
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 53 where flags.isEmpty: // Esc
            stop()
            return
        case 51 where flags.isEmpty, 117 where flags.isEmpty: // ⌫ / ⌦
            hotkeys.setShortcut(nil, for: id)
            stop()
            return
        default:
            break
        }
        let candidate = Shortcut(event: event)
        if let error = ShortcutValidator.validate(
            candidate,
            for: id,
            builtin: hotkeys.bindings,
            external: hotkeys.externalBindings,
            titleOf: { hotkeys.title(of: $0) }
        ) {
            message = error.errorDescription
            messageIncludesHint = false
            NSSound.beep()
            return // keep listening so the user can try another combo
        }
        stop()
        apply(hotkeys.setShortcut(candidate, for: id))
    }
}
