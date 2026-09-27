import AppKit
import CoreGraphics

/// Screen Recording (TCC) state. PrettyShot never shows a silent black frame:
/// every capture checks this first and routes to the readable Permission screen (F7) instead.
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var screenCaptureGranted: Bool = CGPreflightScreenCaptureAccess()

    private static let requestedKey = "permissions.screenCaptureRequested"

    func refresh() {
        let granted = CGPreflightScreenCaptureAccess()
        if granted != screenCaptureGranted { screenCaptureGranted = granted }
    }

    /// Triggers the one-time system prompt, which also registers PrettyShot in the
    /// System Settings list so the user has something to toggle.
    func requestIfNeeded() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.requestedKey) {
            defaults.set(true, forKey: Self.requestedKey)
            _ = CGRequestScreenCaptureAccess()
        }
        refresh()
    }

    /// 系统设置 › 隐私与安全性 › 屏幕录制
    func openSystemSettings() {
        _ = CGRequestScreenCaptureAccess()
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    /// macOS often only applies a fresh Screen Recording grant after relaunch.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
