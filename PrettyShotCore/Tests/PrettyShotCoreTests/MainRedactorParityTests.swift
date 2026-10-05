import CoreGraphics
import Foundation
import XCTest
@testable import PrettyShotCore

/// PRD v0.3.49 #37 (P1) pixel gate: `Redactor` must stay byte-identical to `main`
/// (`MainRedactorSnapshot`, a verbatim copy). Compares the raw RGBA8 bytes both return, not just a
/// redraw, and logs one `PRETTYSHOT_PIXEL_DIFF` line per case so CI shows the byte diff.
final class MainRedactorParityTests: XCTestCase {
    /// The iOS two-mark peak fixture itself: 1320×2868, top pixelate + bottom blur, scale 3.
    func testPeakFixtureTopAndBottomMarksMatchMain() {
        let image = Self.patterned(width: 1320, height: 2868)
        let marks = [
            ParityMark(kind: .pixelate, rect: CGRect(x: 60, y: 150, width: 400, height: 90)),
            ParityMark(kind: .blur, rect: CGRect(x: 700, y: 2650, width: 420, height: 100)),
        ]
        let live = Redactor.apply(marks, to: image, scale: 3)
        let main = MainRedactorSnapshot.apply(marks, to: image, scale: 3)
        Self.assertByteIdentical(live, main, "peak-fixture-top-bottom-1320x2868")
        // Both marks really changed pixels (top rows and bottom rows).
        XCTAssertNotEqual(Self.raw(live, rows: 150..<240), Self.raw(image, rows: 150..<240, normalized: true))
        XCTAssertNotEqual(Self.raw(live, rows: 2650..<2750), Self.raw(image, rows: 2650..<2750, normalized: true))
    }

    /// One wide blur whose reach apron spans where a strip / tile boundary would fall (the old 256KB
    /// strip cap split this write width in two). Covers scale 1 and the scale-3 iOS radius.
    func testWideBlurAcrossFormerStripBoundaryMatchesMain() {
        let image = Self.patterned(width: 520, height: 220)
        let mark = [ParityMark(kind: .blur, rect: CGRect(x: 40, y: 50, width: 400, height: 90))]
        Self.assertByteIdentical(Redactor.apply(mark, to: image, scale: 1),
                                 MainRedactorSnapshot.apply(mark, to: image, scale: 1), "wide-blur-scale1")
        let big = Self.patterned(width: 1320, height: 700)
        let wide = [ParityMark(kind: .blur, rect: CGRect(x: 30, y: 250, width: 1260, height: 160))]
        Self.assertByteIdentical(Redactor.apply(wide, to: big, scale: 3),
                                 MainRedactorSnapshot.apply(wide, to: big, scale: 3), "wide-blur-scale3")
    }

    /// Overlapping marks (one patch, later mark filters the earlier one) on a downscaled preview,
    /// marks clipped by every image edge, and fractional mark rects.
    func testOverlappingEdgeAndFractionalMarksMatchMain() {
        let image = Self.patterned(width: 300, height: 400)
        let cases: [(String, [ParityMark], CGFloat, CGFloat)] = [
            ("overlap-geometry-0.5", [
                ParityMark(kind: .pixelate, rect: CGRect(x: 20, y: 40, width: 400, height: 300)),
                ParityMark(kind: .blur, rect: CGRect(x: 120, y: 100, width: 260, height: 400)),
            ], 2, 0.5),
            ("edges", [
                ParityMark(kind: .blur, rect: CGRect(x: -10, y: -10, width: 90, height: 60)),
                ParityMark(kind: .pixelate, rect: CGRect(x: 240, y: 350, width: 100, height: 100)),
            ], 2, 1),
            ("fractional", [
                ParityMark(kind: .pixelate, rect: CGRect(x: 10.5, y: 7.25, width: 61.3, height: 40.7)),
                ParityMark(kind: .blur, rect: CGRect(x: 100.4, y: 250.6, width: 70.2, height: 33.9)),
            ], 1.5, 1),
        ]
        for (name, marks, scale, geometry) in cases {
            Self.assertByteIdentical(
                Redactor.apply(marks, to: image, scale: scale, geometryScale: geometry),
                MainRedactorSnapshot.apply(marks, to: image, scale: scale, geometryScale: geometry),
                name
            )
        }
    }

