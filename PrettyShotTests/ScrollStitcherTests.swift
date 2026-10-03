import CoreGraphics
import XCTest
@testable import PrettyShot

final class ScrollStitcherTests: XCTestCase {
    func testStickyHeaderAndFooterAreKeptOnce() {
        let first = ScrollFixtures.viewport(scroll: 0)
        let mid = ScrollFixtures.viewport(scroll: 15)
        let last = ScrollFixtures.viewport(scroll: 30)

        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(first), .seeded)
        XCTAssertEqual(stitcher.ingest(mid), .appended(15))
        XCTAssertEqual(stitcher.ingest(last), .appended(15))

        let assembly = stitcher.takeAssembly()
        XCTAssertFalse(assembly.needsReview)
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertEqual(assembly.segments[0].confidentSeamYs, [52, 67])

        let image = try XCTUnwrap(assembly.flattenedIfResolved())
        XCTAssertEqual(image.width, ScrollFixtures.width)
        XCTAssertEqual(image.height, 90)

        for y in 0..<ScrollFixtures.header {
            XCTAssertEqual(ScrollFixtures.row(image, y), ScrollFixtures.row(first, y), "header row \(y)")
        }
        for y in 0..<ScrollFixtures.footer {
            let imageY = image.height - ScrollFixtures.footer + y
            let frameY = ScrollFixtures.height - ScrollFixtures.footer + y
            XCTAssertEqual(ScrollFixtures.row(image, imageY), ScrollFixtures.row(last, frameY), "footer row \(y)")
        }
        for content in 0..<72 {
            let expected = ScrollFixtures.color(slot: ScrollFixtures.contentSlot + content)
            XCTAssertEqual(ScrollFixtures.row(image, ScrollFixtures.header + content), expected, "content \(content)")
        }
    }

    func testSmallStepGrowsAndDuplicatesDoNot() {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0)), .unchanged)
        XCTAssertEqual(stitcher.pixelHeight, 40)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 2)), .appended(2))
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 2)), .unchanged)
        XCTAssertEqual(stitcher.pixelHeight, 42)

        let image = try XCTUnwrap(stitcher.takeAssembly().flattenedIfResolved())
        XCTAssertEqual(image.height, 42)
        XCTAssertEqual(ScrollFixtures.row(image, 0), ScrollFixtures.color(slot: ScrollFixtures.contentSlot))
        XCTAssertEqual(ScrollFixtures.row(image, 41), ScrollFixtures.color(slot: ScrollFixtures.contentSlot + 41))
    }

    func testUnconfidentSeamIsNotFlattenedUntilTheUserDecides() {
        let first = ScrollFixtures.page(scroll: 0, slot: 0)
        let second = ScrollFixtures.page(scroll: 0, slot: 80)

        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(first), .seeded)
        XCTAssertEqual(stitcher.ingest(second), .unmatched)
        XCTAssertEqual(stitcher.segmentCount, 2)

        var assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.segments.count, 2)
        XCTAssertEqual(assembly.seams.count, 1)
        XCTAssertEqual(assembly.seams[0].kind, .needsAlignment)
        XCTAssertTrue(assembly.needsReview)
        XCTAssertNil(assembly.flattenedIfResolved())
        XCTAssertEqual(assembly.segments[0].image, first)
        XCTAssertEqual(assembly.segments[1].image, second)

        let preview = try XCTUnwrap(assembly.renderPreview())
        XCTAssertLessThanOrEqual(max(preview.image.width, preview.image.height), 1200)
        XCTAssertTrue(preview.marks.contains { $0.state == .needsAlignment })
        XCTAssertEqual(assembly.exportChunks().count, 2)

        var stackedAssembly = assembly
        stackedAssembly.joinAsIs(seam: 0)
        let stacked = try XCTUnwrap(stackedAssembly.flattenedIfResolved())
        XCTAssertEqual(stacked.height, first.height + second.height)
        XCTAssertEqual(ScrollFixtures.row(stacked, 0), ScrollFixtures.row(first, 0))
        XCTAssertEqual(ScrollFixtures.row(stacked, first.height), ScrollFixtures.row(second, 0))

        assembly.align(seam: 0, overlap: 10)
        let aligned = try XCTUnwrap(assembly.flattenedIfResolved())
        XCTAssertEqual(aligned.height, first.height + second.height - 10)
        XCTAssertEqual(ScrollFixtures.row(aligned, 0), ScrollFixtures.row(first, 0))
        XCTAssertEqual(ScrollFixtures.row(aligned, first.height), ScrollFixtures.row(second, 10))
        XCTAssertEqual(ScrollFixtures.row(aligned, aligned.height - 1), ScrollFixtures.row(second, second.height - 1))
        XCTAssertTrue(assembly.renderPreview()?.marks.contains { $0.state == .aligned } == true)
    }

    func testSeveralUnmatchedFramesStaySeparate() {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, slot: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, slot: 40)), .unmatched)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, slot: 80)), .unmatched)

        var assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.segments.count, 3)
        XCTAssertEqual(assembly.seams.map(\.kind), [.needsAlignment, .needsAlignment])
        XCTAssertEqual(assembly.exportChunks().count, 3)

        assembly.joinAsIs(seam: 0)
        XCTAssertEqual(assembly.exportChunks().count, 2)
        XCTAssertNil(assembly.flattenedIfResolved())
    }

    func testHeightCapClipsAConfidentJoinAndStops() {
        var options = ScrollStitcher.Options()
        options.maxHeight = 50
        var stitcher = ScrollStitcher(options: options)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 20)), .reachedLimit)
        let image = try XCTUnwrap(stitcher.takeAssembly().flattenedIfResolved())
        XCTAssertEqual(image.height, 50)
    }

    func testPixelBudgetRefusesAnotherFullViewport() {
        var options = ScrollStitcher.Options()
        options.maxPixels = 40 * 45
        var stitcher = ScrollStitcher(options: options)
        let first = ScrollFixtures.page(scroll: 0, slot: 0)
        let unrelated = ScrollFixtures.page(scroll: 0, slot: 80)
        XCTAssertEqual(stitcher.ingest(first), .seeded)
        XCTAssertEqual(stitcher.ingest(unrelated), .reachedLimit)
        let assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertFalse(assembly.needsReview)
        XCTAssertEqual(assembly.flattenedIfResolved()?.height, first.height)
    }

    func testRemainingRowsHonorsHeightAndPixelCaps() {
        XCTAssertEqual(ScrollOutputLimit.maxHeight, 16_384)
        XCTAssertEqual(ScrollOutputLimit.maxPixels, 24_000_000)
        XCTAssertEqual(ScrollOutputLimit.remainingRows(totalHeight: 0, width: 1600), 15_000)
        XCTAssertEqual(ScrollOutputLimit.remainingRows(totalHeight: 16_000, width: 800), 384)
        XCTAssertEqual(ScrollOutputLimit.remainingRows(totalHeight: 100, width: 0), 0)
        XCTAssertEqual(
            ScrollOutputLimit.remainingRows(totalHeight: 40, width: 40, maxHeight: 10_000, maxPixels: 40 * 45),
            5
        )
    }

    func testCGImageRoundTripKeepsTopRowAtTheTop() {
        let width = 8
        let height = 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for x in 0..<width {
            let top = x * 4
            pixels[top] = 255
            pixels[top + 3] = 255
            let bottom = ((height - 1) * width + x) * 4
            pixels[bottom + 2] = 255
            pixels[bottom + 3] = 255
        }
        let image = RGBAImage(width: width, height: height, pixels: pixels)
        let cg = try XCTUnwrap(image.cgImage())
        let back = try XCTUnwrap(RGBAImage.fromCGImage(cg))
        XCTAssertEqual(ScrollFixtures.row(back, 0), (255, 0, 0))
        XCTAssertEqual(ScrollFixtures.row(back, height - 1), (0, 0, 255))
    }

    func testSourceRectFlipsCocoaSelection() {
        let screen = CGSize(width: 1440, height: 900)
        let selection = CGRect(x: 100, y: 650, width: 300, height: 200)
        let source = ScrollingCaptureGeometry.sourceRect(selection: selection, screenSize: screen)
        XCTAssertEqual(source, CGRect(x: 100, y: 50, width: 300, height: 200))
    }

    func testAutoScrollShipsDisabled() {
        XCTAssertFalse(ScrollingCaptureFeature.autoScrollEnabled)
    }
}

