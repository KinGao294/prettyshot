import CoreGraphics
import Foundation
import XCTest
@testable import PrettyShotCore

final class RenderingGoldenTests: XCTestCase {
    func testPresetTableMatchesFrozenSnapshot() throws {
        XCTAssertEqual(BackgroundPreset.all.map(\.key), PreRefactorSnapshot.presets.map(\.key))
        for frozen in PreRefactorSnapshot.presets {
            guard let live = BackgroundPreset.preset(for: frozen.key) else {
                XCTFail("missing preset \(frozen.key)")
                continue
            }
            XCTAssertEqual(live.angle, frozen.angle, frozen.key)
            XCTAssertEqual(live.stops.map(\.hex), frozen.stops.map(\.hex), frozen.key)
            XCTAssertEqual(live.stops.map(\.location), frozen.stops.map(\.location), frozen.key)
            XCTAssertEqual(live.washes.map(\.hex), frozen.washes.map(\.hex), frozen.key)
            XCTAssertEqual(live.washes.map(\.x), frozen.washes.map(\.x), frozen.key)
            XCTAssertEqual(live.washes.map(\.y), frozen.washes.map(\.y), frozen.key)
            XCTAssertEqual(live.washes.map(\.radius), frozen.washes.map(\.radius), frozen.key)
        }
        let style = BackgroundStyle.default
        XCTAssertEqual(style.presetKey, "pastel-air")
        XCTAssertEqual(style.padding, 28)
        XCTAssertEqual(style.radius, 12)
        XCTAssertEqual(style.shadow, 48)

        let data = try JSONEncoder().encode(style)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(object["presetKey"] as? String), "pastel-air")
        XCTAssertEqual(try XCTUnwrap(object["padding"] as? Double), 28, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(object["radius"] as? Double), 12, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(object["shadow"] as? Double), 48, accuracy: 0.001)
        let decoded = try JSONDecoder().decode(BackgroundStyle.self, from: data)
        XCTAssertEqual(decoded, style)

