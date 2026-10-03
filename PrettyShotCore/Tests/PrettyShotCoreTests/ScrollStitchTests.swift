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

    func testOnePixelShiftInBlankFrameOpensSeam() throws {
        try assertBlankOpensASeam(
            CoreScrollFixtures.sparseViewport(scroll: 0, height: 60, contentRows: 10),
            CoreScrollFixtures.sparseViewport(scroll: 1, height: 60, contentRows: 10)
        )
    }

    func testThreePixelShiftInBlankFrameOpensSeam() throws {
        try assertBlankOpensASeam(
            CoreScrollFixtures.sparseViewport(scroll: 0, height: 80, contentRows: 16),
            CoreScrollFixtures.sparseViewport(scroll: 3, height: 80, contentRows: 16)
        )
    }

    func testMidSizeShiftInBlankFrameOpensSeam() throws {
        try assertBlankOpensASeam(
            CoreScrollFixtures.sparseViewport(scroll: 0, height: 80, contentRows: 20),
            CoreScrollFixtures.sparseViewport(scroll: 10, height: 80, contentRows: 20)
        )
    }

    func testTwoPixelShiftBehindFixedBarStitches() throws {
        try assertDownwardJoin(
            CoreScrollFixtures.fixedBarViewport(scroll: 0, height: 80, barRows: 60),
            CoreScrollFixtures.fixedBarViewport(scroll: 2, height: 80, barRows: 60),
            shift: 2
        )
    }

    func testMidSizeShiftBehindFixedBarStitches() throws {
        try assertDownwardJoin(
            CoreScrollFixtures.fixedBarViewport(scroll: 0, height: 80, barRows: 60),
            CoreScrollFixtures.fixedBarViewport(scroll: 12, height: 80, barRows: 60),
            shift: 12
        )
    }

    func testSegmentBreakDoesNotReuseStaleAlias() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 0, height: 90, slot: 25)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 12, height: 90, slot: 25)), .appended(12))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 12)), .unmatched)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 42)), .unmatched)
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.needsReview)
        XCTAssertNil(assembly.flattenedIfResolved())
    }

    func testFinalizeDropsStaleAlias() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 12)), .appended(12))
        _ = stitcher.takeAssembly()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 12)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 42)), .unmatched)
    }

    func testBeginStitchDropsStaleAlias() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 12)), .appended(12))
        stitcher.beginStitch()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 42)), .unmatched)
    }

    /// Two-row solid bands on white. An off-by-one join used to score as well as the true shift.
    func testTwoRowBandsOnWhiteAppendTheTrueShift() throws {
        let shift = 12
        let first = CoreScrollFixtures.colorBands(scroll: 0)
        let second = CoreScrollFixtures.colorBands(scroll: shift)
        try assertStitchedRows(first, second, shift: shift)
    }

    /// Same segment, forward alias, then a real reverse. The reverse must not be appended.
    func testReverseScrollInTheSameSegmentIsNotAppended() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 106)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 118)), .appended(12))
        let outcome = stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 90))
        XCTAssertEqual(outcome, .unmatched)
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.needsReview)
        XCTAssertNil(assembly.flattenedIfResolved())
        XCTAssertEqual(assembly.seams.last?.note, StitchCopy.reverseSeam)
    }

    /// A jump much larger than the previous shift stays a seam, even inside one segment.
    func testAliasJumpFarFromLastShiftOpensASeam() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 12)), .appended(12))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 42)), .unmatched)
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.needsReview)
        XCTAssertEqual(assembly.seams.last?.note, StitchCopy.reverseSeam)
    }

    /// One reverse candidate, and it copies rows already on the page. That opens a seam.
    func testReverseSingleCandidateFalseMatchOpensSeam() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 0, height: 48, slot: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 12, height: 48, slot: 0)), .appended(12))
        let outcome = stitcher.ingest(CoreScrollFixtures.falseReverse())
        XCTAssertNotEqual(outcome, .ignored)
        XCTAssertEqual(outcome, .unmatched)
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.needsReview)
        XCTAssertNil(assembly.flattenedIfResolved())
        XCTAssertEqual(assembly.seams.count, 1)
        XCTAssertEqual(assembly.seams.last?.note, StitchCopy.reverseSeam)
    }

    /// Repeating card chrome used to invent a second shift once the scroll passed one card.
    func testRepeatingCardChromeWithCompetingCandidatesStitchesTrueShift() throws {
        let shift = 28
        let first = CoreScrollFixtures.competingCards(scroll: 0)
        let second = CoreScrollFixtures.competingCards(scroll: shift)
        try assertStitchedRows(first, second, shift: shift)
    }

    /// Neighbors 10 px and 11 px used to be two joins. They are one scroll.
    func testNeighboringRowsWithReplacedFirstRowClusterIntoOneJoin() throws {
        let first = CoreScrollFixtures.neighboringRows(scroll: 0)
        let second = CoreScrollFixtures.neighboringRows(scroll: 10, replaceFirstRowWithPage: 11)
        try assertStitchedRows(first, second, shift: 10)
    }

    private func assertDownwardJoin(
        _ first: RGBAImage,
        _ second: RGBAImage,
        shift: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(first), .seeded, file: file, line: line)
        XCTAssertEqual(stitcher.ingest(second), .appended(shift), file: file, line: line)
        let assembly = stitcher.takeAssembly()
        XCTAssertFalse(assembly.needsReview, file: file, line: line)
        let image = try XCTUnwrap(assembly.flattenedIfResolved(), file: file, line: line)
        XCTAssertEqual(image.height, first.height + shift, file: file, line: line)
        XCTAssertEqual(
            CoreScrollFixtures.row(image, image.height - 1),
            CoreScrollFixtures.row(second, second.height - 1),
            file: file,
            line: line
        )
    }

    /// A blank-dominated scroll must open a seam. Dropping it as flicker hides the rows.
    private func assertBlankOpensASeam(
        _ first: RGBAImage,
        _ second: RGBAImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(first), .seeded, file: file, line: line)
        let outcome = stitcher.ingest(second)
        XCTAssertNotEqual(outcome, .ignored, file: file, line: line)
        XCTAssertEqual(outcome, .unmatched, file: file, line: line)
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.needsReview, file: file, line: line)
        XCTAssertNil(assembly.flattenedIfResolved(), file: file, line: line)
        XCTAssertEqual(assembly.seams.count, 1, file: file, line: line)
        XCTAssertEqual(assembly.seams.first?.note, StitchCopy.blankSeam, file: file, line: line)
    }

    private func assertStitchedRows(
        _ first: RGBAImage,
        _ second: RGBAImage,
        shift: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(first), .seeded, file: file, line: line)
        let outcome = stitcher.ingest(second)
        XCTAssertEqual(outcome, .appended(shift), file: file, line: line)
        // A wrong shift used to walk off the image and abort the suite.
        guard outcome == .appended(shift) else { return }
        let assembly = stitcher.takeAssembly()
        XCTAssertFalse(assembly.needsReview, file: file, line: line)
        let image = try XCTUnwrap(assembly.flattenedIfResolved(), file: file, line: line)
        XCTAssertEqual(image.height, first.height + shift, file: file, line: line)
        guard image.height == first.height + shift else { return }
        for y in 0..<first.height {
            XCTAssertEqual(CoreScrollFixtures.row(image, y), CoreScrollFixtures.row(first, y), "kept row \(y)", file: file, line: line)
        }
        let stripStart = second.height - shift
        for offset in 0..<shift {
            XCTAssertEqual(
                CoreScrollFixtures.row(image, first.height + offset),
                CoreScrollFixtures.row(second, stripStart + offset),
                "new row \(offset)",
                file: file,
                line: line
            )
        }
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

        let measured = try stopPeak(of: &stitcher, ledger: ledger)
        let imageBytes = measured.imageBytes
        // Estimate only: a815b78 kept three full buffers alive together. Not measured on that revision.
        let before = imageBytes * 3
        print("AC-L19 scroll-down peak bytes before≈\(before) (estimate, 3x full image, not measured) after=\(measured.peak) (measured) imageBytes=\(imageBytes) height=\(measured.height) cg=\(measured.cgWidth)x\(measured.cgHeight)")

        XCTAssertEqual(measured.width, width)
        XCTAssertEqual(measured.height, target)
        XCTAssertEqual(measured.cgWidth, width)
        XCTAssertEqual(measured.cgHeight, target)
        XCTAssertLessThan(measured.peak, imageBytes * 2, "stop path still retains a second full-image copy")
        XCTAssertLessThan(measured.peak, before)
    }

    func testStickyHeaderFooterStopPeakStaysUnderTwoImages() throws {
        let width = 1440
        let viewport = 60
        let header = 10
        let footer = 8
        let shift = 20
        let target = 20_000
        var options = ScrollStitcher.Options()
        options.maxHeight = target
        options.maxPixels = width * target
        let ledger = AllocationLedger()
        PixelMetrics.threadLedger = ledger
        defer { PixelMetrics.threadLedger = nil }

        var stitcher = ScrollStitcher(options: options)
        let steps = (target - viewport) / shift
        XCTAssertEqual(stitcher.ingest(stickyFrame(origin: 0, width: width, height: viewport, header: header, footer: footer)), .seeded)
        for step in 1...steps {
            let outcome = stitcher.ingest(stickyFrame(origin: step * shift, width: width, height: viewport, header: header, footer: footer))
            guard case .appended(let rows) = outcome else {
                XCTFail("sticky step \(step) expected append, got \(outcome)")
                return
            }
            XCTAssertEqual(rows, shift, "sticky step \(step)")
        }
        let measured = try stopPeak(of: &stitcher, ledger: ledger)
        reportPeak("sticky-bars", measured: measured)
        XCTAssertEqual(measured.height, target)
        XCTAssertLessThan(measured.peak, measured.imageBytes * 2)
    }

    func testScrollUpStopPeakStaysUnderTwoImages() throws {
        let width = 1440
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
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.uniqueFrame(origin: steps * shift, width: width, height: viewport)), .seeded)
        for step in 1...steps {
            let origin = (steps - step) * shift
            let outcome = stitcher.ingest(CoreScrollFixtures.uniqueFrame(origin: origin, width: width, height: viewport))
            guard case .prepended(let rows) = outcome else {
                XCTFail("scroll-up step \(step) expected prepend, got \(outcome)")
                return
            }
            XCTAssertEqual(rows, shift, "scroll-up step \(step)")
        }
        let measured = try stopPeak(of: &stitcher, ledger: ledger)
        reportPeak("scroll-up", measured: measured)
        XCTAssertEqual(measured.height, target)
        XCTAssertLessThan(measured.peak, measured.imageBytes * 2)
    }

    /// 2 px per frame with a sticky header and footer. 1 px is below the confident-bar threshold.
    func testSlowStickyScrollStopPeakStaysUnderTwoImages() throws {
        let width = 1440
        let viewport = 60
        let header = 10
        let footer = 8
        let shift = 2
        let target = 20_000
        var options = ScrollStitcher.Options()
        options.maxHeight = target
        options.maxPixels = width * target
        let ledger = AllocationLedger()
        PixelMetrics.threadLedger = ledger
        defer { PixelMetrics.threadLedger = nil }

        var stitcher = ScrollStitcher(options: options)
        let steps = (target - viewport) / shift
        XCTAssertEqual(stitcher.ingest(stickyFrame(origin: 0, width: width, height: viewport, header: header, footer: footer)), .seeded)
        for step in 1...steps {
            let outcome = stitcher.ingest(stickyFrame(origin: step * shift, width: width, height: viewport, header: header, footer: footer))
            guard case .appended(let rows) = outcome else {
                XCTFail("slow step \(step) expected append, got \(outcome)")
                return
            }
            XCTAssertEqual(rows, shift, "slow step \(step)")
        }
        let measured = try stopPeak(of: &stitcher, ledger: ledger)
        reportPeak("slow-scroll", measured: measured)
        XCTAssertEqual(measured.height, target)
        XCTAssertLessThan(measured.peak, measured.imageBytes * 2)
    }

    private struct StopMeasurement {
        var peak: Int
        var imageBytes: Int
        var width: Int
        var height: Int
        var cgWidth: Int
        var cgHeight: Int
    }

    func testPendingConfirmCountsUnresolvedDuplicateCandidates() {
        var assembly = ScrollAssembly(duplicateCandidates: Self.threeDuplicateCandidates)

        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 3)
        XCTAssertEqual(assembly.reviewRemainder.pendingConfirm, 3)
        XCTAssertEqual(assembly.reviewBottomBar, Self.confirmBar(3))
        XCTAssertTrue(assembly.needsReview)

        assembly.resolveDuplicateCandidate("dup-1", choice: .keepOnce)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 2)
        XCTAssertEqual(assembly.reviewBottomBar, Self.confirmBar(2))

        assembly.resolveDuplicateCandidate("dup-2", choice: .keepBoth)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(assembly.reviewBottomBar, Self.confirmBar(1))

        assembly.resolveDuplicateCandidate("dup-3", choice: .keepOnce)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertNil(assembly.reviewBottomBar)
        XCTAssertFalse(assembly.needsReview)

        assembly.undoLastDuplicateCandidateChoice()
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(assembly.reviewRemainder.pendingConfirm, 1)
        XCTAssertEqual(assembly.reviewBottomBar, Self.confirmBar(1))
        XCTAssertNil(assembly.duplicateCandidates.first { $0.id == "dup-3" }?.choice)
        XCTAssertTrue(assembly.needsReview)
    }

    func testPendingConfirmIgnoresUnalignedSeamsAndStickyBar() {
        let sticky = PendingStickyConfirmation(headerRows: 8, footerRows: 0, seamCount: 3, keepOnce: nil)
        var assembly = ScrollAssembly(
            seams: [
                ScrollSeam(kind: .needsAlignment, suggestedOverlap: 12),
                ScrollSeam(kind: .needsAlignment, suggestedOverlap: 4),
            ],
            pendingSticky: sticky,
            duplicateCandidates: Self.threeDuplicateCandidates
        )

        XCTAssertEqual(assembly.unalignedSeamCount, 2)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 3)
        XCTAssertTrue(assembly.reviewRemainder.stickyPending)
        XCTAssertEqual(
            assembly.reviewBottomBar,
            "⚠ 还有 6 处没处理（待对齐 2 · 待确认 3 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertEqual(assembly.pendingSticky?.prompt, sticky.prompt)

        assembly.resolveDuplicateCandidate("dup-1", choice: .keepBoth)
        assembly.resolveDuplicateCandidate("dup-2", choice: .keepOnce)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(assembly.unalignedSeamCount, 2)
        XCTAssertTrue(assembly.pendingSticky?.isUnresolved == true)
        XCTAssertEqual(assembly.reviewRemainder.unaligned, 2)
        XCTAssertEqual(assembly.reviewRemainder.pendingConfirm, 1)
        XCTAssertTrue(assembly.reviewRemainder.stickyPending)

        assembly.resolveDuplicateCandidate("dup-3", choice: .keepBoth)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertEqual(assembly.unalignedSeamCount, 2)
        XCTAssertEqual(
            assembly.reviewBottomBar,
            "⚠ 还有 3 处没处理（待对齐 2 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        let parts = assembly.reviewRemainder.detail.split(separator: "·").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        XCTAssertFalse(parts.contains { $0.hasPrefix("待确认") })
        XCTAssertFalse(parts.contains("待确认 0"))
    }

    func testRestoreByIdReopensOneCandidateAndUndoHidesTheBar() {
        var assembly = ScrollAssembly(duplicateCandidates: Self.threeDuplicateCandidates)
        assembly.resolveDuplicateCandidate("dup-1", choice: .keepOnce)
        assembly.resolveDuplicateCandidate("dup-2", choice: .keepBoth)
        assembly.resolveDuplicateCandidate("dup-3", choice: .keepOnce)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertNil(assembly.reviewBottomBar)

        assembly.restoreDuplicateCandidate("missing")
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertNil(assembly.reviewBottomBar)

        assembly.restoreDuplicateCandidate("dup-2")
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertNil(assembly.duplicateCandidates.first { $0.id == "dup-2" }?.choice)
        XCTAssertEqual(assembly.reviewBottomBar, Self.confirmBar(1))

        assembly.undoLastDuplicateCandidateChoice()
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertEqual(assembly.duplicateCandidates.first { $0.id == "dup-2" }?.choice, .keepBoth)
        XCTAssertNil(assembly.reviewBottomBar)
    }

    private static var threeDuplicateCandidates: [DuplicateSegmentCandidate] {
        (1...3).map { DuplicateSegmentCandidate(id: "dup-\($0)") }
    }

    private static func confirmBar(_ count: Int) -> String {
        "⚠ 还有 \(count) 处没处理（待确认 \(count)）。为了不拼错，处理完才能继续——不会静默拼接。"
    }

    private func stopPeak(of stitcher: inout ScrollStitcher, ledger: AllocationLedger) throws -> StopMeasurement {
        ledger.rebasePeak()
        let assembly = stitcher.takeAssembly()
        let stitched = try XCTUnwrap(assembly.flattenedIfResolved())
        let cg = try XCTUnwrap(stitched.cgImage())
        return StopMeasurement(
            peak: ledger.peakBytes,
            imageBytes: stitched.width * stitched.height * 4,
            width: stitched.width,
            height: stitched.height,
            cgWidth: cg.width,
            cgHeight: cg.height
        )
    }

    private func reportPeak(_ scenario: String, measured: StopMeasurement) {
        let before = measured.imageBytes * 3
        print("AC-L19 \(scenario) peak bytes before≈\(before) (estimate, 3x full image, not measured) after=\(measured.peak) (measured) imageBytes=\(measured.imageBytes) height=\(measured.height) cg=\(measured.cgWidth)x\(measured.cgHeight)")
        XCTAssertLessThan(measured.peak, before)
    }

    private func stickyFrame(origin: Int, width: Int, height: Int, header: Int, footer: Int) -> RGBAImage {
        fastFrame(width: width, height: height) { y in
            if y < header { return CoreScrollFixtures.color(slot: y) }
            if y >= height - footer { return CoreScrollFixtures.color(slot: 100 + (y - (height - footer))) }
            return CoreScrollFixtures.color(slot: CoreScrollFixtures.contentSlot + origin + (y - header))
        }
    }

    /// Fills each row by doubling a 4-byte pixel so a 20,000 px capture stays practical in Debug.
    private func fastFrame(width: Int, height: Int, rowColor: (Int) -> [UInt8]) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                let rgb = rowColor(y)
                let dest = base.advanced(by: y * width * 4)
                dest[0] = rgb[0]
                dest[1] = rgb[1]
                dest[2] = rgb[2]
                dest[3] = 255
                var filled = 1
                while filled < width {
                    let count = min(filled, width - filled)
                    dest.advanced(by: filled * 4).update(from: dest, count: count * 4)
                    filled += count
                }
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
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

    static func sparseViewport(scroll: Int, height: Int, contentRows: Int) -> RGBAImage {
        let start = height - contentRows
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in start..<height {
            let rgb = color(slot: contentSlot + (y - start) + scroll)
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    static func fixedBarViewport(scroll: Int, height: Int, barRows: Int) -> RGBAImage {
        fill(width: width, height: height) { y in
            if y < barRows { return y }
            return contentSlot + y + scroll
        }
    }

    /// Next downward page, with the previous page's top rows copied into the bottom.
    /// The copy is the only alignment, and it points backward.
    static func falseReverse(previousOrigin: Int = 12, height: Int = 48, reverse: Int = 16) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let slot = y < reverse ? previousOrigin + 12 + y : previousOrigin + (y - reverse)
            let rgb = color(slot: slot)
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    static func aliasPeriod(scroll: Int, height: Int = 90, period: Int = 60) -> RGBAImage {
        fill(width: width, height: height) { y in
            let pageY = y + scroll
            return (pageY % period + period) % period
        }
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

    /// White viewport, a 2-row solid band every 8 rows. Both rows of a band share one color.
    static func colorBands(scroll: Int, height: Int = 80, gap: Int = 6, thickness: Int = 2) -> RGBAImage {
        let period = gap + thickness
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let page = y + scroll
            let offset = page % period
            guard offset >= gap else { continue }
            let rgb = color(slot: 200 + page / period)
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    /// Slow ramp so a neighbor is a plausible match, without repeating across the frame.
    static func neighboringRows(scroll: Int, height: Int = 40, replaceFirstRowWithPage: Int? = nil) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let page = (y == 0 ? replaceFirstRowWithPage : nil) ?? (y + scroll)
            let rgb = neighboringColor(page)
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    static func neighboringColor(_ page: Int) -> [UInt8] {
        // Step sums to 9, so a neighbor is distance 3. Stays inside UInt8 for this fixture's pages.
        [UInt8(20 + page * 4), UInt8(page * 5), 160]
    }

    /// Card chrome repeats every 20 rows. The scroll is longer than one card, so chrome votes twice.
    static func competingCards(scroll: Int, height: Int = 100, card: Int = 20, chrome: Int = 12) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let page = y + scroll
            let offset = page % card
            let rgb: [UInt8]
            if offset < chrome {
                rgb = [UInt8(30 + (offset % 5) * 40), UInt8(40 + (offset % 3) * 50), 80]
            } else {
                rgb = [UInt8(truncatingIfNeeded: page &* 17), UInt8(truncatingIfNeeded: page &* 13 &+ 40), 200]
            }
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }
}
