import AppKit
import Carbon.HIToolbox
import Combine

/// Global hotkeys via Carbon `RegisterEventHotKey` — works without Accessibility permission and
/// fails loudly (eventHotKeyExistsErr) when another app already owns a combo, which we surface in Settings.
@MainActor
final class HotkeyManager: ObservableObject, HotkeyRegistering {
    /// Current bindings; an action missing from the map is disabled.
    @Published private(set) var bindings: [HotkeyAction: Shortcut] = [:]
    /// Per-action registration problems (conflicts with other apps etc.). Built-in actions only.
    @Published private(set) var registrationErrors: [HotkeyAction: String] = [:]
    /// Saved combos for registered external actions. Missing means disabled.
    @Published private(set) var externalBindings: [String: Shortcut] = [:]
    /// Registration problems for external actions, keyed by `ExternalHotkeyAction.id`.
    @Published private(set) var externalRegistrationErrors: [String: String] = [:]
    /// Settings sections for registered external actions. Empty means the settings page draws none.
    @Published private(set) var externalSettingsGroups: [HotkeySettingsGroup] = []

    var onTrigger: ((HotkeyAction) -> Void)?
    /// Fired by the temporary bare-Esc hotkey (see `beginEscapeMonitoring`).
    var onEscape: (() -> Void)?

    private let defaults: UserDefaults
    private let registrar: HotkeyRegistrar
    private static let storageKey = "hotkeys.v1"
    private static let externalStorageKey = "hotkeys.external.v1"

    private var refs: [HotkeyBindingID: EventHotKeyRef] = [:]
    private var escapeRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var suspended = false

    private var externalActions: [String: ExternalHotkeyAction] = [:]
    private var externalOrder: [String] = []
    private var externalCarbonIDs: [String: UInt32] = [:]
    private var nextExternalCarbonID: UInt32 = HotkeyCarbon.externalBase
    /// Disk image of `hotkeys.external.v1`, including ids whose module is not loaded.
    private var persistedExternal: [String: Stored] = [:]

    private let registrationFailuresSubject = CurrentValueSubject<[HotkeyBindingID], Never>([])
    var registrationFailures: AnyPublisher<[HotkeyBindingID], Never> {
        registrationFailuresSubject.eraseToAnyPublisher()
    }

    init(defaults: UserDefaults = .standard, registrar: HotkeyRegistrar? = nil) {
        self.defaults = defaults
        self.registrar = registrar ?? CarbonHotkeyRegistrar()
        self.bindings = Self.loadBindings(from: defaults)
        self.persistedExternal = Self.loadExternal(from: defaults)
    }

    func shortcut(for action: HotkeyAction) -> Shortcut? {
        bindings[action]
    }

    func shortcut(for id: HotkeyBindingID) -> Shortcut? {
        switch id {
        case .builtin(let action): return bindings[action]
        case .external(let key): return externalBindings[key]
        }
    }

    func displayString(for action: HotkeyAction) -> String {
        bindings[action]?.displayString ?? ""
    }

    /// Menu capsule. Failed registrations read as inactive; a working combo keeps its usual label.
    func menuHint(for id: HotkeyBindingID) -> String {
        if isRegistrationIneffective(id) { return HotkeyFailureNoticeContent.inactiveCapsule }
        return shortcut(for: id)?.displayString ?? ""
    }

    func menuHint(for action: HotkeyAction) -> String {
        menuHint(for: .builtin(action))
    }

    func isRegistrationIneffective(_ id: HotkeyBindingID) -> Bool {
        switch id {
        case .builtin(let action): return registrationErrors[action] != nil
        case .external(let key): return externalRegistrationErrors[key] != nil
        }
    }

    func registrationMessage(for id: HotkeyBindingID) -> String? {
        switch id {
        case .builtin(let action): return registrationErrors[action]
        case .external(let key): return externalRegistrationErrors[key]
        }
    }

    func inlineFailureHint(for id: HotkeyBindingID) -> String? {
        guard case .external(let key) = id else { return nil }
        return externalActions[key]?.copy.inlineFailureHint
    }

    func defaultShortcut(for id: HotkeyBindingID) -> Shortcut? {
        switch id {
        case .builtin(let action): return action.defaultShortcut
        case .external(let key): return externalActions[key]?.defaultShortcut
        }
    }

    func title(of id: HotkeyBindingID) -> String {
        switch id {
        case .builtin(let action): return action.title
        case .external(let key): return externalActions[key]?.title ?? key
        }
    }

    func failureNoticeContent() -> HotkeyFailureNoticeContent? {
        let items = currentFailureIDs().map { id in
            HotkeyFailureNoticeContent.Item(
                shortcut: shortcut(for: id)?.displayString ?? "",
                title: title(of: id),
                registrationFailedTitle: externalCopy(for: id)?.registrationFailedTitle,
                registrationFailedDetail: externalCopy(for: id)?.registrationFailedDetail
            )
        }
        return HotkeyFailureNoticeContent.make(items: items)
    }

