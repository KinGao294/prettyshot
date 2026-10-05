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
        let tie = "找到 2 个都说得通的位移，自动对齐没法确定是哪一个——为了不拼错，先停下来请你确认。"
        let card = try XCTUnwrap(assembly.seams.last).card(number: 1)
        XCTAssertEqual(card.title, "接缝 1 · 待确认：位移无法唯一确定")
        XCTAssertEqual(card.reason, tie)
        XCTAssertFalse(card.reason?.contains("得分相同") == true)
        XCTAssertNotEqual(card.reason, StitchCopy.reverseSeam)
        XCTAssertFalse(card.reason?.contains("这一段是重复的列表行") == true)
        XCTAssertEqual(card.candidates, ["位移 A · +32 px · 当前", "位移 B · −28 px"])
    }

    /// A jump much larger than the previous shift stays a seam, even inside one segment.
    /// +30 and −30 score the same, so the reason is the tie, not a reverse scroll.
    func testAliasJumpFarFromLastShiftOpensASeam() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 12)), .appended(12))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 42)), .unmatched)
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.needsReview)
        let tie = "找到 2 个都说得通的位移，自动对齐没法确定是哪一个——为了不拼错，先停下来请你确认。"
        let card = try XCTUnwrap(assembly.seams.last).card(number: 1)
        XCTAssertEqual(card.title, "接缝 1 · 待确认：位移无法唯一确定")
        XCTAssertEqual(card.reason, tie)
        XCTAssertFalse(card.reason?.contains("得分相同") == true)
        XCTAssertNotEqual(card.reason, StitchCopy.reverseSeam)
        XCTAssertFalse(card.reason?.contains("这一段是重复的列表行") == true)
        XCTAssertEqual(card.candidates, ["位移 A · +30 px · 当前", "位移 B · −30 px"])
    }

    /// A rival whose score is close, but not equal, still opens the tie card.
    func testNearScoreOppositeShiftOpensATie() throws {
        XCTAssertEqual(AliasRival.shiftGap, 2)
        XCTAssertEqual(AliasRival.scoreSlack, 4)
        XCTAssertEqual(AliasRival.voteFactor, 2)
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 12)), .appended(12))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriodNearMiss()), .unmatched)
        let assembly = stitcher.takeAssembly()
        let tie = "找到 2 个都说得通的位移，自动对齐没法确定是哪一个——为了不拼错，先停下来请你确认。"
        let card = try XCTUnwrap(assembly.seams.last).card(number: 1)
        XCTAssertEqual(card.label, "待确认")
        XCTAssertEqual(card.chrome, .amberDashed)
        XCTAssertEqual(card.title, "接缝 1 · 待确认：位移无法唯一确定")
        XCTAssertEqual(card.reason, tie)
        XCTAssertNotEqual(card.reason, StitchCopy.reverseSeam)
        XCTAssertFalse(card.reason?.contains("得分相同") == true)
        XCTAssertFalse(card.reason?.contains("这一段是重复的列表行") == true)
        XCTAssertEqual(card.candidates, ["位移 A · +30 px · 当前", "位移 B · −30 px"])
        XCTAssertEqual(assembly.unalignedSeamCount, 1)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
    }

    /// The equal-score tie is one of the seams the review bar counts as 待对齐.
    func testTieSeamCountsAsUnalignedAndUsesAmberStyle() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 12)), .appended(12))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 42)), .unmatched)
        let assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.unalignedSeamCount, 1)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        let bar = try XCTUnwrap(assembly.reviewBottomBar)
        XCTAssertTrue(bar.contains("待对齐 1"))
        XCTAssertFalse(bar.contains("待确认"))
        let card = try XCTUnwrap(assembly.seams.last).card(number: 1)
        XCTAssertEqual(card.label, "待确认")
        XCTAssertEqual(card.chrome, .amberDashed)
        let preview = try XCTUnwrap(assembly.renderPreview())
        let mark = try XCTUnwrap(preview.marks.first { $0.boundaryIndex == 0 })
        XCTAssertGreaterThan(warnPixels(around: mark, in: preview.image), 0)
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
        let seam = try XCTUnwrap(assembly.seams.last)
        let card = seam.card(number: 1)
        XCTAssertEqual(card.label, "待确认")
        XCTAssertEqual(card.chrome, .amberDashed)
        XCTAssertNotEqual(card.label, "需要对齐")
        XCTAssertEqual(card.reason, StitchCopy.reverseSeam)
        XCTAssertEqual(assembly.unalignedSeamCount, 1)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        let bar = try XCTUnwrap(assembly.reviewBottomBar)
        XCTAssertTrue(bar.contains("待对齐 1"))
        XCTAssertFalse(bar.contains("待确认"))
        XCTAssertEqual(PendingSeamStyle.warn, 0xE3B26B)
        XCTAssertEqual(PendingSeamStyle.text, 0x8A5A12)
        XCTAssertEqual(PendingSeamStyle.fillOpacity, 0.18, accuracy: 0.001)
        XCTAssertEqual(PendingSeamStyle.labelBorderWidth, 1)
        XCTAssertEqual(PendingSeamStyle.seamLineWidth, 3)
        let preview = try XCTUnwrap(assembly.renderPreview())
        let mark = try XCTUnwrap(preview.marks.first { $0.state == .needsAlignment })
        XCTAssertLessThan(mark.y, preview.image.height)
        let pixels = preview.image.pixels
        let warn = (UInt8(0xE3), UInt8(0xB2), UInt8(0x6B))
        var warnCount = 0
        var otherCount = 0
        for x in 0..<preview.image.width {
            let i = (mark.y * preview.image.width + x) * 4
            let sample = (pixels[i], pixels[i + 1], pixels[i + 2])
            if sample == warn {
                warnCount += 1
            } else {
                otherCount += 1
            }
        }
        XCTAssertGreaterThan(warnCount, 0)
        XCTAssertGreaterThan(otherCount, 0)
        var warnRows = 0
        for dy in -2...2 {
            let row = mark.y + dy
            guard row >= 0, row < preview.image.height else { continue }
            let hasWarn = (0..<preview.image.width).contains { x in
                let i = (row * preview.image.width + x) * 4
                return (pixels[i], pixels[i + 1], pixels[i + 2]) == warn
            }
            if hasWarn { warnRows += 1 }
        }
        XCTAssertEqual(warnRows, 3)
    }

    /// 按此对齐 on the auto-selected 「当前」 shift confirms it.
    func testAligningTheAutoSelectedShiftShowsConfirmed() throws {
        var assembly = try openShiftTie()
        let seam = try XCTUnwrap(assembly.seams.first)
        let current = try XCTUnwrap(seam.candidateLines.first { $0.contains("当前") })
        let frameHeight = try XCTUnwrap(assembly.segments.last).image.height
        let suggested = try XCTUnwrap(seam.suggestedOverlap)
        XCTAssertEqual(suggested, frameHeight - shiftPixels(in: current))
        assembly.align(seam: 0, overlap: suggested)
        let card = assembly.seams[0].card(number: 1)
        XCTAssertEqual(card.label, "✓ 已确认")
        XCTAssertEqual(card.labelColor, 0x4F8F7E)
        XCTAssertEqual(ResolvedSeamStyle.mint, 0x4F8F7E)
        XCTAssertEqual(card.chrome, .plain)
        XCTAssertNil(card.title)
        XCTAssertTrue(card.candidates.isEmpty)
        XCTAssertEqual(assembly.unalignedSeamCount, 0)
        try assertResolvedSeamHasNoAmber(assembly)
    }

    /// Picking 位移 B, then aligning, is 「✓ 手动对齐」.
    func testAligningADifferentCandidateShowsManualAlignment() throws {
        var picked = try openShiftTie()
        let seam = try XCTUnwrap(picked.seams.first)
        let other = try XCTUnwrap(seam.candidateLines.first { !$0.contains("当前") })
        let frameHeight = try XCTUnwrap(picked.segments.last).image.height
        let overlap = frameHeight - shiftPixels(in: other)
        XCTAssertNotEqual(overlap, seam.suggestedOverlap)
        picked.align(seam: 0, overlap: overlap)
        let pickedCard = picked.seams[0].card(number: 1)
        XCTAssertEqual(pickedCard.label, "✓ 手动对齐")
        XCTAssertEqual(pickedCard.labelColor, 0x4F8F7E)
        XCTAssertEqual(ResolvedSeamStyle.mint, 0x4F8F7E)
        XCTAssertEqual(pickedCard.chrome, .plain)
        XCTAssertNil(pickedCard.title)
        XCTAssertTrue(pickedCard.candidates.isEmpty)
        try assertResolvedSeamHasNoAmber(picked)
    }

    /// Moving the overlap slider, then aligning, is also 「✓ 手动对齐」.
    func testAligningAfterMovingTheSliderShowsManualAlignment() throws {
        var slid = try openShiftTie()
        let suggested = try XCTUnwrap(slid.seams[0].suggestedOverlap)
        slid.align(seam: 0, overlap: suggested + 4)
        let slidCard = slid.seams[0].card(number: 1)
        XCTAssertEqual(slidCard.label, "✓ 手动对齐")
        XCTAssertEqual(slidCard.labelColor, 0x4F8F7E)
        XCTAssertEqual(slidCard.chrome, .plain)
        XCTAssertNil(slidCard.title)
        XCTAssertTrue(slidCard.candidates.isEmpty)
        try assertResolvedSeamHasNoAmber(slid)
    }

    /// 按原样拼接 leaves a neutral gray 「直接拼」 label and a plain seam.
    func testJoiningAsIsShowsDirectStitch() throws {
        var assembly = try openShiftTie()
        assembly.joinAsIs(seam: 0)
        let card = assembly.seams[0].card(number: 1)
        XCTAssertEqual(card.label, "直接拼")
        XCTAssertEqual(card.labelColor, 0x5C5751)
        XCTAssertEqual(ResolvedSeamStyle.direct, 0x5C5751)
        XCTAssertEqual(card.chrome, .plain)
        XCTAssertNil(card.title)
        XCTAssertTrue(card.candidates.isEmpty)
        XCTAssertEqual(assembly.unalignedSeamCount, 0)
        try assertResolvedSeamHasNoAmber(assembly)
    }

    /// 恢复自动对齐 puts a resolved confirmation seam back on the amber 「待确认」 card.
    func testRestoreAutoAlignmentReturnsToPendingConfirmation() throws {
        var assembly = try openShiftTie()
        let suggested = try XCTUnwrap(assembly.seams[0].suggestedOverlap)
        assembly.align(seam: 0, overlap: suggested)
        assembly.restoreAutoAlignment(seam: 0)
        XCTAssertEqual(assembly.seams[0].kind, .needsAlignment)
        let card = assembly.seams[0].card(number: 1)
        XCTAssertEqual(card.label, "待确认")
        XCTAssertEqual(card.chrome, .amberDashed)
        XCTAssertEqual(card.title, "接缝 1 · 待确认：位移无法唯一确定")
        XCTAssertFalse(card.candidates.isEmpty)
        XCTAssertEqual(assembly.unalignedSeamCount, 1)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        let preview = try XCTUnwrap(assembly.renderPreview())
        let mark = try XCTUnwrap(preview.marks.first { $0.boundaryIndex == 0 })
        XCTAssertGreaterThan(warnPixels(around: mark, in: preview.image), 0)
    }

    private func openShiftTie() throws -> ScrollAssembly {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 106)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 118)), .appended(12))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 90)), .unmatched)
        let assembly = stitcher.takeAssembly()
        let seam = try XCTUnwrap(assembly.seams.first)
        XCTAssertEqual(seam.card(number: 1).label, "待确认")
        XCTAssertEqual(seam.card(number: 1).chrome, .amberDashed)
        return assembly
    }

    private func shiftPixels(in line: String) -> Int {
        Int(line.filter(\.isNumber)) ?? -1
    }

    private func assertResolvedSeamHasNoAmber(
        _ assembly: ScrollAssembly,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let preview = try XCTUnwrap(assembly.renderPreview(), file: file, line: line)
        let mark = try XCTUnwrap(preview.marks.first { $0.boundaryIndex == 0 }, file: file, line: line)
        XCTAssertEqual(amberPixels(around: mark, in: preview.image), 0, file: file, line: line)
    }

    private func amberPixels(around mark: SeamMark, in image: RGBAImage) -> Int {
        let ambers: [(UInt8, UInt8, UInt8)] = [
            (0xE3, 0xB2, 0x6B),
            (0xE8, 0xA3, 0x3D),
        ]
        var count = 0
        for dy in -2...2 {
            let row = mark.y + dy
            guard row >= 0, row < image.height else { continue }
            for x in 0..<image.width {
                let i = (row * image.width + x) * 4
                let sample = (image.pixels[i], image.pixels[i + 1], image.pixels[i + 2])
                if ambers.contains(where: { $0.0 == sample.0 && $0.1 == sample.1 && $0.2 == sample.2 }) {
                    count += 1
                }
            }
        }
        return count
    }

    private func warnPixels(around mark: SeamMark, in image: RGBAImage) -> Int {
        let warn = (UInt8(0xE3), UInt8(0xB2), UInt8(0x6B))
        var count = 0
        for dy in -2...2 {
            let row = mark.y + dy
            guard row >= 0, row < image.height else { continue }
            for x in 0..<image.width {
                let i = (row * image.width + x) * 4
                if (image.pixels[i], image.pixels[i + 1], image.pixels[i + 2]) == warn { count += 1 }
            }
        }
        return count
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
        // The new strip starts at row 16. Its first two rows repeat the previous frame's last two.
        secondSlots[16] = 22
        secondSlots[17] = 23
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

    func testIdenticalIconsWithDifferentTextDoNotBecomeCandidates() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(Self.listFrame(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(Self.listFrame(scroll: 8)), .appended(8))
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.duplicateCandidates.isEmpty)
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertFalse(assembly.needsReview)
        XCTAssertFalse(assembly.opensStitchReview)
        XCTAssertNil(assembly.reviewBottomBar)
        XCTAssertEqual(assembly.previewPrimaryTitle, "下一步 · 美化 →")
        XCTAssertEqual(assembly.flattenedIfResolved()?.height, 32)
    }

    func testRepeatedRowsAwayFromTheSeamAreNotCandidates() throws {
        var stitcher = ScrollStitcher()
        let first = Self.slottedFrame(Array(0..<24))
        var secondSlots = Array(8..<32)
        // Same two rows as the top of the previous frame, but not the rows across the seam.
        secondSlots[18] = 2
        secondSlots[19] = 3
        XCTAssertEqual(stitcher.ingest(first), .seeded)
        XCTAssertEqual(stitcher.ingest(Self.slottedFrame(secondSlots)), .appended(8))
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.duplicateCandidates.isEmpty)
        XCTAssertFalse(assembly.needsReview)
        XCTAssertEqual(assembly.flattenedIfResolved()?.height, 32)
        XCTAssertEqual(assembly.previewPrimaryTitle, "下一步 · 美化 →")
    }

    func testDuplicateSeamNumberCountsUnalignedSeamsBeforeIt() throws {
        let assembly = try Self.duplicateAfterUnalignedSeam()
        XCTAssertEqual(assembly.unalignedSeamCount, 1)
        XCTAssertEqual(assembly.duplicateCandidates.count, 1)
        let candidate = try XCTUnwrap(assembly.duplicateCandidates.first)
        XCTAssertEqual(candidate.seamNumber, 2)
        XCTAssertEqual(candidate.rowCount, 2)
        XCTAssertEqual(candidate.locationLine, "接缝 2 下方 · 2 行")
        XCTAssertEqual(assembly.previewPrimaryTitle, "处理下一处 · 1")
    }

    func testKeepOnceRowsStayOutOfOverLimitExport() throws {
        var assembly = try Self.seamAdjacentAssembly()
        let candidate = try XCTUnwrap(assembly.duplicateCandidates.first)
        let rawHeight = assembly.segments[0].image.height
        XCTAssertEqual(rawHeight, 32)
        assembly.resolveDuplicateCandidate(candidate.id, choice: .keepOnce)
        let keptHeight = rawHeight - candidate.rowCount
        XCTAssertEqual(assembly.stackedHeight(deduping: true), keptHeight)
        XCTAssertEqual(assembly.stackedHeight(deduping: false), keptHeight)

        let marker = CoreScrollFixtures.color(slot: 22)
        XCTAssertEqual(Self.rowHits(assembly.segments[0].image, rgb: marker), 2)

        for dedupe in [true, false] {
            let chunks = assembly.exportWithinLimits(dedupeStickyBars: dedupe, maxHeight: 16, maxPixels: 24_000_000)
            XCTAssertFalse(chunks.isEmpty)
            XCTAssertEqual(chunks.reduce(0) { $0 + $1.height }, keptHeight)
            let joined = try XCTUnwrap(RGBAImage.verticalJoin(chunks))
            XCTAssertEqual(joined.height, keptHeight)
            XCTAssertEqual(Self.rowHits(joined, rgb: marker), 1)
            for chunk in chunks {
                XCTAssertLessThanOrEqual(chunk.height, 16)
            }
        }
    }

    func testManualFinishRerunsDuplicateDetectionAndBlocksExport() throws {
        var assembly = try Self.duplicateAfterUnalignedSeam()
        let id = try XCTUnwrap(assembly.duplicateCandidates.first).id
        assembly.resolveDuplicateCandidate(id, choice: .keepOnce)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertGreaterThan(assembly.duplicateUndoCount, 0)
        assembly.align(seam: 0, overlap: 4)
        let summary = assembly.completeManualAlignment()

        // Seam 0 is 接缝 1 and crops the top of the next segment, so that candidate is cleared.
        // The card names 接缝 1, the same seam as the toast.
        XCTAssertEqual(assembly.duplicateUndoCount, 0)
        XCTAssertEqual(assembly.duplicateCandidates.count, 1)
        XCTAssertNil(assembly.duplicateCandidates[0].choice)
        XCTAssertTrue(assembly.duplicateCandidates[0].seamMoved)
        XCTAssertEqual(assembly.duplicateCandidates[0].movedSeamNumber, 1)
        XCTAssertEqual(assembly.duplicateCandidates[0].locationLine, "接缝 1 下方 · 2 行 · 接缝动过，需要重选")
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(summary.keptChoiceCount, 0)
        XCTAssertEqual(summary.clearedChoiceCount, 1)
        XCTAssertEqual(summary.clearedSeamNumber, 1)
        XCTAssertNil(assembly.flattenedIfResolved())
        XCTAssertEqual(assembly.previewPrimaryTitle, "先确认 1 处重复段")
        XCTAssertEqual(assembly.reviewBottomBar, Self.confirmBar(1))
        XCTAssertTrue(assembly.exportWithinLimits(dedupeStickyBars: true).isEmpty)
        if case .aligned(let overlap) = assembly.seams[0].kind {
            XCTAssertEqual(overlap, 4)
        } else {
            XCTFail("完成 keeps the manual overlap")
        }
    }

    func testRestoreAutoRerunsDuplicateDetectionAndBlocksExport() throws {
        var assembly = try Self.duplicateAfterUnalignedSeam()
        let id = try XCTUnwrap(assembly.duplicateCandidates.first).id
        assembly.resolveDuplicateCandidate(id, choice: .keepBoth)
        XCTAssertGreaterThan(assembly.duplicateUndoCount, 0)
        assembly.seams[0].suggestedOverlap = 5
        assembly.restoreAutoAlignment(seam: 0)

        // Restoring seam 0 away from the stored overlap crops the next segment, so that choice is cleared.
        // The card names 接缝 1, the same seam as the toast.
        XCTAssertEqual(assembly.duplicateUndoCount, 0)
        XCTAssertEqual(assembly.duplicateCandidates.count, 1)
        XCTAssertNil(assembly.duplicateCandidates[0].choice)
        XCTAssertTrue(assembly.duplicateCandidates[0].seamMoved)
        XCTAssertEqual(assembly.duplicateCandidates[0].movedSeamNumber, 1)
        XCTAssertEqual(assembly.duplicateCandidates[0].locationLine, "接缝 1 下方 · 2 行 · 接缝动过，需要重选")
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertNil(assembly.flattenedIfResolved())
        XCTAssertEqual(assembly.previewPrimaryTitle, "先确认 1 处重复段")
        XCTAssertNotNil(assembly.reviewBottomBar)
        XCTAssertTrue(assembly.exportWithinLimits(dedupeStickyBars: false).isEmpty)
        if case .aligned(let overlap) = assembly.seams[0].kind {
            XCTAssertEqual(overlap, 5)
        } else {
            XCTFail("还原自动 applies the suggestion")
        }
    }

    /// AC-L19: choosing 「只保留一次」 must not copy the whole capture on each preview or export.
    func testKeepOnceStopPeakStaysUnderTwoImages() throws {
        let width = 1440
        let viewport = 80
        let shift = 40
        let steps = 200
        let target = viewport + steps * shift
        var options = ScrollStitcher.Options()
        options.maxHeight = target
        options.maxPixels = width * target

        let ledger = AllocationLedger()
        PixelMetrics.threadLedger = ledger
        defer { PixelMetrics.threadLedger = nil }

        var stitcher = ScrollStitcher(options: options)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.uniqueFrame(origin: 0, width: width, height: viewport)), .seeded)
        for step in 1..<steps {
            let outcome = stitcher.ingest(CoreScrollFixtures.uniqueFrame(origin: step * shift, width: width, height: viewport))
            guard case .appended(let rows) = outcome else {
                XCTFail("step \(step) expected append, got \(outcome)")
                return
            }
            XCTAssertEqual(rows, shift, "step \(step)")
        }
        let origin = steps * shift
        let previousOrigin = origin - shift
        let duplicated = fastFrame(width: width, height: viewport) { y in
            if y == viewport - shift { return CoreScrollFixtures.color(slot: previousOrigin + viewport - 2) }
            if y == viewport - shift + 1 { return CoreScrollFixtures.color(slot: previousOrigin + viewport - 1) }
            return CoreScrollFixtures.color(slot: origin + y)
        }
        XCTAssertEqual(stitcher.ingest(duplicated), .appended(shift))

        ledger.rebasePeak()
        var assembly = stitcher.takeAssembly()
        let candidate = try XCTUnwrap(assembly.duplicateCandidates.first)
        XCTAssertEqual(assembly.duplicateCandidates.count, 1)
        assembly.resolveDuplicateCandidate(candidate.id, choice: .keepOnce)
        let hitsBefore = assembly.presentedCacheHits
        XCTAssertNotNil(assembly.renderPreview())
        let stitched = try XCTUnwrap(assembly.flattenedIfResolved())
        XCTAssertNotNil(assembly.renderPreview())
        XCTAssertGreaterThan(assembly.presentedCacheHits, hitsBefore)
        let cg = try XCTUnwrap(stitched.cgImage())
        let imageBytes = stitched.width * stitched.height * 4
        print("AC-L19 keep-once peak bytes before≈\(imageBytes * 3) (estimate, 3x full image, not measured) after=\(ledger.peakBytes) (measured) imageBytes=\(imageBytes) height=\(stitched.height)")
        XCTAssertEqual(stitched.width, width)
        XCTAssertEqual(stitched.height, target - candidate.rowCount)
        XCTAssertEqual(cg.width, width)
        XCTAssertEqual(cg.height, stitched.height)
        XCTAssertLessThan(ledger.peakBytes, imageBytes * 2, "只保留一次 still copies a second full image")
    }

    func testUndoKeepOnceRestoresTheCandidateAndTheRows() throws {
        var assembly = try Self.seamAdjacentAssembly()
        let candidate = try XCTUnwrap(assembly.duplicateCandidates.first)
        let raw = assembly.displayedSegmentHeight(0)
        assembly.resolveDuplicateCandidate(candidate.id, choice: .keepOnce)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertEqual(assembly.displayedSegmentHeight(0), raw - candidate.rowCount)
        XCTAssertTrue(assembly.duplicateRegionMarks().isEmpty)

        assembly.undoLastDuplicateCandidateChoice()
        XCTAssertNil(assembly.duplicateCandidates[0].choice)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(assembly.displayedSegmentHeight(0), raw)
        let mark = try XCTUnwrap(assembly.duplicateRegionMarks().first)
        XCTAssertEqual(mark.label, "重复段 1 · 待确认")
        XCTAssertEqual(mark.displayIndex, 1)
        XCTAssertEqual(mark.y, candidate.startRow)
        XCTAssertEqual(mark.height, candidate.rowCount)
    }

    func testUndoKeepBothRestoresTheCandidateWithoutChangingRows() throws {
        var assembly = try Self.seamAdjacentAssembly()
        let candidate = try XCTUnwrap(assembly.duplicateCandidates.first)
        let raw = assembly.displayedSegmentHeight(0)
        assembly.resolveDuplicateCandidate(candidate.id, choice: .keepBoth)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertEqual(assembly.displayedSegmentHeight(0), raw)
        XCTAssertTrue(assembly.duplicateRegionMarks().isEmpty)

        assembly.undoLastDuplicateCandidateChoice()
        XCTAssertNil(assembly.duplicateCandidates[0].choice)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(assembly.displayedSegmentHeight(0), raw)
        XCTAssertEqual(assembly.duplicateRegionMarks().first?.label, "重复段 1 · 待确认")
    }

    func testDuplicateMarkersUseCandidateIndexAndDropWhenResolved() throws {
        let width = 8
        let height = 40
        let image = RGBAImage(width: width, height: height, pixels: [UInt8](repeating: 200, count: width * height * 4))
        var assembly = ScrollAssembly(
            segments: [ScrollSegment(image: image, confidentSeamYs: [10, 20])],
            duplicateCandidates: [
                DuplicateSegmentCandidate(id: "a", seamNumber: 1, rowCount: 2, segmentIndex: 0, startRow: 10),
                DuplicateSegmentCandidate(id: "b", seamNumber: 2, rowCount: 3, segmentIndex: 0, startRow: 20),
            ]
        )
        let marks = assembly.duplicateRegionMarks()
        XCTAssertEqual(marks.map(\.label), ["重复段 1 · 待确认", "重复段 2 · 待确认"])
        XCTAssertEqual(marks.map(\.displayIndex), [1, 2])
        XCTAssertEqual(marks.map(\.y), [10, 20])
        XCTAssertEqual(marks.map(\.height), [2, 3])
        XCTAssertEqual(ScrollAssembly.duplicatePreviewScrollID("b"), "dup-region-b")

        assembly.resolveDuplicateCandidate("a", choice: .keepOnce)
        let remaining = assembly.duplicateRegionMarks()
        XCTAssertEqual(remaining.map(\.label), ["重复段 2 · 待确认"])
        XCTAssertEqual(remaining.map(\.y), [18])
        XCTAssertEqual(remaining.map(\.height), [3])
        XCTAssertEqual(assembly.previewStackHeight(), 38)
    }

    /// Four identical distinctive rows sit on both sides of a confident seam.
    /// 4b2745d's matchingBlock returns k=4 (available is 8, so the 9-row escape does not apply).
    /// The block continues into itself, so neither ingest nor re-detect may flag it.
    func testContinuingIdenticalRowsAcrossTheSeamAreNotCandidates() {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(Self.continuingBandFrame(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(Self.continuingBandFrame(scroll: 8)), .appended(8))
        var assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertEqual(assembly.confidentSeamCount, 1)
        XCTAssertTrue(assembly.duplicateCandidates.isEmpty)
        XCTAssertFalse(assembly.needsReview)
        XCTAssertEqual(assembly.previewPrimaryTitle, "下一步 · 美化 →")
        XCTAssertEqual(assembly.flattenedIfResolved()?.height, 40)

        assembly.completeManualAlignment()
        XCTAssertTrue(assembly.duplicateCandidates.isEmpty)
        XCTAssertFalse(assembly.needsReview)
        XCTAssertEqual(assembly.previewPrimaryTitle, "下一步 · 美化 →")
    }

    /// ABABABAB across the seam. The longest match is k=8, which tiles with period 2.
    /// Falling through to k=2 would still flag a candidate; the whole match has to be dropped.
    func testPeriodicRunAcrossTheSeamIsNotACandidate() {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(Self.alternatingRunFrame(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(Self.alternatingRunFrame(scroll: 16)), .appended(16))
        var assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertEqual(assembly.confidentSeamCount, 1)
        XCTAssertTrue(assembly.duplicateCandidates.isEmpty)
        XCTAssertEqual(assembly.flattenedIfResolved()?.height, 56)
        assembly.completeManualAlignment()
        XCTAssertTrue(assembly.duplicateCandidates.isEmpty)
    }

    func testKeepOnceDedupeOffPeakStaysUnderTwoImages() {
        let width = 1440
        let height = 800
        let headerH = 6
        let footerH = 4
        let image = fastFrame(width: width, height: height) { y in
            CoreScrollFixtures.color(slot: y)
        }
        let header = fastFrame(width: width, height: headerH) { y in
            CoreScrollFixtures.color(slot: 200 + y)
        }
        let footer = fastFrame(width: width, height: footerH) { y in
            CoreScrollFixtures.color(slot: 300 + y)
        }
        var assembly = ScrollAssembly(
            segments: [ScrollSegment(
                image: image,
                confidentSeamYs: [400],
                stickyRepeats: [StickyRepeat(seamY: 400, header: header, footer: footer)]
            )],
            dedupeStickyBars: false,
            duplicateCandidates: [
                DuplicateSegmentCandidate(id: "a", seamNumber: 1, rowCount: 8, segmentIndex: 0, startRow: 100),
                DuplicateSegmentCandidate(id: "b", seamNumber: 2, rowCount: 8, segmentIndex: 0, startRow: 520),
            ]
        )
        let ledger = AllocationLedger()
        PixelMetrics.threadLedger = ledger
        defer { PixelMetrics.threadLedger = nil }

        _ = assembly.displayedSegmentHeight(0)
        ledger.rebasePeak()
        assembly.resolveDuplicateCandidate("a", choice: .keepOnce)
        _ = assembly.displayedSegmentHeight(0)
        assembly.undoLastDuplicateCandidateChoice()
        _ = assembly.displayedSegmentHeight(0)
        assembly.resolveDuplicateCandidate("b", choice: .keepOnce)
        _ = assembly.displayedSegmentHeight(0)
        assembly.resolveDuplicateCandidate("a", choice: .keepOnce)
        _ = assembly.displayedSegmentHeight(0)

        let imageBytes = width * (height + headerH + footerH) * 4
        XCTAssertGreaterThan(assembly.presentedCacheHits, 0)
        XCTAssertLessThan(ledger.peakBytes, imageBytes * 2, "去重关闭时每个裁法都复制了一张展开图")
    }

    func testDuplicateMarkerFollowsRestoredStickyBars() throws {
        let width = 8
        let height = 40
        let image = RGBAImage(width: width, height: height, pixels: [UInt8](repeating: 200, count: width * height * 4))
        let header = RGBAImage(width: width, height: 6, pixels: [UInt8](repeating: 20, count: width * 6 * 4))
        let footer = RGBAImage(width: width, height: 4, pixels: [UInt8](repeating: 30, count: width * 4 * 4))
        var assembly = ScrollAssembly(
            segments: [ScrollSegment(
                image: image,
                confidentSeamYs: [10],
                stickyRepeats: [StickyRepeat(seamY: 10, header: header, footer: footer)]
            )],
            dedupeStickyBars: false,
            duplicateCandidates: [
                DuplicateSegmentCandidate(id: "cut", choice: .keepOnce, seamNumber: 1, rowCount: 2, segmentIndex: 0, startRow: 12),
                DuplicateSegmentCandidate(id: "mark", seamNumber: 2, rowCount: 2, segmentIndex: 0, startRow: 20),
            ]
        )
        let restored = try XCTUnwrap(assembly.duplicateRegionMarks().first { $0.id == "mark" })
        // expanded y is 20 + header 6 + footer 4, then the keep-once cut above it removes 2.
        XCTAssertEqual(restored.y, 28)
        XCTAssertEqual(restored.height, 2)

        assembly.dedupeStickyBars = true
        let deduped = try XCTUnwrap(assembly.duplicateRegionMarks().first { $0.id == "mark" })
        XCTAssertEqual(deduped.y, 18)

        assembly.resolveDuplicateCandidate("cut", choice: .keepBoth)
        assembly.dedupeStickyBars = false
        XCTAssertEqual(assembly.duplicateRegionMarks().first { $0.id == "mark" }?.y, 30)
        assembly.dedupeStickyBars = true
        XCTAssertEqual(assembly.duplicateRegionMarks().first { $0.id == "mark" }?.y, 20)
    }

    func testUnmovedSeamKeepsDuplicateChoices() throws {
        var assembly = Self.unmovedSeamAssembly(leaveOnePending: true)
        assembly.align(seam: 0, overlap: 0)
        let summary = assembly.completeManualAlignment()

        XCTAssertEqual(summary.keptChoiceCount, 2)
        XCTAssertEqual(summary.pendingCount, 1)
        XCTAssertEqual(summary.clearedChoiceCount, 0)
        XCTAssertNil(summary.clearedSeamNumber)
        XCTAssertEqual(assembly.duplicateUndoCount, 0)
        XCTAssertEqual(assembly.duplicateCandidates.map(\.choice), [.keepOnce, .keepBoth, nil])
        XCTAssertTrue(assembly.duplicateCandidates.allSatisfy { !$0.seamMoved })
        XCTAssertEqual(assembly.duplicateCandidates[0].handledLine, "✓ 已处理 · 只保留一次")
        XCTAssertEqual(assembly.duplicateCandidates[1].handledLine, "✓ 已处理 · 都保留")
        XCTAssertNil(assembly.duplicateCandidates[2].handledLine)
        XCTAssertEqual(assembly.duplicateCandidates[2].locationLine, "接缝 4 下方 · 2 行")
        XCTAssertFalse(assembly.duplicateCandidates[2].locationLine.contains("接缝动过"))
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(assembly.duplicateRegionMarks().map(\.label), ["重复段 3 · 待确认"])
        XCTAssertEqual(assembly.previewPrimaryTitle, "先确认 1 处重复段")
        XCTAssertEqual(assembly.reviewBottomBar, Self.confirmBar(1))
        XCTAssertEqual(
            StitchCopy.manualAlignmentRedetected(seam: 1, overlap: 0, kept: 2, pending: 1, clearedSeam: nil, clearedCount: 0),
            "接缝 1 已对齐（手动 +0 px） · 重复段已重新识别，保留了 2 处选择，1 处待确认"
        )

        assembly.beginStitch()
        XCTAssertTrue(assembly.duplicateCandidates.isEmpty)
        XCTAssertEqual(assembly.duplicateUndoCount, 0)
    }

    func testAllDuplicateChoicesStayWhenTheSeamDoesNotMove() {
        var assembly = Self.unmovedSeamAssembly(leaveOnePending: false)
        assembly.align(seam: 0, overlap: 0)
        let summary = assembly.completeManualAlignment()

        XCTAssertEqual(summary.keptChoiceCount, 3)
        XCTAssertEqual(summary.pendingCount, 0)
        XCTAssertEqual(summary.clearedChoiceCount, 0)
        XCTAssertEqual(assembly.duplicateUndoCount, 0)
        XCTAssertTrue(assembly.duplicateCandidates.allSatisfy { $0.choice != nil && !$0.seamMoved })
        XCTAssertTrue(assembly.duplicateRegionMarks().isEmpty)
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertNil(assembly.reviewBottomBar)
        XCTAssertEqual(assembly.previewPrimaryTitle, "下一步 · 美化 →")
        XCTAssertNotNil(assembly.flattenedIfResolved())
        XCTAssertEqual(
            StitchCopy.manualAlignmentRedetected(seam: 1, overlap: 0, kept: 3, pending: 0, clearedSeam: nil, clearedCount: 0),
            "接缝 1 已对齐（手动 +0 px） · 重复段的选择都保留了"
        )
    }

    func testMovedSeamClearsOnlyThatSeamsChoices() throws {
        var assembly = Self.movedSeamAssembly()
        assembly.align(seam: 0, overlap: 6)
        let summary = assembly.completeManualAlignment()

        XCTAssertEqual(summary.keptChoiceCount, 1)
        XCTAssertEqual(summary.pendingCount, 2)
        XCTAssertEqual(summary.clearedSeamNumber, 2)
        XCTAssertEqual(summary.clearedChoiceCount, 1)
        XCTAssertEqual(assembly.duplicateUndoCount, 0)
        XCTAssertEqual(assembly.visibleSeamNumber(boundary: 0), 2)

        let kept = try XCTUnwrap(assembly.duplicateCandidates.first { $0.segmentIndex == 0 })
        XCTAssertEqual(kept.choice, .keepOnce)
        XCTAssertFalse(kept.seamMoved)
        XCTAssertEqual(kept.handledLine, "✓ 已处理 · 只保留一次")
        XCTAssertEqual(kept.locationLine, "接缝 1 下方 · 2 行")
        XCTAssertFalse(assembly.duplicateRegionMarks().contains { $0.id == kept.id })

        let cleared = try XCTUnwrap(assembly.duplicateCandidates.first { $0.seamNumber == 3 })
        XCTAssertNil(cleared.choice)
        XCTAssertTrue(cleared.seamMoved)
        XCTAssertEqual(cleared.movedSeamNumber, 2)
        XCTAssertEqual(cleared.locationLine, "接缝 2 下方 · 2 行 · 接缝动过，需要重选")
        XCTAssertEqual(
            StitchCopy.duplicateSeamMovedNote(seam: cleared.movedSeamNumber ?? 0),
            "接缝 2 动过，这里之前的选择已清掉，需要重选。"
        )

        let untouched = try XCTUnwrap(assembly.duplicateCandidates.first { $0.seamNumber == 4 })
        XCTAssertNil(untouched.choice)
        XCTAssertFalse(untouched.seamMoved)
        XCTAssertEqual(untouched.locationLine, "接缝 4 下方 · 2 行")

        XCTAssertEqual(assembly.duplicateRegionMarks().map(\.id).sorted(), [cleared.id, untouched.id].sorted())
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 2)
        XCTAssertEqual(assembly.previewPrimaryTitle, "先确认 2 处重复段")
        XCTAssertEqual(assembly.reviewBottomBar, Self.confirmBar(2))
        XCTAssertEqual(
            StitchCopy.manualAlignmentRedetected(
                seam: 2,
                overlap: 6,
                kept: summary.keptChoiceCount,
                pending: summary.pendingCount,
                clearedSeam: summary.clearedSeamNumber,
                clearedCount: summary.clearedChoiceCount
            ),
            "接缝 2 已对齐（手动 +6 px） · 接缝 2 动过，那里的 1 处选择已清掉，需要重选"
        )

        assembly.resolveDuplicateCandidate(cleared.id, choice: .keepOnce)
        let rechosen = try XCTUnwrap(assembly.duplicateCandidates.first { $0.id == cleared.id })
        XCTAssertEqual(rechosen.choice, .keepOnce)
        XCTAssertFalse(rechosen.seamMoved)
        XCTAssertNil(rechosen.movedSeamNumber)
        XCTAssertEqual(rechosen.locationLine, "接缝 3 下方 · 2 行")
        XCTAssertFalse(assembly.duplicateRegionMarks().contains { $0.id == cleared.id })
        XCTAssertEqual(assembly.pendingDuplicateConfirmCount, 1)

        assembly.undoLastDuplicateCandidateChoice()
        let undone = try XCTUnwrap(assembly.duplicateCandidates.first { $0.id == cleared.id })
        XCTAssertNil(undone.choice)
        XCTAssertTrue(undone.seamMoved)
        XCTAssertEqual(undone.movedSeamNumber, 2)
        XCTAssertEqual(undone.locationLine, "接缝 2 下方 · 2 行 · 接缝动过，需要重选")
        XCTAssertTrue(assembly.duplicateRegionMarks().contains { $0.id == cleared.id })
    }

    /// Dragging visible seam 2 crops the segment under it. That card goes back to 待确认
    /// and names 接缝 2, the same seam as the toast. The card under seam 1 keeps its choice.
    func testDraggingSeamTwoResetsTheSegmentBelowAndKeepsTheCandidateUnderSeamOne() throws {
        var assembly = Self.movedSeamAssembly()
        XCTAssertEqual(assembly.visibleSeamNumber(boundary: 0), 2)
        assembly.align(seam: 0, overlap: 6)
        _ = assembly.completeManualAlignment()

        let underSeamOne = try XCTUnwrap(assembly.duplicateCandidates.first { $0.segmentIndex == 0 })
        XCTAssertEqual(underSeamOne.seamNumber, 1)
        XCTAssertEqual(underSeamOne.choice, .keepOnce)
        XCTAssertEqual(underSeamOne.handledLine, "✓ 已处理 · 只保留一次")
        XCTAssertFalse(underSeamOne.seamMoved)
        XCTAssertFalse(underSeamOne.locationLine.contains("接缝动过"))

        let belowSeamTwo = try XCTUnwrap(assembly.duplicateCandidates.first { $0.seamNumber == 3 })
        XCTAssertEqual(belowSeamTwo.segmentIndex, 1)
        XCTAssertNil(belowSeamTwo.choice)
        XCTAssertTrue(belowSeamTwo.seamMoved)
        XCTAssertEqual(belowSeamTwo.movedSeamNumber, 2)
        XCTAssertEqual(belowSeamTwo.locationLine, "接缝 2 下方 · 2 行 · 接缝动过，需要重选")
    }

    /// Upward scroll records the repeated rows above the seam. 「完成」 must still
    /// see the same candidate and keep the choice when that seam did not move.
    func testUpwardScrollChoiceSurvivesManualFinish() throws {
        var stitcher = ScrollStitcher()
        let lower = Self.slottedFrame(Array(8..<32))
        var upper = Array(0..<24)
        upper[6] = 8
        upper[7] = 9
        XCTAssertEqual(stitcher.ingest(lower), .seeded)
        guard case .prepended(let rows) = stitcher.ingest(Self.slottedFrame(upper)) else {
            XCTFail("scroll up should prepend")
            return
        }
        XCTAssertEqual(rows, 8)
        var assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertTrue(assembly.seams.isEmpty)
        let before = try XCTUnwrap(assembly.duplicateCandidates.first)
        XCTAssertEqual(assembly.duplicateCandidates.count, 1)
        XCTAssertEqual(before.rowCount, 2)
        assembly.resolveDuplicateCandidate(before.id, choice: .keepOnce)
        let summary = assembly.completeManualAlignment()
        let after = try XCTUnwrap(assembly.duplicateCandidates.first)
        XCTAssertEqual(assembly.duplicateCandidates.count, 1)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.startRow, before.startRow)
        XCTAssertEqual(after.choice, .keepOnce)
        XCTAssertFalse(after.seamMoved)
        XCTAssertEqual(after.handledLine, "✓ 已处理 · 只保留一次")
        XCTAssertEqual(summary.keptChoiceCount, 1)
        XCTAssertEqual(summary.clearedChoiceCount, 0)
        XCTAssertEqual(summary.pendingCount, 0)
    }

    func testRestoreAutoClearsAChoiceWhenTheSuggestionMovesTheSeam() throws {
        var assembly = Self.movedSeamAssembly()
        assembly.seams[0].suggestedOverlap = 6
        let summary = assembly.restoreAutoAlignment(seam: 0)

        XCTAssertEqual(summary.clearedSeamNumber, 2)
        XCTAssertEqual(summary.clearedChoiceCount, 1)
        XCTAssertEqual(summary.keptChoiceCount, 1)
        let kept = try XCTUnwrap(assembly.duplicateCandidates.first { $0.segmentIndex == 0 })
        XCTAssertEqual(kept.choice, .keepOnce)
        XCTAssertFalse(kept.seamMoved)
        XCTAssertEqual(kept.handledLine, "✓ 已处理 · 只保留一次")
        let cleared = try XCTUnwrap(assembly.duplicateCandidates.first { $0.seamNumber == 3 })
        XCTAssertNil(cleared.choice)
        XCTAssertTrue(cleared.seamMoved)
        XCTAssertEqual(cleared.movedSeamNumber, 2)
        XCTAssertEqual(cleared.locationLine, "接缝 2 下方 · 2 行 · 接缝动过，需要重选")
        XCTAssertEqual(assembly.duplicateUndoCount, 0)
        if case .aligned(let overlap) = assembly.seams[0].kind {
            XCTAssertEqual(overlap, 6)
        } else {
            XCTFail("还原自动 applies the suggestion")
        }
        XCTAssertEqual(
            StitchCopy.restoreAutoRedetected(
                seam: 2,
                kept: summary.keptChoiceCount,
                pending: summary.pendingCount,
                clearedSeam: summary.clearedSeamNumber,
                clearedCount: summary.clearedChoiceCount
            ),
            "接缝 2 已还原自动 · 接缝 2 动过，那里的 1 处选择已清掉，需要重选"
        )
    }

    private static func rowHits(_ image: RGBAImage, rgb: [UInt8]) -> Int {
        var hits = 0
        for y in 0..<image.height where CoreScrollFixtures.row(image, y) == rgb {
            hits += 1
        }
        return hits
    }

    private static func seamAdjacentAssembly() throws -> ScrollAssembly {
        var stitcher = ScrollStitcher()
        let first = slottedFrame(Array(0..<24))
        var secondSlots = Array(8..<32)
        secondSlots[16] = 22
        secondSlots[17] = 23
        XCTAssertEqual(stitcher.ingest(first), .seeded)
        XCTAssertEqual(stitcher.ingest(slottedFrame(secondSlots)), .appended(8))
        let assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.duplicateCandidates.count, 1)
        return assembly
    }

    private static func duplicateAfterUnalignedSeam() throws -> ScrollAssembly {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(slottedFrame(Array(0..<24))), .seeded)
        XCTAssertEqual(stitcher.ingest(slottedFrame(Array(80..<104))), .unmatched)
        var third = Array(88..<112)
        third[16] = 102
        third[17] = 103
        let outcome = stitcher.ingest(slottedFrame(third))
        guard case .appended(let rows) = outcome else {
            XCTFail("expected the second segment to join, got \(outcome)")
            return ScrollAssembly()
        }
        XCTAssertEqual(rows, 8)
        return stitcher.takeAssembly()
    }

    /// Same icon on every row, different text. Shared chrome must not become a duplicate candidate.
    private static func listFrame(scroll: Int, height: Int = 24) -> RGBAImage {
        let width = CoreScrollFixtures.width
        let icon = CoreScrollFixtures.color(slot: 1)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let text = CoreScrollFixtures.color(slot: 40 + y + scroll)
            for x in 0..<width {
                let rgb = x < 8 ? icon : text
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    /// Page rows 28..<36 are one distinctive icon-and-white row, repeated. Everything else is unique.
    private static func continuingBandFrame(scroll: Int, height: Int = 32) -> RGBAImage {
        let width = CoreScrollFixtures.width
        let icon = CoreScrollFixtures.color(slot: 7)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let page = scroll + y
            let inBand = page >= 28 && page < 36
            for x in 0..<width {
                let rgb: [UInt8]
                if inBand, x < 10 {
                    rgb = icon
                } else if inBand {
                    rgb = [255, 255, 255]
                } else {
                    rgb = CoreScrollFixtures.color(slot: page + 30)
                }
                let index = (y * width + x) * 4
                pixels[index] = rgb[0]
                pixels[index + 1] = rgb[1]
                pixels[index + 2] = rgb[2]
                pixels[index + 3] = 255
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    /// Pages 32..<48 alternate two colors. Scroll 0 then 16 puts ABABABAB on both sides of the seam,
    /// while each frame's last rows stay unique so the run is not a sticky footer.
    private static func alternatingRunFrame(scroll: Int, height: Int = 40) -> RGBAImage {
        let width = CoreScrollFixtures.width
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let page = scroll + y
            let rgb: [UInt8]
            if page >= 32, page < 48 {
                rgb = CoreScrollFixtures.color(slot: page % 2 == 0 ? 11 : 13)
            } else {
                rgb = CoreScrollFixtures.color(slot: page + 50)
            }
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = rgb[0]
                pixels[index + 1] = rgb[1]
                pixels[index + 2] = rgb[2]
                pixels[index + 3] = 255
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    /// Two-row duplicate at each seam: rows seam-2 and seam match, rows seam-1 and seam+1 match, and the pair does not tile.
    private static func plantedImage(height: Int, seams: [Int]) -> RGBAImage {
        var slots = (0..<height).map { $0 + 100 }
        for seam in seams {
            slots[seam - 2] = 20 + seam
            slots[seam] = 20 + seam
            slots[seam - 1] = 21 + seam
            slots[seam + 1] = 21 + seam
        }
        return slottedFrame(slots)
    }

    private static func seededCandidate(
        segment: Int,
        seam: Int,
        start: Int,
        choice: DuplicateSegmentChoice?,
        offset: Int
    ) -> DuplicateSegmentCandidate {
        DuplicateSegmentCandidate(
            id: "seed-\(segment)-\(seam)",
            choice: choice,
            seamNumber: seam,
            rowCount: 2,
            segmentIndex: segment,
            startRow: start,
            offset: offset
        )
    }

    /// Segment 0 has no confident seam, so the boundary is 接缝 1. Segment 1 holds three duplicates.
    private static func unmovedSeamAssembly(leaveOnePending: Bool) -> ScrollAssembly {
        let lowerSeams = [8, 16, 24]
        let choices: [DuplicateSegmentChoice?] = leaveOnePending
            ? [.keepOnce, .keepBoth, nil]
            : [.keepOnce, .keepBoth, .keepOnce]
        let candidates = lowerSeams.enumerated().map { offset, seamY in
            seededCandidate(segment: 1, seam: offset + 2, start: seamY, choice: choices[offset], offset: 0)
        }
        return ScrollAssembly(
            segments: [
                ScrollSegment(image: plantedImage(height: 12, seams: []), confidentSeamYs: []),
                ScrollSegment(image: plantedImage(height: 40, seams: lowerSeams), confidentSeamYs: lowerSeams),
            ],
            seams: [ScrollSeam(kind: .needsAlignment, suggestedOverlap: 0)],
            duplicateCandidates: candidates
        )
    }

    /// Segment 0's duplicate is 接缝 1. The boundary under it is 接缝 2. Segment 1 holds two more.
    private static func movedSeamAssembly() -> ScrollAssembly {
        let upperSeams = [8]
        let lowerSeams = [8, 16]
        return ScrollAssembly(
            segments: [
                ScrollSegment(image: plantedImage(height: 20, seams: upperSeams), confidentSeamYs: upperSeams),
                ScrollSegment(image: plantedImage(height: 32, seams: lowerSeams), confidentSeamYs: lowerSeams),
            ],
            seams: [ScrollSeam(kind: .needsAlignment, suggestedOverlap: 0)],
            duplicateCandidates: [
                seededCandidate(segment: 0, seam: 1, start: 8, choice: .keepOnce, offset: 0),
                seededCandidate(segment: 1, seam: 3, start: 8, choice: .keepBoth, offset: 0),
                seededCandidate(segment: 1, seam: 4, start: 16, choice: nil, offset: 0),
            ]
        )
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

    /// Same period as `aliasPeriod(scroll: 42)`, with the bottom rows nudged so the reverse
    /// candidate scores a little worse than +30 without leaving the rival threshold.
    static func aliasPeriodNearMiss(scroll: Int = 42, height: Int = 90, period: Int = 60) -> RGBAImage {
        let image = aliasPeriod(scroll: scroll, height: height, period: period)
        var pixels = image.pixels
        for y in 60..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let red = Int(pixels[i])
                pixels[i] = UInt8(red >= 12 ? red - 12 : red + 12)
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
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

// MARK: - Round 6 must-fixes (C, E, F)

extension ScrollStitchTests {
    private static let tieReason = "找到 2 个都说得通的位移，自动对齐没法确定是哪一个——为了不拼错，先停下来请你确认。"
    private static let listRowPrefix = "这一段是重复的列表行（行高 22 px）。"

    // C: a rival in the same direction as the best shift also opens the tie.

    /// +12, then a frame that +30 and +50 both explain. Neither is close to +12, both point down.
    func testSameDirectionRivalOpensATie() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.palePage(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.palePage(scroll: 12)), .appended(12))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.paleSameDirectionTie()), .unmatched)
        let assembly = stitcher.takeAssembly()
        let card = try XCTUnwrap(assembly.seams.last).card(number: 1)
        XCTAssertEqual(card.label, "待确认")
        XCTAssertEqual(card.chrome, .amberDashed)
        XCTAssertEqual(card.title, "接缝 1 · 待确认：位移无法唯一确定")
        XCTAssertEqual(card.reason, Self.tieReason)
        XCTAssertEqual(card.candidates.count, 2)
        XCTAssertTrue(card.candidates.allSatisfy { $0.contains("+") }, "\(card.candidates)")
        XCTAssertFalse(card.candidates.contains { $0.contains("−") }, "\(card.candidates)")
        XCTAssertEqual(card.candidates.filter { $0.hasSuffix(" · 当前") }.count, 1)
        XCTAssertEqual(assembly.unalignedSeamCount, 1)
    }

    // C: repeated 22 px list rows put the list-row sentence in front of the tie reason.

    func testRepeatedListRowsPrefixTheTieReason() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.withFixedListRows(CoreScrollFixtures.aliasPeriod(scroll: 0))), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.withFixedListRows(CoreScrollFixtures.aliasPeriod(scroll: 12))), .appended(12))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.withFixedListRows(CoreScrollFixtures.aliasPeriod(scroll: 42))), .unmatched)
        let assembly = stitcher.takeAssembly()
        let card = try XCTUnwrap(assembly.seams.last).card(number: 1)
        XCTAssertEqual(card.label, "待确认")
        XCTAssertEqual(card.chrome, .amberDashed)
        XCTAssertEqual(card.title, "接缝 1 · 待确认：位移无法唯一确定")
        XCTAssertTrue(card.reason?.hasPrefix(Self.listRowPrefix) == true, card.reason ?? "nil")
        XCTAssertEqual(card.reason, Self.listRowPrefix + Self.tieReason)
        XCTAssertEqual(card.candidates.count, 2)
    }

    // E: tie candidates keep their sign, and aligning on a shift uses that sign.

    func testTieSeamKeepsSignedCandidateShifts() throws {
        let assembly = try openShiftTie()
        let seam = try XCTUnwrap(assembly.seams.first)
        XCTAssertEqual(seam.candidateLines, ["位移 A · +32 px · 当前", "位移 B · −28 px"])
        XCTAssertEqual(seam.candidateShifts, [32, -28])
    }

    /// −28 puts the new frame 28 rows above the last one (top 12 → −16): 16 new rows go on top,
    /// the rest repeats segment 0. Nothing is appended below. The old overlap 62 appended 28 rows.
    func testAligningTheReverseTieCandidatePutsItsRowsAboveTheSegment() throws {
        var assembly = try openShiftTie()
        let upper = try XCTUnwrap(assembly.segments.first).image
        XCTAssertEqual(upper.height, 102)
        assembly.align(seam: 0, shift: -28)
        XCTAssertEqual(assembly.unalignedSeamCount, 0)
        let image = try XCTUnwrap(assembly.flattenedIfResolved())
        XCTAssertEqual(image.height, 118)
        XCTAssertEqual(assembly.stackedHeight(deduping: true), 118)
        guard image.height == 118 else { return }
        let source = CoreScrollFixtures.aliasPeriod(scroll: 90)
        for y in 0..<16 {
            XCTAssertEqual(CoreScrollFixtures.row(image, y), CoreScrollFixtures.row(source, y), "prepended row \(y)")
        }
        for y in 0..<upper.height {
            XCTAssertEqual(CoreScrollFixtures.row(image, 16 + y), CoreScrollFixtures.row(upper, y), "segment 0 row \(y)")
        }
        let card = assembly.seams[0].card(number: 1)
        XCTAssertEqual(card.label, "✓ 手动对齐")
        XCTAssertEqual(card.chrome, .plain)
        let preview = try XCTUnwrap(assembly.renderPreview())
        XCTAssertEqual(preview.image.height, 118)
    }

    /// Guards existing behaviour: +32 is still overlap 58, the same image as 按此对齐 on the suggestion.
    func testAligningTheSelectedTieShiftMatchesTheSuggestedOverlap() throws {
        var byShift = try openShiftTie()
        var byOverlap = try openShiftTie()
        let suggested = try XCTUnwrap(byOverlap.seams[0].suggestedOverlap)
        XCTAssertEqual(suggested, 58)
        byShift.align(seam: 0, shift: 32)
        byOverlap.align(seam: 0, overlap: suggested)
        let shifted = try XCTUnwrap(byShift.flattenedIfResolved())
        let overlapped = try XCTUnwrap(byOverlap.flattenedIfResolved())
        XCTAssertEqual(shifted.height, 134)
        XCTAssertEqual(shifted, overlapped)
        XCTAssertEqual(byShift.seams[0].card(number: 1).label, "✓ 已确认")
    }

    /// +30 and −30 both give overlap 60. Picking −30 is not the auto-selected shift.
    func testAligningTheOppositeShiftOfAnEvenTieIsManual() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 12)), .appended(12))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.aliasPeriod(scroll: 42)), .unmatched)
        let opened = stitcher.takeAssembly()
        XCTAssertEqual(opened.seams.first?.candidateShifts, [30, -30])
        var opposite = opened
        opposite.align(seam: 0, shift: -30)
        XCTAssertEqual(opposite.seams[0].card(number: 1).label, "✓ 手动对齐")
        var selected = opened
        selected.align(seam: 0, shift: 30)
        XCTAssertEqual(selected.seams[0].card(number: 1).label, "✓ 已确认")
    }

    // F: once a confirmation seam is handled, the tie or reverse reason is gone from the card and the mark.

    func testConfirmedTieSeamDropsTheTieReason() throws {
        var assembly = try openShiftTie()
        let suggested = try XCTUnwrap(assembly.seams[0].suggestedOverlap)
        assembly.align(seam: 0, overlap: suggested)
        try assertHandledSeamShowsNoReason(assembly)
    }

    func testManualTieSeamDropsTheTieReason() throws {
        var assembly = try openShiftTie()
        let suggested = try XCTUnwrap(assembly.seams[0].suggestedOverlap)
        assembly.align(seam: 0, overlap: suggested + 4)
        try assertHandledSeamShowsNoReason(assembly)
    }

    func testDirectTieSeamDropsTheTieReason() throws {
        var assembly = try openShiftTie()
        assembly.joinAsIs(seam: 0)
        try assertHandledSeamShowsNoReason(assembly)
    }

    func testAlignedReverseSeamDropsTheReverseLine() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 0, height: 48, slot: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.page(scroll: 12, height: 48, slot: 0)), .appended(12))
        XCTAssertEqual(stitcher.ingest(CoreScrollFixtures.falseReverse()), .unmatched)
        var assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.seams.first?.note, StitchCopy.reverseSeam)
        let suggested = try XCTUnwrap(assembly.seams[0].suggestedOverlap)
        assembly.align(seam: 0, overlap: suggested)
        try assertHandledSeamShowsNoReason(assembly)
    }

    /// Guards existing behaviour: the pending tie still shows its reason on the card and the mark.
    func testPendingTieSeamKeepsTheTieReasonOnTheMark() throws {
        let assembly = try openShiftTie()
        let card = assembly.seams[0].card(number: 1)
        XCTAssertEqual(card.reason, Self.tieReason)
        let preview = try XCTUnwrap(assembly.renderPreview())
        let mark = try XCTUnwrap(preview.marks.first { $0.boundaryIndex == 0 })
        XCTAssertEqual(mark.note, Self.tieReason)
    }

    private func assertHandledSeamShowsNoReason(
        _ assembly: ScrollAssembly,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let card = assembly.seams[0].card(number: 1)
        XCTAssertEqual(card.chrome, .plain, file: file, line: line)
        XCTAssertNil(card.reason, file: file, line: line)
        let preview = try XCTUnwrap(assembly.renderPreview(), file: file, line: line)
        let mark = try XCTUnwrap(preview.marks.first { $0.boundaryIndex == 0 }, file: file, line: line)
        XCTAssertNil(mark.note, file: file, line: line)
    }
}

