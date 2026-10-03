import CoreGraphics
import Foundation
import XCTest
@testable import PrettyShotCore

/// AC-L15..L18 stitching behaviour, the over-limit copy, and the AC-L19 stop-path memory harness.
final class ScrollStitchTests: XCTestCase {
    func testStickyHeaderAndFooterAreKeptOnce() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.viewport(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.viewport(scroll: 15)), .appended(15))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.viewport(scroll: 30)), .appended(15))

        var assembly = stitcher.takeAssembly()
        XCTAssertFalse(assembly.needsReview)
        XCTAssertFalse(assembly.opensStitchReview)
        XCTAssertTrue(assembly.hasStickyRepeats)
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertEqual(assembly.segments[0].confidentSeamYs, [52, 67])

        let deduped = try XCTUnwrap(assembly.flattenedIfResolved())
        XCTAssertEqual(deduped.height, 90)
        for y in 0..<CoreScrollFixtures.header {
            XCTAssertEqual(CoreScrollFixtures.row(deduped, y), CoreScrollFixtures.row(CoreScrollFixtures.viewport(scroll: 0), y))
        }
        let restoredHeight = 90 + 2 * (CoreScrollFixtures.header + CoreScrollFixtures.footer)
        assembly.dedupeStickyBars = false
        let restored = try XCTUnwrap(assembly.flattenedIfResolved())
        XCTAssertEqual(restored.height, restoredHeight)
        XCTAssertEqual(CoreScrollFixtures.row(restored, 52), CoreScrollFixtures.color(slot: 100))
        assembly.dedupeStickyBars = true
        XCTAssertEqual(try XCTUnwrap(assembly.flattenedIfResolved()).pixels, deduped.pixels)
    }

    func testUncertainStickyBandIsOneConfirmation() throws {
        var stitcher = ScrollStitcher()
        let frameCount = 8
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.softHeaderViewport(scroll: 0)), .seeded)
        for index in 1..<frameCount {
            let outcome = stitcher.ingest(CoreScrollFixtures.softHeaderViewport(scroll: index * 12))
            guard case .appended = outcome else {
                XCTFail("frame \(index) should join the same run, got \(outcome)")
                return
            }
        }
        var assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertTrue(assembly.seams.isEmpty)
        XCTAssertEqual(assembly.pendingSticky?.seamCount, frameCount - 1)
        XCTAssertEqual(assembly.pendingSticky?.prompt, "待确认 · 顶部这条可能是固定栏（涉及 \(frameCount - 1) 处接缝）")
        XCTAssertEqual(assembly.unresolvedItemCount, 1)
        XCTAssertNil(assembly.flattenedIfResolved())

        assembly.confirmStickyBars(keepOnce: true)
        XCTAssertFalse(assembly.needsReview)
        XCTAssertEqual(assembly.flattenedIfResolved()?.height, 48 + 12 * (frameCount - 1))
    }

    func testExportWithinLimitsRefusesUnalignedSeams() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 0, slot: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 0, slot: 40)), .unmatched)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 0, slot: 80)), .unmatched)
        var assembly = stitcher.takeAssembly()
        assembly.align(seam: 0, overlap: 0)
        XCTAssertEqual(assembly.unalignedSeamCount, 1)

        let refused = assembly.exportWithinLimits(dedupeStickyBars: true, maxHeight: 10, maxPixels: 24_000_000)
        XCTAssertTrue(refused.isEmpty, "exported segments must not span an unaligned seam")

        assembly.joinAsIs(seam: 1)
        let chunks = assembly.exportWithinLimits(dedupeStickyBars: true, maxHeight: 25, maxPixels: 24_000_000)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.height }, 120)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.height, 25)
            XCTAssertLessThanOrEqual(chunk.width * chunk.height, 24_000_000)
        }
    }

    func testOverLimitPromptButtonStateFallsFromTwoToZero() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 0, slot: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 0, slot: 40)), .unmatched)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 0, slot: 80)), .unmatched)
        var assembly = stitcher.takeAssembly()

        let blocked = assembly.restoreExportPrompt
        XCTAssertEqual(blocked.unalignedCount, 2)
        XCTAssertEqual(blocked.primaryTitle, "先处理 2 处待对齐")
        XCTAssertFalse(blocked.primaryExports)
        XCTAssertFalse(blocked.segmentExportEnabled)
        XCTAssertEqual(blocked.segmentExportCaption, "还有 2 处待对齐，先处理再导出")
        XCTAssertEqual(StitchCopy.keepDedupe, "保持去重")

        assembly.align(seam: 0, overlap: 0)
        let oneLeft = assembly.restoreExportPrompt
        XCTAssertEqual(oneLeft.unalignedCount, 1)
        XCTAssertEqual(oneLeft.primaryTitle, "先处理 1 处待对齐")
        XCTAssertFalse(oneLeft.primaryExports)
        XCTAssertFalse(oneLeft.segmentExportEnabled)
        XCTAssertEqual(oneLeft.segmentExportCaption, "还有 1 处待对齐，先处理再导出")

        assembly.joinAsIs(seam: 1)
        let ready = assembly.restoreExportPrompt
        XCTAssertEqual(ready.unalignedCount, 0)
        XCTAssertEqual(ready.primaryTitle, "分段导出")
        XCTAssertTrue(ready.primaryExports)
        XCTAssertTrue(ready.segmentExportEnabled)
        XCTAssertNil(ready.segmentExportCaption)
        XCTAssertFalse(assembly.exportWithinLimits(dedupeStickyBars: true).isEmpty)
    }

    func testOverLimitCopyNamesWhicheverLimitIsExceeded() {
        XCTAssertEqual(StitchCopy.wanRoundedUp(24_000_000), 2_400)
        XCTAssertEqual(StitchCopy.wanRoundedUp(24_003_000), 2_401)
        XCTAssertEqual(StitchCopy.wanRoundedUp(24_000_001), 2_401)
        XCTAssertEqual(StitchCopy.wanRoundedUp(1), 1)

        XCTAssertEqual(
            StitchCopy.overLimit(height: 18_240, pixels: 1_000_000, maxHeight: 16_384, maxPixels: 24_000_000),
            "还原后约 18,240 px，超过单张上限 16,384 px"
        )
        XCTAssertEqual(
            StitchCopy.overLimit(height: 18_240),
            "还原后约 18,240 px，超过单张上限 16,384 px"
        )
        XCTAssertEqual(
            StitchCopy.overLimit(height: 10_000, pixels: 24_003_000, maxHeight: 16_384, maxPixels: 24_000_000),
            "还原后约 2,401 万像素，超过单张总量上限 2,400 万像素"
        )
        XCTAssertEqual(
            StitchCopy.overLimit(height: 20_000, pixels: 30_000_000, maxHeight: 16_384, maxPixels: 24_000_000),
            "还原后约 20,000 px、3,000 万像素，超过单张上限 16,384 px 和总量上限 2,400 万像素"
        )
        XCTAssertEqual(StitchCopy.overLimitNote, "不会悄悄截断。可以分段导出（每段都不超上限），或保持去重。")
        XCTAssertEqual(StitchCopy.exportSegments, "分段导出")
        XCTAssertEqual(StitchCopy.keepDedupe, "保持去重")
    }

    func testRestoreOverLimitDoesNotTruncate() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.viewport(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.viewport(scroll: 15)), .appended(15))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.viewport(scroll: 30)), .appended(15))
        var assembly = stitcher.takeAssembly()
        let deduped = try XCTUnwrap(assembly.flattenedIfResolved())
        let restoredHeight = 90 + 2 * (CoreScrollFixtures.header + CoreScrollFixtures.footer)

        switch assembly.restoreStickyBars(maxHeight: 100, maxPixels: 24_000_000) {
        case .exceedsLimit(let height, let message):
            XCTAssertEqual(height, restoredHeight)
            XCTAssertEqual(message, StitchCopy.overLimit(height: restoredHeight))
            XCTAssertEqual(message, "还原后约 \(restoredHeight) px，超过单张上限 16,384 px")
        default:
            XCTFail("expected the over-limit prompt")
        }
        XCTAssertTrue(assembly.dedupeStickyBars)
        XCTAssertEqual(assembly.flattenedIfResolved()?.pixels, deduped.pixels)

        // Restored height is the image plus the 8 px header and footer spliced back in.
        var wide = wideAssembly(width: 2_000, height: 12_984)
        switch wide.restoreStickyBars() {
        case .exceedsLimit(_, let message):
            XCTAssertEqual(message, "还原后约 2,600 万像素，超过单张总量上限 2,400 万像素")
        default:
            XCTFail("expected a pixel-cap prompt")
        }
        var both = wideAssembly(width: 2_000, height: 19_984)
        switch both.restoreStickyBars() {
        case .exceedsLimit(_, let message):
            XCTAssertEqual(message, "还原后约 20,000 px、4,000 万像素，超过单张上限 16,384 px 和总量上限 2,400 万像素")
        default:
            XCTFail("expected both limits in the prompt")
        }
    }

    /// Synthetic 1440×20,000 capture. The harness counts tile bytes reserved by the stitcher.
    /// Before is the old stop path: the open parts, the seal `verticalJoin`, and the `Data` copy inside `cgImage` were alive together (3 full RGBA buffers).
    func testLongCaptureStopPeakStaysUnderTwoImages() throws {
        let width = 1440
        // Viewport plus one shift stays inside one palette period (~120), so the true
        // shift is the only perfect match. A taller window wraps and looks ambiguous.
        let viewport = 80
        let shift = 40
        let target = 20_000
        var options = ScrollStitcher.Options()
        options.maxHeight = target
        options.maxPixels = width * target

        let ledger = AllocationLedger()
        PixelMetrics.threadLedger = ledger
        defer { PixelMetrics.threadLedger = nil }

        var stitcher = ScrollStitcher(options: options)
        let steps = (target - viewport) / shift
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.uniqueFrame(origin: 0, width: width, height: viewport)), .seeded)
        for step in 1...steps {
            let outcome = stitcher.ingest(CoreScrollFixtures.uniqueFrame(origin: step * shift, width: width, height: viewport))
            guard case .appended(let rows) = outcome else {
                XCTFail("step \(step) expected append, got \(outcome)")
                return
            }
            XCTAssertEqual(rows, shift, "step \(step)")
        }

        ledger.rebasePeak()
        let assembly = stitcher.takeAssembly()
        let stitched = try XCTUnwrap(assembly.flattenedIfResolved())
        let cg = try XCTUnwrap(stitched.cgImage())
        let stopPeak = ledger.peakBytes
        let imageBytes = stitched.width * stitched.height * 4
        // a815b78 stop path kept three full buffers: parts while joining, the joined segment while
        // exportChunks joined again, and `Data(pixels)` for the CGImage provider.
        let before = imageBytes * 3
        print("AC-L19 peak bytes before≈\(before) after=\(stopPeak) imageBytes=\(imageBytes) height=\(stitched.height) cg=\(cg.width)x\(cg.height)")

        XCTAssertEqual(stitched.width, width)
        XCTAssertEqual(stitched.height, target)
        XCTAssertEqual(cg.width, width)
        XCTAssertEqual(cg.height, target)
        XCTAssertLessThan(stopPeak, imageBytes * 2, "stop path still retains a second full-image copy")
        XCTAssertLessThan(stopPeak, before)
    }

    private func wideAssembly(width: Int, height: Int) -> ScrollAssembly {
        // Dimensions drive the prompt. The pixels themselves are not read on the over-limit path.
        let image = RGBAImage(width: width, height: height, storage: ImageStorage(width: width))
        let bar = RGBAImage(width: width, height: 8, pixels: [UInt8](repeating: 10, count: width * 8 * 4))
        let segment = ScrollSegment(
            image: image,
            confidentSeamYs: [height / 2],
            stickyRepeats: [StickyRepeat(seamY: height / 2, header: bar, footer: bar)]
        )
        return ScrollAssembly(segments: [segment], seams: [], dedupeStickyBars: true, pendingSticky: nil)
    }
}