        let plain = BackgroundStyle(presetKey: nil, padding: 8, radius: 0, shadow: 0)
        let plainData = try JSONEncoder().encode(plain)
        let plainJSON = String(data: plainData, encoding: .utf8) ?? ""
        XCTAssertFalse(plainJSON.contains("presetKey"))
        XCTAssertEqual(try JSONDecoder().decode(BackgroundStyle.self, from: plainData), plain)
    }

    func testBeautifyPixelsMatchPreRefactor() {
        let image = TestImages.make(width: 72, height: 40, striped: true)
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var cases: [(String, String?, Double, Double, Double, CGFloat, CGRect, CGSize?)] = [
            ("plain", nil, 28, 12, 48, 2, full, nil),
            ("crop-shadow", "paper-mist", 16, 8, 36, 2, CGRect(x: 8, y: 6, width: 40, height: 22), nil),
            ("no-shadow", "night-ink", 12, 0, 0, 1, full, nil),
            ("base-size", "soft-bloom", 10, 6, 24, 2, full, CGSize(width: 144, height: 80)),
        ]
        for preset in PreRefactorSnapshot.presets {
            cases.append((preset.key, preset.key, 28, 12, 48, 2, full, nil))
        }
        for (name, key, padding, radius, shadow, scale, crop, baseSize) in cases {
            let live = BeautifyRenderer.render(BeautifyInput(
                base: image,
                crop: crop,
                background: BackgroundStyle(presetKey: key, padding: padding, radius: radius, shadow: shadow),
                scale: scale,
                baseSize: baseSize
            ))
            let frozen = PreRefactorSnapshot.render(
                base: image, crop: crop, presetKey: key, padding: padding, radius: radius, shadow: shadow,
                scale: scale, baseSize: baseSize
            )
            XCTAssertSamePixels(live, frozen, name)
        }
    }

    func testRedactionPixelsMatchPreRefactor() {
        let image = TestImages.make(width: 96, height: 48, striped: true)
        let regions: [(String, [PreRefactorSnapshot.Region], [Mark], CGFloat, CGFloat)] = [
            ("pixelate",
             [PreRefactorSnapshot.Region(pixelate: true, rect: CGRect(x: 0, y: 0, width: 40, height: 48))],
             [Mark(kind: .pixelate, rect: CGRect(x: 0, y: 0, width: 40, height: 48))],
             2, 1),
            ("blur",
             [PreRefactorSnapshot.Region(pixelate: false, rect: CGRect(x: 20, y: 8, width: 50, height: 30))],
             [Mark(kind: .blur, rect: CGRect(x: 20, y: 8, width: 50, height: 30))],
             1, 1),
            ("stacked-scaled",
             [
                PreRefactorSnapshot.Region(pixelate: true, rect: CGRect(x: 0, y: 0, width: 70, height: 40)),
                PreRefactorSnapshot.Region(pixelate: false, rect: CGRect(x: 10, y: 4, width: 40, height: 30)),
             ],
             [
                Mark(kind: .pixelate, rect: CGRect(x: 0, y: 0, width: 70, height: 40)),
                Mark(kind: .blur, rect: CGRect(x: 10, y: 4, width: 40, height: 30)),
             ],
             2, 0.5),
        ]
        for (name, frozenRegions, marks, scale, geometry) in regions {
            let live = Redactor.apply(marks, to: image, scale: scale, geometryScale: geometry)
            let frozen = PreRefactorSnapshot.redact(frozenRegions, image: image, scale: scale, geometryScale: geometry)
            XCTAssertSamePixels(live, frozen, name)
        }
    }

    func testTinyRedactionReturnsTheSameImage() {
        let image = TestImages.make(width: 32, height: 16, striped: true)
        let redacted = Redactor.apply([
            Mark(kind: .pixelate, rect: CGRect(x: 0, y: 0, width: 3, height: 10), meaningful: false),
            Mark(kind: .blur, rect: CGRect(x: 1, y: 1, width: 2, height: 2), meaningful: false),
        ], to: image, scale: 1)
        XCTAssertTrue(redacted === image)
    }

    func testDefaultPreviewMatchesHistoricalLongSideScale() {
        let small = TestImages.make(width: 200, height: 80)
        XCTAssertNil(Redactor.previewSource(for: small))
        XCTAssertNil(PreRefactorSnapshot.previewSource(for: small))

        let wide = TestImages.make(width: 1400, height: 20, striped: true)
        let live = Redactor.previewSource(for: wide)
        let frozen = PreRefactorSnapshot.previewSource(for: wide)
        XCTAssertEqual(live?.factor ?? -1, frozen?.factor ?? -2, accuracy: 0.000_001)
        XCTAssertSamePixels(live?.image, frozen?.image, "preview")
    }

    func testDisplaySourceSkipsOrdinaryShotsAndScalesTallOnes() {
        XCTAssertNil(Redactor.displaySource(for: TestImages.make(width: 1800, height: 1200)))
        let tall = TestImages.make(width: 64, height: 5000)
        guard let preview = Redactor.displaySource(for: tall) else {
            XCTFail("expected a display preview for a tall capture")
            return
        }
        XCTAssertLessThanOrEqual(max(preview.image.width, preview.image.height), 4096)
        XCTAssertEqual(preview.image.width, 52)
        XCTAssertEqual(preview.image.height, 4096)
    }

    func testCSSAngleGeometry() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        var (start, end) = GradientGeometry.endpoints(angleDegrees: 180, in: rect)
        XCTAssertEqual(start.x, 100, accuracy: 0.001)
        XCTAssertEqual(start.y, 0, accuracy: 0.001)
        XCTAssertEqual(end.y, 100, accuracy: 0.001)

        (start, end) = GradientGeometry.endpoints(angleDegrees: 90, in: rect)
        XCTAssertEqual(start.x, 0, accuracy: 0.001)
        XCTAssertEqual(end.x, 200, accuracy: 0.001)
        XCTAssertEqual(start.y, 50, accuracy: 0.001)
    }

    func testSharedSourcesStayPlatformNeutral() throws {
        let tests = URL(fileURLWithPath: #filePath)
        let sources = tests
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PrettyShotCore", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let allowed = [
            "CoreGraphics",
            "CoreImage",
            "CoreImage.CIFilterBuiltins",
            "Foundation",
        ]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let imports = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { return nil }
                return String(trimmed.dropFirst("import ".count)).trimmingCharacters(in: .whitespaces)
            }
            XCTAssertFalse(imports.isEmpty, "\(file.lastPathComponent) has no imports")
            for module in imports {
                XCTAssertTrue(allowed.contains(module), "\(file.lastPathComponent) imports \(module)")
            }
        }
    }
}

private struct Mark: Redactable {
    var kind: RedactionKind
    var rect: CGRect
    var meaningful: Bool = true

    var redactionKind: RedactionKind? { kind }
    var redactionRect: CGRect { rect }
    var isMeaningfulRedaction: Bool { meaningful }
}
