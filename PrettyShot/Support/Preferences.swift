import Foundation

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults

    private enum Key {
        static let saveDirectory = "prefs.saveDirectory"
        static let background = "prefs.background.v1"
        static let copySoundEnabled = "prefs.copySound"
    }

    /// Where Overlay "Save" writes PNGs (default: ~/Downloads, per the prototype).
    @Published var saveDirectory: URL {
        didSet { defaults.set(saveDirectory.path, forKey: Key.saveDirectory) }
    }

    /// Last used beautify settings, restored in every new editor.
    @Published var background: BackgroundStyle {
        didSet {
            if let data = try? JSONEncoder().encode(background) {
                defaults.set(data, forKey: Key.background)
            }
        }
    }

    @Published var copySoundEnabled: Bool {
        didSet { defaults.set(copySoundEnabled, forKey: Key.copySoundEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let path = defaults.string(forKey: Key.saveDirectory) {
            saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        if let data = defaults.data(forKey: Key.background),
           let stored = try? JSONDecoder().decode(BackgroundStyle.self, from: data) {
            background = stored
        } else {
            background = .default
        }
        copySoundEnabled = defaults.object(forKey: Key.copySoundEnabled) as? Bool ?? true
    }
}
