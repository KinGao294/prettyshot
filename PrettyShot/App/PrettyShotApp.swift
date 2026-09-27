import AppKit
import SwiftUI

@main
struct PrettyShotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // PrettyShot is a menu bar agent (LSUIElement). The status item, popover and all windows are
        // owned by AppCoordinator; the Settings scene is the standard ⌘, entry point.
        Settings {
            SettingsView(
                preferences: AppCoordinator.shared.preferences,
                hotkeys: AppCoordinator.shared.hotkeys,
                permissions: AppCoordinator.shared.permissions,
                history: AppCoordinator.shared.history
            )
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppCoordinator.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCoordinator.shared.stop()
    }

    /// Re-opening the app from Finder/Spotlight while it's running shows the popover's main entry: History.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppCoordinator.shared.showHistory() }
        return true
    }
}
