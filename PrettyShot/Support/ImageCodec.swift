import AppKit
import ImageIO
import UniformTypeIdentifiers

/// PNG encode/decode + thumbnails. Pixel data stays as CGImage; `scale` = pixels per point.
enum ImageCodec {
    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = pngData(from: image) else { throw CodecError.encodeFailed }
        try data.write(to: url, options: .atomic)
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// NSImage whose point size honours the capture's backing scale (Retina-correct paste/drag).
    static func nsImage(_ image: CGImage, scale: CGFloat) -> NSImage {
        let s = max(scale, 1)
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / s, height: CGFloat(image.height) / s))
    }

    enum CodecError: LocalizedError {
        case encodeFailed
        var errorDescription: String? { "PNG 编码失败" }
    }
}

enum Clipboard {
    @discardableResult
    static func copy(_ image: CGImage, scale: CGFloat) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrapped = ImageCodec.nsImage(image, scale: scale)
        // NSImage provides TIFF for legacy apps; explicit PNG keeps alpha + exact pixels for modern ones.
        var ok = pasteboard.writeObjects([wrapped])
        if let png = ImageCodec.pngData(from: image) {
            ok = pasteboard.setData(png, forType: .png) || ok
        }
        return ok
    }
}

enum FileNaming {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    static func screenshotName(date: Date = Date(), suffix: String = "") -> String {
        "PrettyShot \(formatter.string(from: date))\(suffix).png"
    }

    /// Returns a URL in `directory` that doesn't exist yet ("… 2.png", "… 3.png" …).
    static func uniqueURL(in directory: URL, date: Date = Date()) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(screenshotName(date: date))
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(screenshotName(date: date, suffix: " \(n)"))
            n += 1
        }
        return candidate
    }
}
