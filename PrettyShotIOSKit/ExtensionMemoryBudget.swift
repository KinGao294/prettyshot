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
/// Export peak is four RGBA buffers at once: the source, the redacted copy, the beautify canvas,
/// and the shadow transparency layer. There is no tiled render in M3. Two buffers of a 12MP
/// image fit under 120MB; four do not (about 192MB), so that image is handed to the app.
/// Editing keeps the file URL plus one preview. Nothing is exported at preview size.
enum ExtensionMemoryBudget {
    static let limitBytes = 120 * 1024 * 1024
    static let bytesPerPixel = 4
    static let previewMaxLongSide = 1280
    /// Source + redacted + canvas + shadow layer.
    static let fullSizeCopiesWhileExporting = 4
    static let forbiddenSimultaneousFullSizeCopies = 3

    enum Plan: Equatable {
        case fullResolutionInline
        case handoffToApp
        /// The extension cannot pass the original file. The user reselects it in the app.
        case reselectInApp
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

    /// Bytes for the buffers that are alive together during a shadowed, redacted export.
    /// Canvas and the shadow layer use the output size; pass the source size when the canvas is not known yet.
    static func exportPeakBytes(sourcePixels: Int, canvasPixels: Int) -> Int {
        rgbaBytes(pixels: sourcePixels, copies: 2) + rgbaBytes(pixels: canvasPixels, copies: 2)
    }

    /// Full export after the preview is released. Counts the real peak, not two source copies.
    static func fullExportHold(pixelCount: Int) -> MemoryHold {
        MemoryHold(
            fullDecodedCopies: fullSizeCopiesWhileExporting,
            estimatedBytes: exportPeakBytes(sourcePixels: pixelCount, canvasPixels: pixelCount),
            passesFileWithoutDecode: false
        )
    }

    static func plan(pixelCount: Int, canTransferToApp: Bool) -> Plan {
        let exportBytes = exportPeakBytes(sourcePixels: pixelCount, canvasPixels: pixelCount)
        if exportBytes <= limitBytes {
            return .fullResolutionInline
        }
        if canTransferToApp {
            return .handoffToApp
        }
        return .reselectInApp
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

    /// Native pixel size. Used for export and stitch input, never a long-side cap.
    static func fullImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func fullImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func pixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard let width, let height, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Capture time from the file header, used to put a re-added shot back in order.
    static func captureDate(_ data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw)
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
