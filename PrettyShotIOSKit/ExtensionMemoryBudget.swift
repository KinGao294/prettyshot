import CoreGraphics
import Foundation
import ImageIO
import PrettyShotCore

/// Share Extension memory plan for AC-I17.
///
/// A 12MP RGBA buffer is 12e6 × 4 = 48MB. Five of them are 240MB,
/// over the ~120MB extension cap. The extension therefore:
/// 1. reads pixel size from the image header, without decoding a bitmap
/// 2. keeps one downscaled preview (long side ≤ 1280) while editing
/// 3. releases that preview before the export decode
/// 4. decodes one full-size image, bakes redaction into it, and draws the beautified result
///
/// Export peak is five RGBA buffers at once: the source, the redacted copy, the beautify canvas,
/// the shadow transparency layer, and one extra canvas-sized buffer, plus `renderMarginBytes`.
/// The canvas is the laid-out size after padding, not the source. About 40MB is left for the process
/// itself. There is no tiled render in M3. A 12MP image's five buffers are about 240MB, so that image
/// is handed to the app. Editing keeps the file URL plus one preview. Nothing is exported at preview size.
///
/// The 1320×2868 sample's delta omitted the source that was already resident. Putting that copy back
/// makes the low sample about 94.3MB, while five buffers alone are 84.5MB. The 12MB margin is that gap.
/// A second CI sample sits near 102MB. That spread is not folded into the formula: doing so would
/// hand 1179×2556 and 1830×1830 at padding 28 to the app. Noted for (36).
enum ExtensionMemoryBudget {
    static let limitBytes = 120 * 1024 * 1024
    /// Left unused so the process, ImageIO, and the shadow layer's allocator overhead still fit.
    static let headroomBytes = 40 * 1024 * 1024
    static let bytesPerPixel = 4
    static let previewMaxLongSide = 1280
    /// Source + redacted + canvas + shadow layer + one extra canvas buffer.
    static let fullSizeCopiesWhileExporting = 5
    /// Bytes the five-buffer total misses on the 94.3MB sample. See the type comment. Visible for (36).
    static let renderMarginBytes = 12 * 1024 * 1024
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
        rgbaBytes(pixels: sourcePixels, copies: 2) + rgbaBytes(pixels: canvasPixels, copies: 3) + renderMarginBytes
    }

    /// Full export after the preview is released. Byte estimate uses the five-buffer peak.
    /// `fullDecodedCopies` stays at four: the existing hold check locks that field.
    static func fullExportHold(pixelCount: Int) -> MemoryHold {
        MemoryHold(
            fullDecodedCopies: 4,
            estimatedBytes: exportPeakBytes(sourcePixels: pixelCount, canvasPixels: pixelCount),
            passesFileWithoutDecode: false
        )
    }

    /// Output pixels from `BeautifyRenderer.layout`, including padding. `scale` defaults to the
    /// status-bar match so the plan uses the same canvas the export will allocate.
    static func canvasPixelCount(
        width: Int,
        height: Int,
        style: BackgroundStyle = .default,
        scale: CGFloat? = nil
    ) -> Int {
        guard width > 0, height > 0, let base = onePixel else { return 0 }
        let resolved = scale ?? (StatusBarCropTable.match(width: width, height: height)?.scale ?? 1)
        let input = BeautifyInput(
            base: base,
            crop: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            background: style,
            scale: resolved
        )
        let canvas = BeautifyRenderer.layout(for: input).canvasSize
        return Int(canvas.width.rounded(.up)) * Int(canvas.height.rounded(.up))
    }

    /// Inline only when the padded five-buffer peak plus `headroomBytes` fits in `limitBytes`.
    static func plan(
        pixelWidth: Int,
        pixelHeight: Int,
        canTransferToApp: Bool,
        style: BackgroundStyle = .default,
        scale: CGFloat? = nil
    ) -> Plan {
        let sourcePixels = max(0, pixelWidth) * max(0, pixelHeight)
        let canvasPixels = canvasPixelCount(width: pixelWidth, height: pixelHeight, style: style, scale: scale)
        let exportBytes = exportPeakBytes(sourcePixels: sourcePixels, canvasPixels: canvasPixels)
        if exportBytes + headroomBytes <= limitBytes {
            return .fullResolutionInline
        }
        if canTransferToApp {
            return .handoffToApp
        }
        return .reselectInApp
    }

    private static let onePixel: CGImage? = {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        return context.makeImage()
    }()

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
    /// `cached: false` keeps ImageIO from holding a decoded bitmap inside the image. Export uses it:
    /// the redactor decodes straight into its own buffer, so the source is not a second resident copy.
    static func fullImage(_ data: Data, cached: Bool = true) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, decodeOptions(cached: cached))
    }

    static func fullImage(_ url: URL, cached: Bool = true) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, decodeOptions(cached: cached))
    }

    private static func decodeOptions(cached: Bool) -> CFDictionary? {
        guard !cached else { return nil }
        return [kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false] as CFDictionary
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
