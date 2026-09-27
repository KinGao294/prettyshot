import AppKit
import Carbon.HIToolbox
import Combine

/// Global hotkeys via Carbon `RegisterEventHotKey` — works without Accessibility permission and
/// fails loudly (eventHotKeyExistsErr) when another app already owns a combo, which we surface in Settings.
@MainActor
final class HotkeyManager: ObservableObject {
    /// Current bindings; an action missing from the map is disabled.
    @Published private(set) var bindings: [HotkeyAction: Shortcut] = [:]
    /// Per-action registration problems (conflicts with other apps etc.).
    @Published private(set) var registrationErrors: [HotkeyAction: String] = [:]

    var onTrigger: ((HotkeyAction) -> Void)?

    private let defaults: UserDefaults
    private static let storageKey = "hotkeys.v1"
    private static let signature: OSType = 0x5053_6874 // 'PSht'

    private var hotKeyRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private var suspended = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bindings = Self.loadBindings(from: defaults)
    }

    func shortcut(for action: HotkeyAction) -> Shortcut? {
        bindings[action]
    }

    func displayString(for action: HotkeyAction) -> String {
        bindings[action]?.displayString ?? ""
    }

    /// Validates, stores and re-registers. Passing `nil` disables the action.
    @discardableResult
    func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction) -> ShortcutValidationError? {
        if let shortcut, let error = ShortcutValidator.validate(shortcut, for: action, existing: bindings) {
            return error
        }
        bindings[action] = shortcut
        save()
        reregister()
        return nil
    }

    func resetToDefaults() {
        bindings = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultShortcut) })
        save()
        reregister()
    }

    /// Temporarily release all combos (e.g. while the Settings recorder listens for a new one).
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        suspended = false
        registerAll()
    }

    func registerAll() {
        guard !suspended else { return }
        installHandlerIfNeeded()
        unregisterAll()
        var errors: [HotkeyAction: String] = [:]
        for (index, action) in HotkeyAction.allCases.enumerated() {
            guard let shortcut = bindings[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs[action] = ref
            } else if status == OSStatus(eventHotKeyExistsErr) {
                errors[action] = "与其它 App 的全局快捷键冲突，请在上方重新设置"
            } else {
                errors[action] = "注册失败（\(status)）"
            }
        }
        registrationErrors = errors
    }

    func unregisterAll() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    // MARK: - Private

    private func reregister() {
        if !suspended { registerAll() }
    }

    fileprivate func handleHotKey(id: UInt32) {
        let index = Int(id) - 1
        guard HotkeyAction.allCases.indices.contains(index) else { return }
        onTrigger?(HotkeyAction.allCases[index])
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &eventType, userData, &eventHandler)
    }

    // MARK: Persistence

    /// Stored as action → optional shortcut; an explicit `nil` means "disabled by the user".
    private struct Stored: Codable {
        var shortcut: Shortcut?
    }

    private static func loadBindings(from defaults: UserDefaults) -> [HotkeyAction: Shortcut] {
        var result = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultShortcut) })
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return result }
        for (key, value) in stored {
            guard let action = HotkeyAction(rawValue: key) else { continue }
            if let shortcut = value.shortcut, !shortcut.isSystemScreenshotShortcut {
                result[action] = shortcut
            } else {
                result.removeValue(forKey: action)
            }
        }
        return result
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0.rawValue, Stored(shortcut: bindings[$0])) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// C callback; must not capture context. `userData` is the (unretained) HotkeyManager.
private func hotKeyCallback(_ handler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { manager.handleHotKey(id: id) }
    }
    return noErr
}
