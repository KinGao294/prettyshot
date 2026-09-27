import XCTest
@testable import PrettyShot

final class CaptureGeometryTests: XCTestCase {
    func testRetinaSelectionMapsToTopLeftPixels() {
        // 1440×900 pt screen captured at 2x.
        let view = CGSize(width: 1440, height: 900)
        let image = CGSize(width: 2880, height: 1800)
        // Selection 100pt from the left, 50pt from the *top* (y-up view: minY = 900 - 50 - 200).
        let selection = CGRect(x: 100, y: 650, width: 300, height: 200)
        XCTAssertEqual(CaptureGeometry.pixelRect(for: selection, viewSize: view, imageSize: image),
                       CGRect(x: 200, y: 100, width: 600, height: 400))
    }

    func testSelectionIsClippedToImage() {
        let rect = CaptureGeometry.pixelRect(for: CGRect(x: -10, y: -10, width: 50, height: 50),
                                             viewSize: CGSize(width: 100, height: 100),
                                             imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(rect, CGRect(x: 0, y: 60, width: 40, height: 40))
    }

    func testQuartzToCocoaConversion() {
        let quartz = CGRect(x: 10, y: 20, width: 300, height: 200)
        XCTAssertEqual(WindowCatalog.cocoaRect(fromQuartz: quartz, primaryHeight: 900),
                       CGRect(x: 10, y: 680, width: 300, height: 200))
    }

    func testFileNamesAreUnique() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PrettyShotNames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 0)
        let first = FileNaming.uniqueURL(in: dir, date: date)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("PrettyShot "))
        XCTAssertTrue(first.lastPathComponent.hasSuffix(".png"))
        try Data().write(to: first)
        let second = FileNaming.uniqueURL(in: dir, date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2.png"))
    }
}