private enum ScrollFixtures {
    static let width = 40
    static let height = 60
    static let header = 10
    static let footer = 8
    static let contentSlot = 10

    private static let levels: [UInt8] = [0, 64, 128, 192, 255]
    /// 120 colors whose channels sit on a 63-step lattice, grays removed so every row is distinctive
    /// and any two different rows are farther apart than the stitcher's align distance.
    private static let palette: [Int] = (0..<125).filter { index in
        let r = index % 5
        let g = (index / 5) % 5
        let b = index / 25
        return !(r == g && g == b)
    }

    static func color(slot: Int) -> (UInt8, UInt8, UInt8) {
        let index = palette[slot % palette.count]
        return (levels[index % 5], levels[(index / 5) % 5], levels[index / 25])
    }

    static func row(_ image: RGBAImage, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = y * image.width * 4
        return (image.pixels[i], image.pixels[i + 1], image.pixels[i + 2])
    }

    static func viewport(scroll: Int) -> RGBAImage {
        let content = height - header - footer
        return fill(width: width, height: height) { y in
            if y < header { return y }
            if y >= height - footer { return 100 + (y - (height - footer)) }
            return contentSlot + scroll + (y - header)
        }
    }

    static func page(scroll: Int, height: Int = 40, slot: Int = contentSlot) -> RGBAImage {
        fill(width: width, height: height) { y in slot + scroll + y }
    }

    private static func fill(width: Int, height: Int, slot: (Int) -> Int) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let (r, g, b) = color(slot: slot(y))
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = r
                pixels[i + 1] = g
                pixels[i + 2] = b
                pixels[i + 3] = 255
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }
}
