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
/// Editing and handoff keep the file URL or encoded bytes plus one preview. They do not decode
/// a second full-size bitmap. A larger image is handed off as that file, or the extension asks
/// before saving a preview.
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

    /// Editing / handoff. The preview is the only decoded bitmap.
    static func inlineEditingHold(pixelCount: Int, previewPixels: Int) -> MemoryHold {
        precondition(pixelCount >= 0)
        return MemoryHold(
            fullDecodedCopies: 0,
            estimatedBytes: rgbaBytes(pixels: previewPixels, copies: 1),
            passesFileWithoutDecode: true
        )
    }

    /// Full export after the preview is released: one source decode and one output.
    static func fullExportHold(pixelCount: Int) -> MemoryHold {
        MemoryHold(
            fullDecodedCopies: fullSizeCopiesWhileExporting,
            estimatedBytes: rgbaBytes(pixels: pixelCount, copies: fullSizeCopiesWhileExporting),
            passesFileWithoutDecode: false
        )
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

    struct MemoryHold: Equatable {
        var fullDecodedCopies: Int
        var estimatedBytes: Int
        /// Handoff passes the file URL or encoded bytes and does not decode a full bitmap.
        var passesFileWithoutDecode: Bool
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(source)
    }

    static func pixelSize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(source)
    }

    static func downsample(_ data: Data, maxLongSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsample(source, maxLongSide: maxLongSide)
    }

    static func downsample(_ url: URL, maxLongSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return downsample(source, maxLongSide: maxLongSide)
    }

    private static func pixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard let width, let height, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func downsample(_ source: CGImageSource, maxLongSide: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxLongSide),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
