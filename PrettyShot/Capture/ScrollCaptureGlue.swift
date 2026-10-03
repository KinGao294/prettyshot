import CoreGraphics
import CoreVideo
import PrettyShotCore

/// Screen-local selection (Cocoa, origin bottom-left) → ScreenCaptureKit `sourceRect`
/// (points, origin top-left of the display).
enum ScrollingCaptureGeometry {
    static func sourceRect(selection: CGRect, screenSize: CGSize) -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0 else { return .null }
        let flipped = CGRect(
            x: selection.minX,
            y: screenSize.height - selection.maxY,
            width: selection.width,
            height: selection.height
        )
        return flipped.integral.intersection(CGRect(origin: .zero, size: screenSize))
    }
}

extension RGBAImage {
    /// Copies a BGRA/RGBA `CVPixelBuffer` (row 0 = top, as ScreenCaptureKit delivers it).
    static func fromPixelBuffer(_ buffer: CVPixelBuffer) -> RGBAImage? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let bgra = format == kCVPixelFormatType_32BGRA
        let rgba = format == kCVPixelFormatType_32RGBA
        guard bgra || rgba else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let source = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = source.advanced(by: y * bytesPerRow)
            let destination = y * width * 4
            if rgba {
                for x in 0..<(width * 4) {
                    pixels[destination + x] = row[x]
                }
            } else {
                for x in 0..<width {
                    let s = x * 4
                    let d = destination + s
                    pixels[d] = row[s + 2]
                    pixels[d + 1] = row[s + 1]
                    pixels[d + 2] = row[s]
                    pixels[d + 3] = row[s + 3]
                }
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }
}
