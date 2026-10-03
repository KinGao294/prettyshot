import AppKit
import CoreMedia
import CoreVideo
import PrettyShotCore
import ScreenCaptureKit

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case region, window, fullscreen, scrolling

    var id: String { rawValue }

    /// Chip label in the Capture HUD (F2).
    var chipTitle: String {
        switch self {
        case .region: return "区域"
        case .window: return "窗口"
        case .fullscreen: return "全屏"
        case .scrolling: return "滚动"
        }
    }

    /// Row label in the menu bar popover (F1).
    var menuTitle: String {
        switch self {
        case .region: return "捕获区域"
        case .window: return "捕获窗口"
        case .fullscreen: return "捕获全屏"
        case .scrolling: return "滚动捕获"
        }
    }

    var symbol: String {
        switch self {
        case .region: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        case .scrolling: return "arrow.up.and.down.square"
        }
    }
}

struct CaptureResult {
    let image: CGImage
    /// Pixels per point of the source display.
    let scale: CGFloat
    let mode: CaptureMode
    /// Shown after a scrolling capture that stopped itself (length cap). Nil for ordinary shots.
    var notice: String? = nil
    /// Kept when a confident sticky dedupe can still be restored. Nil for ordinary shots.
    var scrollingAssembly: ScrollAssembly? = nil
}

struct ScrollingReview {
    var scale: CGFloat
    var assembly: ScrollAssembly
    var notice: String?
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    /// Screen Recording was just granted and ScreenCaptureKit still returns black / empty frames.
    case notReady
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "PrettyShot 没有屏幕录制权限"
        case .noDisplay: return "找不到可捕获的显示器"
        case .notReady: return "屏幕录制权限刚生效，画面还没准备好，请再按一次捕获"
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
            guard let display = self.display(for: screen, in: content) else { continue }
            let image = try await captureDisplay(display, content: content)
            snapshots.append(ScreenSnapshot(screen: screen, image: image))
        }
        if snapshots.isEmpty { throw CaptureError.noDisplay }
        return snapshots
    }

    func captureScreen(_ screen: NSScreen, content: SCShareableContent) async throws -> CaptureResult {
        guard let display = self.display(for: screen, in: content) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let image = try await captureDisplay(display, content: content)
        return CaptureResult(image: image, scale: CGFloat(image.width) / CGFloat(max(display.width, 1)), mode: .fullscreen)
    }

    /// Filter + stream config for one rectangle of `screen`. `sourceRect` is in points, origin at the
    /// top-left of the display (see `ScrollingCaptureGeometry`). PrettyShot's own windows are excluded
    /// so the scrolling chrome is not part of the frame.
    func regionStreamSetup(
        for screen: NSScreen,
        sourceRect: CGRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await shareableContent()
        guard let display = self.display(for: screen, in: content) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = max(1, pixelWidth)
        config.height = max(1, pixelHeight)
        config.showsCursor = false
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 8)
        config.queueDepth = 3
        config.captureResolution = .best
        return (filter, config)
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

    /// True when the frame is (almost) pure black — what ScreenCaptureKit returns for a moment after a fresh grant.
    /// Only consulted right after a grant, so a genuinely black screen is not misreported in normal use.
    nonisolated static func looksBlank(_ image: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        for index in stride(from: 0, to: pixels.count, by: 4) where max(pixels[index], pixels[index + 1], pixels[index + 2]) > 3 {
            return false
        }
        return true
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