    /// Validates, stores and re-registers. Passing `nil` disables the action.
    @discardableResult
    func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction) -> ShortcutValidationError? {
        setShortcut(shortcut, for: .builtin(action))
    }

    /// Manual change. While suspended (or when clearing a combo) this saves immediately, matching the
    /// historical path. Otherwise the combo is registered first and saved only after Carbon accepts it.
    @discardableResult
    func setShortcut(_ shortcut: Shortcut?, for id: HotkeyBindingID) -> ShortcutValidationError? {
        if let shortcut, let error = ShortcutValidator.validate(
            shortcut,
            for: id,
            builtin: bindings,
            external: externalBindings,
            titleOf: { self.title(of: $0) }
        ) {
            return error
        }
        guard !suspended, let shortcut else {
            store(shortcut, for: id)
            save(id)
            reregister()
            return nil
        }
        let previous = self.shortcut(for: id)
        unregisterBinding(id)
        guard let carbonID = carbonID(for: id) else {
            store(shortcut, for: id)
            save(id)
            return nil
        }
        installHandlerIfNeeded()
        switch registrar.register(shortcut, carbonID: carbonID) {
        case .success(let ref):
            refs[id] = ref
            store(shortcut, for: id)
            save(id)
            clearError(for: id)
            return nil
        case .failure(let status):
            if let previous, case .success(let ref) = registrar.register(previous, carbonID: carbonID) {
                refs[id] = ref
            }
            if status == OSStatus(eventHotKeyExistsErr) {
                return .inUseByOtherApp
            }
            return .registrationFailed(status)
        }
    }

    func resetToDefaults() {
        bindings = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultShortcut) })
        saveBuiltin()
        reregister()
    }

    func register(_ action: ExternalHotkeyAction) {
        let isNew = externalActions[action.id] == nil
        externalActions[action.id] = action
        if isNew {
            externalOrder.append(action.id)
            externalCarbonIDs[action.id] = allocateExternalCarbonID()
            applyPersistedBinding(for: action)
        }
        refreshExternalSettingsGroups()
        guard !suspended else { return }
        installHandlerIfNeeded()
        if refs[.external(action.id)] == nil {
            bindExternal(action.id)
            publishFailures()
        }
    }

    func unregister(id: String) {
        unregisterBinding(.external(id))
        externalActions[id] = nil
        externalOrder.removeAll { $0 == id }
        externalCarbonIDs[id] = nil
        externalBindings[id] = nil
        externalRegistrationErrors[id] = nil
        refreshExternalSettingsGroups()
        publishFailures()
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
            switch registrar.register(shortcut, carbonID: UInt32(index + 1)) {
            case .success(let ref):
                refs[.builtin(action)] = ref
            case .failure(let status):
                errors[action] = Self.message(forRegistrationStatus: status)
            }
        }
        registrationErrors = errors

        var externalErrors: [String: String] = [:]
        for id in externalOrder {
            guard let shortcut = externalBindings[id], let carbonID = externalCarbonIDs[id] else { continue }
            switch registrar.register(shortcut, carbonID: carbonID) {
            case .success(let ref):
                refs[.external(id)] = ref
            case .failure(let status):
                externalErrors[id] = Self.message(forRegistrationStatus: status)
            }
        }
        externalRegistrationErrors = externalErrors
        publishFailures()
    }

    func unregisterAll() {
        for ref in refs.values {
            registrar.unregister(ref)
        }
        refs.removeAll()
    }

    /// Grabs bare Esc system-wide while a capture is in flight, so Esc cancels even before the HUD
    /// has key focus (fullscreen capture never shows a HUD). Carbon hotkeys need no Accessibility permission.
    func beginEscapeMonitoring() {
        guard escapeRef == nil else { return }
        installHandlerIfNeeded()
        if case .success(let ref) = registrar.register(
            Shortcut(keyCode: kVK_Escape, modifiers: 0),
            carbonID: HotkeyCarbon.escapeID
        ) {
            escapeRef = ref
        }
    }

    func endEscapeMonitoring() {
        if let escapeRef { registrar.unregister(escapeRef) }
        escapeRef = nil
    }

    // MARK: - Private

    private func reregister() {
        if !suspended { registerAll() }
    }

    func handleHotKey(id: UInt32) {
        if id == HotkeyCarbon.escapeID {
            onEscape?()
            return
        }
        if id >= HotkeyCarbon.externalBase, let actionID = externalCarbonIDs.first(where: { $0.value == id })?.key {
            externalActions[actionID]?.handler()
            return
        }
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

    private func carbonID(for id: HotkeyBindingID) -> UInt32? {
        switch id {
        case .builtin(let action):
            guard let index = HotkeyAction.allCases.firstIndex(of: action) else { return nil }
            return UInt32(index + 1)
        case .external(let key):
            return externalCarbonIDs[key]
        }
    }

    private func allocateExternalCarbonID() -> UInt32 {
        if nextExternalCarbonID == HotkeyCarbon.escapeID {
            nextExternalCarbonID += 1
        }
        let id = nextExternalCarbonID
        nextExternalCarbonID += 1
        return id
    }

    private func unregisterBinding(_ id: HotkeyBindingID) {
        if let ref = refs.removeValue(forKey: id) {
            registrar.unregister(ref)
        }
    }

    private func bindExternal(_ id: String) {
        guard let carbonID = externalCarbonIDs[id] else { return }
        guard let shortcut = externalBindings[id] else {
            externalRegistrationErrors[id] = nil
            return
        }
        switch registrar.register(shortcut, carbonID: carbonID) {
        case .success(let ref):
            refs[.external(id)] = ref
            externalRegistrationErrors[id] = nil
        case .failure(let status):
            externalRegistrationErrors[id] = Self.message(forRegistrationStatus: status)
        }
    }

    private func store(_ shortcut: Shortcut?, for id: HotkeyBindingID) {
        switch id {
        case .builtin(let action):
            bindings[action] = shortcut
        case .external(let key):
            externalBindings[key] = shortcut
        }
    }

    private func save(_ id: HotkeyBindingID) {
        switch id {
        case .builtin: saveBuiltin()
        case .external: saveExternal()
        }
    }

    private func clearError(for id: HotkeyBindingID) {
        let removed: Bool
        switch id {
        case .builtin(let action):
            removed = registrationErrors.removeValue(forKey: action) != nil
        case .external(let key):
            removed = externalRegistrationErrors.removeValue(forKey: key) != nil
        }
        if removed { publishFailures() }
    }

    private func publishFailures() {
        registrationFailuresSubject.send(currentFailureIDs())
    }

    private func currentFailureIDs() -> [HotkeyBindingID] {
        var ids: [HotkeyBindingID] = []
        for action in HotkeyAction.allCases where registrationErrors[action] != nil {
            ids.append(.builtin(action))
        }
        for id in externalOrder where externalRegistrationErrors[id] != nil {
            ids.append(.external(id))
        }
        return ids
    }

    private func externalCopy(for id: HotkeyBindingID) -> HotkeyCopy? {
        guard case .external(let key) = id else { return nil }
        return externalActions[key]?.copy
    }

    private func applyPersistedBinding(for action: ExternalHotkeyAction) {
        if let stored = persistedExternal[action.id] {
            if let shortcut = stored.shortcut, !shortcut.isSystemScreenshotShortcut {
                externalBindings[action.id] = shortcut
            } else {
                externalBindings.removeValue(forKey: action.id)
            }
        } else if let shortcut = action.defaultShortcut, !shortcut.isSystemScreenshotShortcut {
            externalBindings[action.id] = shortcut
        }
    }

    private func refreshExternalSettingsGroups() {
        var buckets: [String: (group: HotkeyGroup, rows: [HotkeySettingsRow])] = [:]
        var seen: [String] = []
        for id in externalOrder {
            guard let action = externalActions[id] else { continue }
            let row = HotkeySettingsRow(id: .external(id), title: action.title, subtitle: action.subtitle)
            if buckets[action.group.id] == nil {
                buckets[action.group.id] = (action.group, [row])
                seen.append(action.group.id)
            } else {
                buckets[action.group.id]?.rows.append(row)
            }
        }
        externalSettingsGroups = seen.sorted { lhs, rhs in
            let left = buckets[lhs]!.group.order
            let right = buckets[rhs]!.group.order
            if left != right { return left < right }
            return seen.firstIndex(of: lhs)! < seen.firstIndex(of: rhs)!
        }.compactMap { key in
            guard let bucket = buckets[key], !bucket.rows.isEmpty else { return nil }
            return HotkeySettingsGroup(
                id: bucket.group.id,
                title: bucket.group.title,
                footnote: bucket.group.footnote,
                rows: bucket.rows
            )
        }
    }

    private static func message(forRegistrationStatus status: OSStatus) -> String {
        if status == OSStatus(eventHotKeyExistsErr) {
            return "与其它 App 的全局快捷键冲突，请在上方重新设置"
        }
        return "注册失败（\(status)）"
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

    private static func loadExternal(from defaults: UserDefaults) -> [String: Stored] {
        guard let data = defaults.data(forKey: externalStorageKey),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else { return [:] }
        return stored
    }

    private func saveBuiltin() {
        let stored = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0.rawValue, Stored(shortcut: bindings[$0])) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Writes registered external combos. Ids that are not currently registered stay on disk.
    private func saveExternal() {
        var stored = persistedExternal
        for id in externalActions.keys {
            stored[id] = Stored(shortcut: externalBindings[id])
        }
        persistedExternal = stored
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.externalStorageKey)
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