extension CoreScrollFixtures {
    /// Pale rows: channels in 195...255 (step 10), at least 20 apart inside a row so every row is distinctive.
    /// Two different rows stay close, so a frame that is half right for a shift still scores inside the align distance.
    static let paleLevels: [UInt8] = [195, 205, 215, 225, 235, 245, 255]
    static let palePalette: [[UInt8]] = (0..<343).compactMap { index -> [UInt8]? in
        let rgb = [paleLevels[index % 7], paleLevels[(index / 7) % 7], paleLevels[index / 49]]
        let span = Int(rgb.max() ?? 0) - Int(rgb.min() ?? 0)
        return span >= 20 ? rgb : nil
    }

    /// Page row `page` of the pale page. 17 is coprime with the palette size, so rows never repeat.
    static func paleColor(_ page: Int) -> [UInt8] {
        palePalette[(page * 17) % palePalette.count]
    }

    static func palePage(scroll: Int, height: Int = 90) -> RGBAImage {
        solidRows((0..<height).map { paleColor(scroll + $0) })
    }

    /// After `palePage(scroll: 12)`: rows 0..<24 continue the page 30 rows on, rows 24..<50
    /// continue it 50 rows on, and the rest is new. +30 and +50 both explain the frame.
    static func paleSameDirectionTie(last: Int = 12, height: Int = 90) -> RGBAImage {
        solidRows((0..<height).map { y -> [UInt8] in
            if y < 24 { return paleColor(last + 30 + y) }
            if y < 50 { return paleColor(last + 50 + y) }
            return paleColor(200 + y)
        })
    }

    /// A fixed list panel under the moving rows: 132 rows that repeat every 22 px, byte for byte.
    static func withFixedListRows(_ image: RGBAImage, rows: Int = 132) -> RGBAImage {
        var colors: [[UInt8]] = []
        for y in 0..<image.height {
            colors.append(row(image, y))
        }
        for y in 0..<rows {
            colors.append(listRowPalette[y % 22])
        }
        return solidRows(colors)
    }

    /// Channels halfway between the stitch palette levels, so no list row is near a page row.
    static let listRowPalette: [[UInt8]] = {
        let mids: [UInt8] = [32, 96, 160, 224]
        var colors: [[UInt8]] = []
        for index in 0..<64 {
            let rgb = [mids[index % 4], mids[(index / 4) % 4], mids[index / 16]]
            if Int(rgb.max() ?? 0) - Int(rgb.min() ?? 0) >= 18 {
                colors.append(rgb)
            }
        }
        return colors
    }()

    static func solidRows(_ colors: [[UInt8]]) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * colors.count * 4)
        for (y, rgb) in colors.enumerated() {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
                pixels[i + 3] = 255
            }
        }
        return RGBAImage(width: width, height: colors.count, pixels: pixels)
    }
}
