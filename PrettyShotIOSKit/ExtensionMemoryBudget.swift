import CoreGraphics
import Foundation
import ImageIO

/// Share Extension memory plan for AC-I17.
///
/// A 12MP RGBA buffer is 12e6 × 4 = 48MB. Three of them (source, redacted copy, canvas) are 144MB,
/// over the ~120MB extension cap. The extension therefore:
/// 1. reads pixel size from the image header, without decoding a bitmap
/// 2. keeps one downscaled preview (long side ≤ 1280) while editing
/// 3. releases that preview before the export decode
/// 4. decodes one full-size image, bakes redaction into it, and draws the beautified result
///
/// Full resolution stays inline while two RGBA copies fit under the cap (12MP × 2 × 4 = 96MB).
/// Larger images hand off to the app when an App Group is available; otherwise the extension
/// saves the preview-resolution image and says so.
enum ExtensionMemoryBudget {
    static let limitBytes = 120 * 1024 * 1024
    static let bytesPerPixel = 4
    static let previewMaxLongSide = 1280
    /// Stitch input cap for the skeleton. Full-width export waits on the M4 device measurement.
    static let stitchInputMaxLongSide = 1600
    static let fullSizeCopiesWhileExporting = 2
    static let forbiddenSimultaneousFullSizeCopies = 3

    enum Plan: Equatable {
        case fullResolutionInline
        case handoffToApp
        case previewResolutionInline
    }

    static func rgbaBytes(pixels: Int, copies: Int) -> Int {
        max(0, pixels) * bytesPerPixel * max(0, copies)
    }

    static func previewPixelCount(width: Int, height: Int, maxLongSide: Int = previewMaxLongSide) -> Int {
        scaledCount(width: width, height: height, maxLongSide: maxLongSide)
    }

    static func plan(pixelCount: Int, canTransferToApp: Bool) -> Plan {
        let exportBytes = rgbaBytes(pixels: pixelCount, copies: fullSizeCopiesWhileExporting)
        if exportBytes <= limitBytes {
            return .fullResolutionInline
        }
        if canTransferToApp {
            return .handoffToApp
        }
        return .previewResolutionInline
    }

    private static func scaledCount(width: Int, height: Int, maxLongSide: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let longSide = max(width, height)
        guard longSide > maxLongSide, maxLongSide > 0 else { return width * height }
        let scale = Double(maxLongSide) / Double(longSide)
        let scaledWidth = max(1, Int((Double(width) * scale).rounded()))
        let scaledHeight = max(1, Int((Double(height) * scale).rounded()))
        return scaledWidth * scaledHeight
    }
}

/// ImageIO thumbnail path. Pixel size comes from the header; the preview never decodes 12MP.
enum ImagePrep {
    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard let width, let height, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func downsample(_ data: Data, maxLongSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxLongSide),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