    /// A Display P3 source with translucent pixels: the canvas draw converts colour space and
    /// premultiplies, so the patch must be drawn the same way the canvas is.
    func testDisplayP3TranslucentSourceMatchesMain() {
        let image = Self.patterned(width: 260, height: 520, spaceName: CGColorSpace.displayP3, translucent: true)
        let marks = [
            ParityMark(kind: .pixelate, rect: CGRect(x: 12, y: 20, width: 120, height: 40)),
            ParityMark(kind: .blur, rect: CGRect(x: 100, y: 420, width: 140, height: 60)),
        ]
        Self.assertByteIdentical(Redactor.apply(marks, to: image, scale: 2),
                                 MainRedactorSnapshot.apply(marks, to: image, scale: 2), "display-p3-translucent")
    }

    // MARK: - Helpers

    /// Deterministic non-flat RGBA pattern so blur and pixelate change most pixels.
    static func patterned(
        width: Int, height: Int,
        spaceName: CFString = CGColorSpace.sRGB,
        translucent: Bool = false
    ) -> CGImage {
        let space = CGColorSpace(name: spaceName)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let a: UInt8 = translucent ? UInt8(96 + (x * 3 + y) % 160) : 255
                let r = UInt8((x * 7 + y * 3) & 0xFF)
                let g = UInt8((x * 2 + y * 11 + ((x / 9) % 2) * 120) & 0xFF)
                let b = UInt8(((x ^ y) * 5) & 0xFF)
                pixels[i] = UInt8(Int(r) * Int(a) / 255)
                pixels[i + 1] = UInt8(Int(g) * Int(a) / 255)
                pixels[i + 2] = UInt8(Int(b) * Int(a) / 255)
                pixels[i + 3] = a
            }
        }
        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Raw provider bytes of both results, which share format, colour space and row stride.
    static func assertByteIdentical(
        _ live: CGImage, _ main: CGImage, _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(live.width, main.width, name, file: file, line: line)
        XCTAssertEqual(live.height, main.height, name, file: file, line: line)
        XCTAssertEqual(live.bytesPerRow, main.bytesPerRow, name, file: file, line: line)
        XCTAssertEqual(live.bitmapInfo, main.bitmapInfo, name, file: file, line: line)
        XCTAssertEqual(live.colorSpace?.name as String?, main.colorSpace?.name as String?, name, file: file, line: line)
        guard let a = live.dataProvider?.data, let b = main.dataProvider?.data else {
            XCTFail("\(name): missing provider data", file: file, line: line)
            return
        }
        let count = min(CFDataGetLength(a), CFDataGetLength(b))
        let pa = CFDataGetBytePtr(a)!
        let pb = CFDataGetBytePtr(b)!
        var differing = 0
        var first = -1
        for index in 0..<count where pa[index] != pb[index] {
            differing += 1
            if first < 0 { first = index }
        }
        print("PRETTYSHOT_PIXEL_DIFF case=\(name) size=\(live.width)x\(live.height) bytes=\(count) "
              + "lengthLive=\(CFDataGetLength(a)) lengthMain=\(CFDataGetLength(b)) differing=\(differing)")
        XCTAssertEqual(CFDataGetLength(a), CFDataGetLength(b), name, file: file, line: line)
        if first >= 0 {
            let row = first / live.bytesPerRow
            let col = (first % live.bytesPerRow) / 4
            XCTFail("\(name): \(differing) bytes differ from main; first at pixel (\(col), \(row)) "
                    + "channel \(first % 4): \(pa[first]) vs \(pb[first])", file: file, line: line)
        }
        // Also the redraw comparison the other goldens use.
        XCTAssertSamePixels(live, main, name, file: file, line: line)
    }

    /// Rows of `image` (y down) as sRGB RGBA8 premultiplied bytes.
    static func raw(_ image: CGImage, rows: Range<Int>, normalized: Bool = false) -> [UInt8] {
        let all = TestImages.bytes(image)
        let stride = image.width * 4
        return Array(all[rows.lowerBound * stride..<rows.upperBound * stride])
    }
}

private struct ParityMark: Redactable {
    var kind: RedactionKind
    var rect: CGRect
    var redactionKind: RedactionKind? { kind }
    var redactionRect: CGRect { rect }
    var isMeaningfulRedaction: Bool { rect.width >= 4 && rect.height >= 4 }
}
