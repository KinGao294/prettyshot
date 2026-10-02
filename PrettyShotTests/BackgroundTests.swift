import XCTest
@testable import PrettyShot

final class BackgroundTests: XCTestCase {
    func testEightOriginalPresetsFromDesign() {
        XCTAssertEqual(BackgroundPreset.all.map(\.key), [
            "paper-mist", "ink-wash", "soft-bloom", "moss-quiet",
            "dusk-lilac", "ceramic-white", "night-ink", "citrus-fog",
            "pastel-air",
        ])
        XCTAssertFalse(BackgroundPreset.preset(for: "pastel-air")?.washes.isEmpty ?? true)
        for preset in BackgroundPreset.all {
            XCTAssertEqual(preset.stops.first?.location, 0)
            XCTAssertEqual(preset.stops.last?.location, 1)
            XCTAssertNotNil(preset.cgGradient)
        }
        XCTAssertTrue(BackgroundPreset.all.contains { $0.stops.contains { $0.hex == 0xE8A0A8 } }, "Bloom Rose appears in soft-bloom")
    }

    func testCSSAngleGeometry() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)

        // 180deg = top → bottom.
        var (start, end) = GradientGeometry.endpoints(angleDegrees: 180, in: rect)
        XCTAssertEqual(start.x, 100, accuracy: 0.001)
        XCTAssertEqual(start.y, 0, accuracy: 0.001)
        XCTAssertEqual(end.y, 100, accuracy: 0.001)

        // 90deg = left → right.
        (start, end) = GradientGeometry.endpoints(angleDegrees: 90, in: rect)
        XCTAssertEqual(start.x, 0, accuracy: 0.001)
        XCTAssertEqual(end.x, 200, accuracy: 0.001)
        XCTAssertEqual(start.y, 50, accuracy: 0.001)

        // 135deg: towards bottom-right, symmetric around the centre.
        (start, end) = GradientGeometry.endpoints(angleDegrees: 135, in: rect)
        XCTAssertLessThan(start.x, end.x)
        XCTAssertLessThan(start.y, end.y)
        XCTAssertEqual((start.x + end.x) / 2, 100, accuracy: 0.001)
        XCTAssertEqual((start.y + end.y) / 2, 50, accuracy: 0.001)
    }

    func testDefaultStyleMatchesPrototype() {
        let style = BackgroundStyle.default
        XCTAssertEqual(style.presetKey, "pastel-air")
        XCTAssertEqual(style.padding, 28)
        XCTAssertEqual(style.radius, 12)
        XCTAssertEqual(style.shadow, 48)
    }
}
