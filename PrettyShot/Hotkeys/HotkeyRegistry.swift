import Combine
import Foundation

/// Grouping metadata supplied by whoever registers an external hotkey.
/// The app does not ship any built-in external group names.
struct HotkeyGroup: Hashable {
    let id: String
    let title: String
    let footnote: String?
    /// Built-in shortcuts stay first. External groups should use `order >= 100`.
    let order: Int

    init(id: String, title: String, footnote: String? = nil, order: Int) {
        self.id = id
        self.title = title
        self.footnote = footnote
        self.order = order
    }
}

/// Optional copy overrides. Nil fields fall back to the app's generic templates.
struct HotkeyCopy: Equatable {
    var registrationFailedTitle: String?
    var registrationFailedDetail: String?
    var inlineFailureHint: String?

    init(
        registrationFailedTitle: String? = nil,
        registrationFailedDetail: String? = nil,
        inlineFailureHint: String? = nil
    ) {
        self.registrationFailedTitle = registrationFailedTitle
        self.registrationFailedDetail = registrationFailedDetail
        self.inlineFailureHint = inlineFailureHint
    }
}

/// An action registered by another module. `id` is the persistence key.
struct ExternalHotkeyAction: Identifiable {
    let id: String
    let group: HotkeyGroup
    let title: String
    let subtitle: String?
    let defaultShortcut: Shortcut?
    let copy: HotkeyCopy
    let handler: @MainActor () -> Void

    init(
        id: String,
        group: HotkeyGroup,
        title: String,
        subtitle: String? = nil,
        defaultShortcut: Shortcut? = nil,
        copy: HotkeyCopy = HotkeyCopy(),
        handler: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.defaultShortcut = defaultShortcut
        self.copy = copy
        self.handler = handler
    }
}

enum HotkeyBindingID: Hashable {
    case builtin(HotkeyAction)
    case external(String)
}

/// External registration surface implemented by `HotkeyManager`.
@MainActor
protocol HotkeyRegistering: AnyObject {
    /// Registers an external action and tries its saved combo (or the default when nothing is saved).
    /// Failures are stored and published; this method does not throw.
    func register(_ action: ExternalHotkeyAction)
    func unregister(id: String)
    /// Current bindings that failed to register, built-in and external, in a stable order.
    var registrationFailures: AnyPublisher<[HotkeyBindingID], Never> { get }
}

struct HotkeySettingsRow: Identifiable, Equatable {
    var id: HotkeyBindingID
    var title: String
    var subtitle: String?
}

struct HotkeySettingsGroup: Identifiable, Equatable {
    var id: String
    var title: String
    var footnote: String?
    var rows: [HotkeySettingsRow]
}