private enum CoreScrollFixtures {
    static let width = 40
    static let height = 60
    static let header = 10
    static let footer = 8
    static let contentSlot = 10

    private static let levels: [UInt8] = [0, 64, 128, 192, 255]
    private static let palette: [Int] = (0..<125).filter { index in
        let r = index % 5
        let g = (index / 5) % 5
        let b = index / 25
        return !(r == g && g == b)
    }

    static func color(slot: Int) -> [UInt8] {
        let index = palette[slot % palette.count]
        return [levels[index % 5], levels[(index / 5) % 5], levels[index / 25]]
    }

    static func row(_ image: RGBAImage, _ y: Int) -> [UInt8] {
        let i = y * image.width * 4
        let pixels = image.pixels
        return [pixels[i], pixels[i + 1], pixels[i + 2]]
    }

    static func softHeaderViewport(scroll: Int) -> RGBAImage {
        let height = 48
        let header = 8
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let nudge = UInt8(scroll == 0 ? 0 : 24)
        for y in 0..<height {
            let rgb: [UInt8]
            if y < header {
                rgb = color(slot: y)
            } else if y == header {
                rgb = [80 &+ nudge, 40 &+ nudge, 160 &+ nudge]
            } else {
                rgb = color(slot: contentSlot + scroll + (y - header))
            }
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
                pixels[i + 3] = 255
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    static func viewport(scroll: Int) -> RGBAImage {
        fill(width: width, height: height) { y in
            if y < header { return y }
            if y >= height - footer { return 100 + (y - (height - footer)) }
            return contentSlot + scroll + (y - header)
        }
    }

    static func page(scroll: Int, height: Int = 40, slot: Int = contentSlot) -> RGBAImage {
        fill(width: width, height: height) { y in slot + scroll + y }
    }

    /// Solid rows from the stitch palette. The viewport stays shorter than the palette so each
    /// frame's rows are unique and the true shift is the only confident one.
    static func uniqueFrame(origin: Int, width: Int, height: Int) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let rgb = color(slot: origin + y)
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    private static func fill(width: Int, height: Int, slot: (Int) -> Int) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let rgb = color(slot: slot(y))
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
                pixels[i + 3] = 255
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }
}
