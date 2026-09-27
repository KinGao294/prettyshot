import AppKit
import SwiftUI

/// Click → press a new combo. Esc cancels, ⌫ clears (disables) the action.
/// Global hotkeys are suspended while recording so the current combo can be re-recorded.
@MainActor
struct ShortcutRecorder: View {
    let action: HotkeyAction
    @ObservedObject var hotkeys: HotkeyManager

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    isRecording ? stop() : start()
                } label: {
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(isRecording ? Palette.bloomDeep : Palette.charcoal)
                        .frame(minWidth: 110)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isRecording ? Palette.bloomRose.opacity(0.15) : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(isRecording ? Palette.bloomRose : Palette.borderLight, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("点击后按下新的快捷键；Esc 取消，⌫ 清除")

                if hotkeys.shortcut(for: action) != action.defaultShortcut {
                    Button {
                        message = hotkeys.setShortcut(action.defaultShortcut, for: action)?.errorDescription
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("恢复默认 \(action.defaultShortcut.displayString)")
                }
            }

            if let error = message ?? hotkeys.registrationErrors[action] {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.bloomDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stop() }
    }

    private var label: String {
        if isRecording { return "请按下快捷键…" }
        return hotkeys.shortcut(for: action)?.displayString ?? "未设置"
    }

    private func start() {
        message = nil
        isRecording = true
        hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hotkeys.resume()
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 53 where flags.isEmpty: // Esc
            stop()
            return
        case 51 where flags.isEmpty, 117 where flags.isEmpty: // ⌫ / ⌦
            hotkeys.setShortcut(nil, for: action)
            stop()
            return
        default:
            break
        }
        let candidate = Shortcut(event: event)
        if let error = ShortcutValidator.validate(candidate, for: action, existing: hotkeys.bindings) {
            message = error.errorDescription
            NSSound.beep()
            return // keep listening so the user can try another combo
        }
        stop()
        message = hotkeys.setShortcut(candidate, for: action)?.errorDescription
    }
}
