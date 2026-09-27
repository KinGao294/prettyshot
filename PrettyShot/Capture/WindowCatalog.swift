import AppKit
import ScreenCaptureKit

/// A pickable on-screen window with its frame converted to Cocoa global coordinates.
struct CapturableWindow {
    let scWindow: SCWindow
    /// Cocoa global coordinates (origin bottom-left of the primary screen, y up).
    let frame: CGRect
    let title: String
    let appName: String
}

enum WindowCatalog {
    /// Normal app windows, ordered front-to-back so hover picks the topmost one.
    @MainActor
    static func windows(from content: SCShareableContent) -> [CapturableWindow] {
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        // CGWindowList is documented to return windows in front-to-back order; SCShareableContent is not.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []

        var result: [CapturableWindow] = []
        for entry in info {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let window = byID[CGWindowID(number.uint32Value)] else { continue }
            guard window.windowLayer == 0,
                  window.isOnScreen,
                  window.frame.width >= 40, window.frame.height >= 40,
                  window.owningApplication?.processID != ownPID else { continue }
            result.append(CapturableWindow(
                scWindow: window,
                frame: cocoaRect(fromQuartz: window.frame, primaryHeight: primaryHeight),
                title: window.title ?? "",
                appName: window.owningApplication?.applicationName ?? ""
            ))
        }
        return result
    }

    /// Quartz global (top-left origin, y down) → Cocoa global (bottom-left origin, y up).
    static func cocoaRect(fromQuartz rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
