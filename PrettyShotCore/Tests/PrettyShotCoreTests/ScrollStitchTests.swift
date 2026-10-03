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

    func testKeepOnceThenRestoreBringsTheCandidateBack() {
        var assembly = ScrollAssembly(duplicateCandidates: [DuplicateSegmentCandidate(id: "dup-1", seamNumber: 2, rowCount: 2)])
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        assembly.resolveDuplicateCandidate("dup-1", choice: .keepOnce)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertNil(assembly.reviewBottomBar)

        let beforeRestore = assembly.duplicateUndoCount
        assembly.restoreDuplicateCandidate("dup-1")
        XCTAssertEqual(assembly.duplicateUndoCount, beforeRestore + 1)
        XCTAssertNil(assembly.duplicateCandidates[0].choice)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(assembly.reviewBottomBar, Self.confirmBar(1))
        XCTAssertEqual(assembly.duplicateCandidates[0].pendingTitle(displayIndex: 1), "重复段 1 · 待确认")
        XCTAssertEqual(assembly.duplicateCandidates[0].locationLine, "接缝 2 下方 · 2 行")
        XCTAssertEqual(StitchCopy.duplicateDetail, "这段内容出现了两次")
        XCTAssertEqual(StitchCopy.duplicateHandled(.keepOnce), "✓ 已处理 · 只保留一次")
        XCTAssertEqual(StitchCopy.duplicateHandled(.keepBoth), "✓ 已处理 · 都保留")
        XCTAssertEqual(
            StitchCopy.duplicateRestoredToast(index: 1, remaining: 1),
            "重复段 1 已还原为待确认 · 待确认还剩 1 处"
        )
    }

    func testRestoringTheSameCandidateTwicePushesOneUndoEntry() {
        var assembly = ScrollAssembly(duplicateCandidates: [DuplicateSegmentCandidate(id: "dup-1")])
        assembly.resolveDuplicateCandidate("dup-1", choice: .keepBoth)
        let before = assembly.duplicateUndoCount
        assembly.restoreDuplicateCandidate("dup-1")
        assembly.restoreDuplicateCandidate("dup-1")
        XCTAssertEqual(assembly.duplicateUndoCount, before + 1)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)

        assembly.undoLastDuplicateCandidateChoice()
        XCTAssertEqual(assembly.duplicateCandidates[0].choice, .keepBoth)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
    }

    func testUndoOfRestoreStillReachesTheEarlierChoice() {
        var assembly = ScrollAssembly(duplicateCandidates: [DuplicateSegmentCandidate(id: "dup-1")])
        assembly.resolveDuplicateCandidate("dup-1", choice: .keepOnce)
        assembly.resolveDuplicateCandidate("dup-1", choice: .keepBoth)
        assembly.restoreDuplicateCandidate("dup-1")
        XCTAssertNil(assembly.duplicateCandidates[0].choice)

        assembly.undoLastDuplicateCandidateChoice()
        XCTAssertEqual(assembly.duplicateCandidates[0].choice, .keepBoth)
        assembly.undoLastDuplicateCandidateChoice()
        XCTAssertEqual(assembly.duplicateCandidates[0].choice, .keepOnce)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
    }

    func testPreviewPrimaryCountsSeamsStickyAndDuplicatesSeparately() {
        var mixed = ScrollAssembly(
            seams: [ScrollSeam(kind: .needsAlignment, suggestedOverlap: 4)],
            pendingSticky: PendingStickyConfirmation(headerRows: 8, footerRows: 0, seamCount: 7, keepOnce: nil),
            duplicateCandidates: [DuplicateSegmentCandidate(id: "dup-1")]
        )
        XCTAssertEqual(mixed.previewPrimaryTitle, "处理下一处 · 1")
        XCTAssertEqual(mixed.unalignedSeamCount, 1)
        XCTAssertNotEqual(mixed.previewPrimaryTitle, "处理下一处 · 8")

        mixed.joinAsIs(seam: 0)
        XCTAssertEqual(mixed.previewPrimaryTitle, "处理下一处 · 1")
        XCTAssertEqual(mixed.pendingDuplicateConfirmCount, 1)

        mixed.confirmStickyBars(keepOnce: true)
        XCTAssertEqual(mixed.previewPrimaryTitle, "先确认 1 处重复段")

        mixed.resolveDuplicateCandidate("dup-1", choice: .keepBoth)
        XCTAssertEqual(mixed.previewPrimaryTitle, "下一步 · 美化 →")
        XCTAssertNil(mixed.reviewBottomBar)

        var seamsOnly = ScrollAssembly(seams: [
            ScrollSeam(kind: .needsAlignment, suggestedOverlap: 2),
            ScrollSeam(kind: .needsAlignment, suggestedOverlap: 3),
        ])
        XCTAssertEqual(seamsOnly.previewPrimaryTitle, "处理下一处 · 2")

        let stickyOnly = ScrollAssembly(
            pendingSticky: PendingStickyConfirmation(headerRows: 6, footerRows: 0, seamCount: 4, keepOnce: nil)
        )
        XCTAssertEqual(stickyOnly.previewPrimaryTitle, "处理下一处 · 1")

        let duplicatesOnly = ScrollAssembly(duplicateCandidates: Self.threeDuplicateCandidates)
        XCTAssertEqual(duplicatesOnly.previewPrimaryTitle, "先确认 3 处重复段")
        XCTAssertEqual(StitchCopy.handleUnaligned(2), "先处理 2 处待对齐")
    }

    func testBottomBarKeepsDuplicateAndStickyCountsSeparate() {
        XCTAssertEqual(
            StitchCopy.bottomBar(.init(pendingConfirm: 1)),
            "⚠ 还有 1 处没处理（待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertEqual(
            StitchCopy.bottomBar(.init(pendingConfirm: 1, stickyPending: true)),
            "⚠ 还有 2 处没处理（待确认 1 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertEqual(
            StitchCopy.bottomBar(.init(unaligned: 1, pendingConfirm: 1, stickyPending: true)),
            "⚠ 还有 3 处没处理（待对齐 1 · 待确认 1 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        let mixed = StitchCopy.Remainder(unaligned: 1, pendingConfirm: 1, stickyPending: true)
        XCTAssertEqual(mixed.count, 3)
        XCTAssertFalse(mixed.detail.contains("重复段待确认"))
    }

    func testRestitchActionsClearCandidatesAndTheUndoStack() {
        func loaded() -> ScrollAssembly {
            let image = RGBAImage(width: 8, height: 12, pixels: [UInt8](repeating: 255, count: 8 * 12 * 4))
            let segment = ScrollSegment(image: image, confidentSeamYs: [])
            var assembly = ScrollAssembly(
                segments: [segment, segment],
                seams: [ScrollSeam(kind: .needsAlignment, suggestedOverlap: 6)],
                duplicateCandidates: [DuplicateSegmentCandidate(id: "dup-1")]
            )
            assembly.resolveDuplicateCandidate("dup-1", choice: .keepOnce)
            assembly.resolveDuplicateCandidate("dup-1", choice: .keepBoth)
            XCTAssertGreaterThan(assembly.duplicateUndoCount, 0)
            return assembly
        }

        var started = loaded()
        started.beginStitch()
        XCTAssertTrue(started.duplicateCandidates.isEmpty)
        XCTAssertEqual(started.duplicateUndoCount, 0)
        started.undoLastDuplicateCandidateChoice()
        XCTAssertTrue(started.duplicateCandidates.isEmpty)

        var finished = loaded()
        finished.align(seam: 0, overlap: 3)
        finished.completeManualAlignment()
        XCTAssertTrue(finished.duplicateCandidates.isEmpty)
        XCTAssertEqual(finished.duplicateUndoCount, 0)
        if case .aligned(let overlap) = finished.seams[0].kind {
            XCTAssertEqual(overlap, 3)
        } else {
            XCTFail("manual alignment stays on the seam")
        }

        var restored = loaded()
        restored.restoreAutoAlignment(seam: 0)
        XCTAssertTrue(restored.duplicateCandidates.isEmpty)
        XCTAssertEqual(restored.duplicateUndoCount, 0)
        if case .aligned(let overlap) = restored.seams[0].kind {
            XCTAssertEqual(overlap, 6)
        } else {
            XCTFail("restore automatic alignment applies the suggestion")
        }
    }

    func testConfidentOnePassStitchDoesNotAskAboutDuplicates() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.viewport(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.viewport(scroll: 15)), .appended(15))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.viewport(scroll: 30)), .appended(15))
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.duplicateCandidates.isEmpty)
        XCTAssertEqual(assembly.duplicateUndoCount, 0)
        XCTAssertFalse(assembly.needsReview)
        XCTAssertFalse(assembly.opensStitchReview)
        XCTAssertNil(assembly.reviewBottomBar)
        XCTAssertEqual(assembly.previewPrimaryTitle, "下一步 · 美化 →")
        XCTAssertEqual(assembly.flattenedIfResolved()?.height, 90)
    }

    func testUncertainRepeatedRunBecomesOneDuplicateCandidate() throws {
        var stitcher = ScrollStitcher()
        stitcher.beginStitch()
        let first = Self.slottedFrame(Array(0..<24))
        var secondSlots = Array(8..<32)
        secondSlots[18] = 2
        secondSlots[19] = 3
        XCTAssertEqual(stitcher.ingest(first), .seeded)
        let outcome = stitcher.ingest(Self.slottedFrame(secondSlots))
        guard case .appended(let rows) = outcome else {
            XCTFail("a short repeat inside a confident join should still stitch, got \(outcome)")
            return
        }
        XCTAssertEqual(rows, 8)
        let assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertTrue(assembly.seams.isEmpty)
        XCTAssertEqual(assembly.duplicateCandidates.count, 1)
        let candidate = try XCTUnwrap(assembly.duplicateCandidates.first)
        XCTAssertEqual(candidate.rowCount, 2)
        XCTAssertEqual(candidate.seamNumber, 1)
        XCTAssertTrue(candidate.isUnresolved)
        XCTAssertEqual(candidate.locationLine, "接缝 1 下方 · 2 行")
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(assembly.previewPrimaryTitle, "先确认 1 处重复段")
        XCTAssertNil(assembly.flattenedIfResolved())
        XCTAssertEqual(assembly.segments[0].image.height, 32)

        var keepBoth = assembly
        keepBoth.resolveDuplicateCandidate(candidate.id, choice: .keepBoth)
        XCTAssertEqual(keepBoth.flattenedIfResolved()?.height, 32)
        XCTAssertFalse(keepBoth.needsReview)

        var keepOnce = assembly
        keepOnce.resolveDuplicateCandidate(candidate.id, choice: .keepOnce)
        let shortened = try XCTUnwrap(keepOnce.flattenedIfResolved())
        XCTAssertEqual(shortened.height, 30)

        var restarted = ScrollStitcher()
        restarted.beginStitch()
        XCTAssertEqual(restarted.ingest(first), .seeded)
        XCTAssertEqual(restarted.ingest(Self.slottedFrame(secondSlots)), .appended(8))
        let fresh = restarted.takeAssembly()
        XCTAssertEqual(fresh.duplicateCandidates.count, 1)
        XCTAssertEqual(fresh.duplicateUndoCount, 0)
        XCTAssertTrue(fresh.duplicateCandidates.allSatisfy(\.isUnresolved))
    }

    private static func slottedFrame(_ slots: [Int]) -> RGBAImage {
        let width = CoreScrollFixtures.width
        var pixels = [UInt8](repeating: 255, count: width * slots.count * 4)
        for (y, slot) in slots.enumerated() {
            let rgb = CoreScrollFixtures.color(slot: slot)
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
            }
        }
        return RGBAImage(width: width, height: slots.count, pixels: pixels)
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
