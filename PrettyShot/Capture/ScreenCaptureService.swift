import AppKit
import ScreenCaptureKit

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case region, window, fullscreen

    var id: String { rawValue }

    /// Chip label in the Capture HUD (F2).
    var chipTitle: String {
        switch self {
        case .region: return "区域"
        case .window: return "窗口"
        case .fullscreen: return "全屏"
        }
    }

    /// Row label in the menu bar popover (F1).
    var menuTitle: String {
        switch self {
        case .region: return "捕获区域"
        case .window: return "捕获窗口"
        case .fullscreen: return "捕获全屏"
        }
    }

    var symbol: String {
        switch self {
        case .region: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        }
    }
}

struct CaptureResult {
    let image: CGImage
    /// Pixels per point of the source display.
    let scale: CGFloat
    let mode: CaptureMode
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "PrettyShot 没有屏幕录制权限"
        case .noDisplay: return "找不到可捕获的显示器"
        case .failed(let reason): return "捕获失败：\(reason)"
        }
    }
}

/// A frozen frame of one screen, captured before the HUD appears so the HUD never
/// ends up in the screenshot and region/window picking works on a still image.
struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage
    var scale: CGFloat { CGFloat(image.width) / max(screen.frame.width, 1) }
}

/// Thin async wrapper around ScreenCaptureKit (macOS 14 `SCScreenshotManager`).
@MainActor
final class ScreenCaptureService {
    func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.map(error)
        }
    }

    /// Captures every connected screen, excluding PrettyShot's own windows (overlay, pins, toasts).
    func snapshotAllScreens(content: SCShareableContent) async throws -> [ScreenSnapshot] {
        var snapshots: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let display = display(for: screen, in: content) else { continue }
            let image = try await captureDisplay(display, content: content)
            snapshots.append(ScreenSnapshot(screen: screen, image: image))
        }
        if snapshots.isEmpty { throw CaptureError.noDisplay }
        return snapshots
    }

    func captureScreen(_ screen: NSScreen, content: SCShareableContent) async throws -> CaptureResult {
        guard let display = display(for: screen, in: content) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let image = try await captureDisplay(display, content: content)
        return CaptureResult(image: image, scale: CGFloat(image.width) / CGFloat(max(display.width, 1)), mode: .fullscreen)
    }

    /// Captures a single window independent of what overlaps it (keeps rounded-corner alpha).
    func captureWindow(_ window: SCWindow) async throws -> CaptureResult {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = configuration(for: filter)
        config.ignoreShadowsSingleWindow = true
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return CaptureResult(image: image, scale: CGFloat(filter.pointPixelScale), mode: .window)
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - Private

    private func captureDisplay(_ display: SCDisplay, content: SCShareableContent) async throws -> CGImage {
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = configuration(for: filter)
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw Self.map(error)
        }
    }

    private func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }

    private func display(for screen: NSScreen, in content: SCShareableContent) -> SCDisplay? {
        guard let id = screen.displayID else { return nil }
        return content.displays.first { $0.displayID == id }
    }

    /// Never report a black/empty frame as success — map TCC denials to a readable error (P3).
    nonisolated static func map(_ error: Error) -> CaptureError {
        if let captureError = error as? CaptureError { return captureError }
        if let scError = error as? SCStreamError, scError.code == .userDeclined {
            return .permissionDenied
        }
        if !CGPreflightScreenCaptureAccess() {
            return .permissionDenied
        }
        return .failed(error.localizedDescription)
    }
}
