import CoreGraphics
import Foundation
import PrettyShotCore
import XCTest
@testable import PrettyShot

final class ScrollStitcherTests: XCTestCase {
    func testStickyHeaderAndFooterAreKeptOnce() throws {
        let first = ScrollFixtures.viewport(scroll: 0)
        let mid = ScrollFixtures.viewport(scroll: 15)
        let last = ScrollFixtures.viewport(scroll: 30)

        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(first), .seeded)
        XCTAssertEqual(stitcher.ingest(mid), .appended(15))
        XCTAssertEqual(stitcher.ingest(last), .appended(15))

        let assembly = stitcher.takeAssembly()
        XCTAssertFalse(assembly.needsReview)
        XCTAssertFalse(assembly.opensStitchReview)
        XCTAssertTrue(assembly.hasStickyRepeats)
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

    func testSmallStepGrowsAndDuplicatesDoNot() throws {
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

    func testUnconfidentSeamIsNotFlattenedUntilTheUserDecides() throws {
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

    func testSeveralUnmatchedFramesStaySeparate() throws {
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

    func testHeightCapClipsAConfidentJoinAndStops() throws {
        var options = ScrollStitcher.Options()
        options.maxHeight = 50
        var stitcher = ScrollStitcher(options: options)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 20)), .reachedLimit)
        let image = try XCTUnwrap(stitcher.takeAssembly().flattenedIfResolved())
        XCTAssertEqual(image.height, 50)
    }

    func testPixelBudgetRefusesAnotherFullViewport() throws {
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

    func testRemainingRowsHonorsHeightAndPixelCaps() throws {
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

    func testCGImageRoundTripKeepsTopRowAtTheTop() throws {
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
        XCTAssertEqual(ScrollFixtures.row(back, 0), [255, 0, 0])
        XCTAssertEqual(ScrollFixtures.row(back, height - 1), [0, 0, 255])
    }

    func testSourceRectFlipsCocoaSelection() throws {
        let screen = CGSize(width: 1440, height: 900)
        let selection = CGRect(x: 100, y: 650, width: 300, height: 200)
        let source = ScrollingCaptureGeometry.sourceRect(selection: selection, screenSize: screen)
        XCTAssertEqual(source, CGRect(x: 100, y: 50, width: 300, height: 200))
    }

    func testAutoScrollShipsDisabled() throws {
        XCTAssertFalse(ScrollingCaptureFeature.autoScrollEnabled)
    }

    func testRepeatedRowsAreNotConfident() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.periodic(scroll: 0)), .seeded)
        let outcome = stitcher.ingest(ScrollFixtures.periodic(scroll: 25))
        XCTAssertEqual(outcome, .unmatched)
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.needsReview)
        XCTAssertNil(assembly.flattenedIfResolved())
        XCTAssertEqual(assembly.seams.first?.kind, .needsAlignment)

        var resolved = assembly
        resolved.align(seam: 0, overlap: 25)
        XCTAssertFalse(resolved.needsReview)
        XCTAssertNotNil(resolved.flattenedIfResolved())
        resolved.align(seam: 0, overlap: 10)
        XCTAssertEqual(resolved.flattenedIfResolved()?.height, 180 + 180 - 10)
        resolved.restoreAutoAlignment(seam: 0)
        let suggested = resolved.seams[0].suggestedOverlap ?? 0
        if case .aligned(let overlap) = resolved.seams[0].kind {
            XCTAssertEqual(overlap, suggested)
        } else {
            XCTFail("restore auto alignment should leave the seam aligned")
        }
    }

    func testSlowScrollKeepsRowsThatLookedUnchanged() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.gradient(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.gradient(scroll: 1)), .unchanged)
        XCTAssertEqual(stitcher.pixelHeight, 12)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.gradient(scroll: 2)), .appended(2))
        let image = try XCTUnwrap(stitcher.takeAssembly().flattenedIfResolved())
        XCTAssertEqual(image.height, 14)
        XCTAssertEqual(ScrollFixtures.row(image, 0), ScrollFixtures.gradientColor(scroll: 0, y: 0))
        XCTAssertEqual(ScrollFixtures.row(image, 13), ScrollFixtures.gradientColor(scroll: 2, y: 11))
    }

    func testUpwardScrollPrepends() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 20)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0)), .prepended(20))
        let assembly = stitcher.takeAssembly()
        XCTAssertFalse(assembly.needsReview)
        let image = try XCTUnwrap(assembly.flattenedIfResolved())
        XCTAssertEqual(image.height, 60)
        XCTAssertEqual(ScrollFixtures.row(image, 0), ScrollFixtures.color(slot: ScrollFixtures.contentSlot))
        XCTAssertEqual(ScrollFixtures.row(image, 59), ScrollFixtures.color(slot: ScrollFixtures.contentSlot + 59))
    }

    func testSmallCaptureNoiseStillStitchesTheTrueShift() throws {
        var stitcher = ScrollStitcher()
        let first = ScrollFixtures.page(scroll: 0)
        let second = ScrollFixtures.noised(ScrollFixtures.page(scroll: 8), amplitude: 2)
        XCTAssertEqual(stitcher.ingest(first), .seeded)
        XCTAssertEqual(stitcher.ingest(second), .appended(8))
        let assembly = stitcher.takeAssembly()
        XCTAssertFalse(assembly.needsReview)
        XCTAssertEqual(assembly.flattenedIfResolved()?.height, 48)
    }

    /// Shared card chrome used to invent extra shifts. Unique card bodies should still join.
    func testRepeatingCardChromeDoesNotSplitTheRun() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.cards(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.cards(scroll: 18)), .appended(18))
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.cards(scroll: 36)), .appended(18))
        let assembly = stitcher.takeAssembly()
        XCTAssertFalse(assembly.needsReview)
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertEqual(assembly.flattenedIfResolved()?.height, 160 + 36)
    }

    /// Repeating card chrome used to invent a second shift once the scroll passed one card.
    func testRepeatingCardChromeWithCompetingCandidatesStitchesTrueShift() throws {
        let shift = 28
        let first = ScrollFixtures.competingCards(scroll: 0)
        let second = ScrollFixtures.competingCards(scroll: shift)
        try assertStitchedRows(first, second, shift: shift)
    }

    /// Adjacent rows that look alike used to report 10 px and 11 px as two equally good joins.
    func testNeighboringShiftCandidatesClusterIntoOneJoin() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.softStep(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.softStep(scroll: 10)), .appended(10))
        XCTAssertFalse(stitcher.takeAssembly().needsReview)
    }

    /// Neighbors 10 px and 11 px used to be two joins. They are one scroll.
    func testNeighboringRowsWithReplacedFirstRowClusterIntoOneJoin() throws {
        let first = ScrollFixtures.neighboringRows(scroll: 0)
        let second = ScrollFixtures.neighboringRows(scroll: 10, replaceFirstRowWithPage: 11)
        try assertStitchedRows(first, second, shift: 10)
    }

    func testOneFrameFlickerDoesNotOpenASeam() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.flashed(ScrollFixtures.page(scroll: 0), rows: 8)), .ignored)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 6)), .appended(6))
        let assembly = stitcher.takeAssembly()
        XCTAssertFalse(assembly.needsReview)
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertEqual(assembly.flattenedIfResolved()?.height, 46)
    }

    /// A 1 px scroll inside a mostly blank viewport must open a seam, not be dropped.
    func testOnePixelShiftInBlankFrameOpensSeam() throws {
        try assertBlankOpensASeam(
            ScrollFixtures.sparseViewport(scroll: 0, height: 60, contentRows: 10),
            ScrollFixtures.sparseViewport(scroll: 1, height: 60, contentRows: 10)
        )
    }

    /// A 3 px scroll in the same kind of frame opens a seam instead of being ignored.
    func testThreePixelShiftInBlankFrameOpensSeam() throws {
        try assertBlankOpensASeam(
            ScrollFixtures.sparseViewport(scroll: 0, height: 80, contentRows: 16),
            ScrollFixtures.sparseViewport(scroll: 3, height: 80, contentRows: 16)
        )
    }

    /// A mid-size scroll across blank space opens a seam instead of being ignored.
    func testMidSizeShiftInBlankFrameOpensSeam() throws {
        try assertBlankOpensASeam(
            ScrollFixtures.sparseViewport(scroll: 0, height: 80, contentRows: 20),
            ScrollFixtures.sparseViewport(scroll: 10, height: 80, contentRows: 20)
        )
    }

    /// A 2 px scroll under a fixed bar taller than the sticky cap must not be swallowed.
    func testTwoPixelShiftBehindFixedBarStitches() throws {
        try assertDownwardJoin(
            ScrollFixtures.fixedBarViewport(scroll: 0, height: 80, barRows: 60),
            ScrollFixtures.fixedBarViewport(scroll: 2, height: 80, barRows: 60),
            shift: 2
        )
    }

    /// A mid-size scroll under that same bar must append, not come back as flicker.
    func testMidSizeShiftBehindFixedBarStitches() throws {
        try assertDownwardJoin(
            ScrollFixtures.fixedBarViewport(scroll: 0, height: 80, barRows: 60),
            ScrollFixtures.fixedBarViewport(scroll: 12, height: 80, barRows: 60),
            shift: 12
        )
    }

    /// After a segment break the previous direction must not pick an alias on the next run.
    func testSegmentBreakDoesNotReuseStaleAlias() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, height: 90, slot: 25)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 12, height: 90, slot: 25)), .appended(12))
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 12)), .unmatched)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 42)), .unmatched)
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.needsReview)
        XCTAssertNil(assembly.flattenedIfResolved())
    }

    /// Finalizing the assembly ends the alias memory. The next capture must not reuse it.
    func testFinalizeDropsStaleAlias() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 12)), .appended(12))
        _ = stitcher.takeAssembly()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 12)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 42)), .unmatched)
    }

    /// `beginStitch()` is its own reset. A later reverse alias must stay a seam.
    func testBeginStitchDropsStaleAlias() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 12)), .appended(12))
        stitcher.beginStitch()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 42)), .unmatched)
    }

    /// Two-row solid bands on white. An off-by-one join used to score as well as the true shift.
    func testTwoRowBandsOnWhiteAppendTheTrueShift() throws {
        let shift = 12
        let first = ScrollFixtures.colorBands(scroll: 0)
        let second = ScrollFixtures.colorBands(scroll: shift)
        try assertStitchedRows(first, second, shift: shift)
    }

    /// Same segment, forward alias, then a real reverse. The reverse must not be appended.
    func testReverseScrollInTheSameSegmentIsNotAppended() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 106)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 118)), .appended(12))
        let outcome = stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 90))
        XCTAssertEqual(outcome, .unmatched)
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.needsReview)
        XCTAssertNil(assembly.flattenedIfResolved())
        let tie = "找到 2 个得分相同的位移，自动对齐没法确定是哪一个——为了不拼错，先停下来请你确认。"
        let card = try XCTUnwrap(assembly.seams.last).card(number: 1)
        XCTAssertEqual(card.title, "接缝 1 · 待确认：位移无法唯一确定")
        XCTAssertEqual(card.reason, tie)
        XCTAssertNotEqual(card.reason, StitchCopy.reverseSeam)
        XCTAssertFalse(card.reason?.contains("这一段是重复的列表行") == true)
        XCTAssertEqual(card.candidates, ["位移 A · +32 px · 当前", "位移 B · −28 px"])
    }

    /// A jump much larger than the previous shift stays a seam, even inside one segment.
    /// +30 and −30 score the same, so the reason is the tie, not a reverse scroll.
    func testAliasJumpFarFromLastShiftOpensASeam() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 12)), .appended(12))
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 42)), .unmatched)
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.needsReview)
        let tie = "找到 2 个得分相同的位移，自动对齐没法确定是哪一个——为了不拼错，先停下来请你确认。"
        let card = try XCTUnwrap(assembly.seams.last).card(number: 1)
        XCTAssertEqual(card.title, "接缝 1 · 待确认：位移无法唯一确定")
        XCTAssertEqual(card.reason, tie)
        XCTAssertNotEqual(card.reason, StitchCopy.reverseSeam)
        XCTAssertFalse(card.reason?.contains("这一段是重复的列表行") == true)
        XCTAssertEqual(card.candidates, ["位移 A · +30 px · 当前", "位移 B · −30 px"])
    }

    /// One reverse candidate, and it copies rows already on the page. That opens a seam.
    func testReverseSingleCandidateFalseMatchOpensSeam() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, height: 48, slot: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 12, height: 48, slot: 0)), .appended(12))
        let outcome = stitcher.ingest(ScrollFixtures.falseReverse())
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
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 106)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 118)), .appended(12))
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.aliasPeriod(scroll: 90)), .unmatched)
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
            ScrollFixtures.row(image, image.height - 1),
            ScrollFixtures.row(second, second.height - 1),
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
            XCTAssertEqual(ScrollFixtures.row(image, y), ScrollFixtures.row(first, y), "kept row \(y)", file: file, line: line)
        }
        let stripStart = second.height - shift
        for offset in 0..<shift {
            XCTAssertEqual(
                ScrollFixtures.row(image, first.height + offset),
                ScrollFixtures.row(second, stripStart + offset),
                "new row \(offset)",
                file: file,
                line: line
            )
        }
    }

    func testStickyDedupeCanBeRestored() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 15)), .appended(15))
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 30)), .appended(15))
        var assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.hasStickyRepeats)
        XCTAssertFalse(assembly.opensStitchReview)
        let deduped = try XCTUnwrap(assembly.flattenedIfResolved())
        XCTAssertEqual(deduped.height, 90)
        XCTAssertEqual(ScrollFixtures.row(deduped, 0), ScrollFixtures.color(slot: 0))

        assembly.dedupeStickyBars = false
        let restored = try XCTUnwrap(assembly.flattenedIfResolved())
        XCTAssertEqual(restored.height, 90 + 2 * (ScrollFixtures.header + ScrollFixtures.footer))
        XCTAssertFalse(assembly.needsReview)
        let firstSeam = 52
        XCTAssertEqual(ScrollFixtures.row(restored, firstSeam), ScrollFixtures.color(slot: 100))
        XCTAssertEqual(ScrollFixtures.row(restored, firstSeam + ScrollFixtures.footer), ScrollFixtures.color(slot: 0))

        assembly.dedupeStickyBars = true
        let again = try XCTUnwrap(assembly.flattenedIfResolved())
        XCTAssertEqual(again.height, 90)
        XCTAssertEqual(again.pixels, deduped.pixels)
    }

    func testLowConfidenceStickyDedupeNeedsConfirmation() throws {
        var stitcher = ScrollStitcher()
        let first = ScrollFixtures.softHeaderViewport(scroll: 0)
        let second = ScrollFixtures.softHeaderViewport(scroll: 12)
        XCTAssertEqual(stitcher.ingest(first), .seeded)
        XCTAssertEqual(stitcher.ingest(second), .appended(12))

        var assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertTrue(assembly.seams.isEmpty)
        XCTAssertEqual(assembly.pendingSticky?.seamCount, 1)
        XCTAssertEqual(assembly.pendingSticky?.prompt, "待确认 · 顶部这条可能是固定栏（涉及 1 处接缝）")
        XCTAssertTrue(assembly.needsReview)
        XCTAssertTrue(assembly.opensStitchReview)
        XCTAssertNil(assembly.flattenedIfResolved())

        assembly.confirmStickyBars(keepOnce: true)
        XCTAssertFalse(assembly.needsReview)
        XCTAssertNotNil(assembly.flattenedIfResolved())
    }

    func testUncertainStickyBandAcrossManyFramesIsOneConfirmation() throws {
        var stitcher = ScrollStitcher()
        let frameCount = 8
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.softHeaderViewport(scroll: 0)), .seeded)
        for index in 1..<frameCount {
            let outcome = stitcher.ingest(ScrollFixtures.softHeaderViewport(scroll: index * 12))
            guard case .appended = outcome else {
                XCTFail("frame \(index) should join the same run, got \(outcome)")
                return
            }
        }
        let assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.segments.count, 1)
        XCTAssertTrue(assembly.seams.isEmpty)
        XCTAssertEqual(assembly.pendingSticky?.seamCount, frameCount - 1)
        XCTAssertEqual(assembly.pendingSticky?.prompt, "待确认 · 顶部这条可能是固定栏（涉及 \(frameCount - 1) 处接缝）")
        XCTAssertEqual(assembly.unresolvedItemCount, 1)
        XCTAssertEqual(
            assembly.reviewBottomBar,
            "⚠ 还有 1 处没处理（固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertTrue(assembly.needsReview)
        XCTAssertNil(assembly.flattenedIfResolved())

        var keepOnce = assembly
        keepOnce.confirmStickyBars(keepOnce: true)
        XCTAssertFalse(keepOnce.needsReview)
        XCTAssertEqual(keepOnce.flattenedIfResolved()?.height, 48 + 12 * (frameCount - 1))

        var keepAll = assembly
        keepAll.confirmStickyBars(keepOnce: false)
        XCTAssertFalse(keepAll.needsReview)
        XCTAssertGreaterThan(keepAll.flattenedIfResolved()?.height ?? 0, keepOnce.flattenedIfResolved()?.height ?? 0)
    }

    func testRestoreOverLimitPromptsInsteadOfTruncating() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 15)), .appended(15))
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 30)), .appended(15))
        var assembly = stitcher.takeAssembly()
        let deduped = try XCTUnwrap(assembly.flattenedIfResolved())
        let restoredHeight = 90 + 2 * (ScrollFixtures.header + ScrollFixtures.footer)

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

        let chunks = assembly.exportWithinLimits(dedupeStickyBars: false, maxHeight: 40, maxPixels: 24_000_000)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.height }, restoredHeight)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.height, 40)
            XCTAssertLessThanOrEqual(chunk.width * chunk.height, 24_000_000)
        }
    }

    func testPresentedCacheHitsOnRepeatedPreview() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 15)), .appended(15))
        var assembly = stitcher.takeAssembly()
        XCTAssertNotNil(assembly.renderPreview())
        let afterFirst = assembly.presentedCacheHits
        XCTAssertNotNil(assembly.renderPreview())
        XCTAssertGreaterThan(assembly.presentedCacheHits, afterFirst)
    }

    @MainActor
    func testAssemblyPersistsAndRestoresFromHistory() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 15)), .appended(15))
        let assembly = stitcher.takeAssembly()
        let deduped = try XCTUnwrap(assembly.flattenedIfResolved())
        let image = try XCTUnwrap(deduped.cgImage())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PrettyShotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(directory: directory, limit: 10)
        let item = try store.add(image: image, scale: 2, mode: .scrolling)
        XCTAssertEqual(item.modeLabel, "长图 · \(image.height) px")
        try store.saveStitch(assembly, for: item)
        XCTAssertTrue(store.items[0].hasStickyRestore)

        let reloaded = HistoryStore(directory: directory, limit: 10)
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertTrue(reloaded.items[0].hasStickyRestore)
        let loaded = try XCTUnwrap(reloaded.loadStitch(for: reloaded.items[0]))
        let loadedImage = try XCTUnwrap(loaded.flattenedIfResolved())
        XCTAssertEqual(loadedImage.height, deduped.height)
        XCTAssertEqual(ScrollFixtures.row(loadedImage, 0), ScrollFixtures.row(deduped, 0))
        XCTAssertEqual(ScrollFixtures.row(loadedImage, loadedImage.height - 1), ScrollFixtures.row(deduped, deduped.height - 1))

        var restored = loaded
        guard case .restored(let height) = restored.restoreStickyBars() else {
            XCTFail("restored image fits in one capture")
            return
        }
        let tall = try XCTUnwrap(restored.flattenedIfResolved())
        XCTAssertEqual(tall.height, height)
        XCTAssertGreaterThan(tall.height, deduped.height)
        try reloaded.replaceImage(of: reloaded.items[0].id, with: try XCTUnwrap(tall.cgImage()))
        try reloaded.saveStitch(restored, for: reloaded.items[0])

        let again = HistoryStore(directory: directory, limit: 10)
        XCTAssertFalse(again.items[0].hasStickyRestore)
        XCTAssertEqual(again.image(for: again.items[0])?.height, tall.height)
        let roundTrip = try XCTUnwrap(again.loadStitch(for: again.items[0]))
        XCTAssertFalse(roundTrip.dedupeStickyBars)
        XCTAssertEqual(roundTrip.flattenedIfResolved()?.height, tall.height)
    }

    func testExportWithinLimitsRefusesToSpanUnalignedSeams() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, slot: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, slot: 40)), .unmatched)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, slot: 80)), .unmatched)
        var assembly = stitcher.takeAssembly()
        assembly.align(seam: 0, overlap: 0)
        XCTAssertEqual(assembly.unalignedSeamCount, 1)

        let refused = assembly.exportWithinLimits(dedupeStickyBars: true, maxHeight: 10, maxPixels: 24_000_000)
        XCTAssertTrue(refused.isEmpty)

        assembly.joinAsIs(seam: 1)
        let chunks = assembly.exportWithinLimits(dedupeStickyBars: true, maxHeight: 25, maxPixels: 24_000_000)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.height }, 120)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.height, 25)
            XCTAssertLessThanOrEqual(chunk.width * chunk.height, 24_000_000)
        }
    }

    @MainActor
    func testOverLimitPromptBlocksExportUntilSeamsAreAligned() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, slot: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, slot: 40)), .unmatched)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, slot: 80)), .unmatched)
        let assembly = stitcher.takeAssembly()
        let model = StitchPreviewModel(assembly: assembly, notice: nil)

        let blocked = model.assembly.restoreExportPrompt
        XCTAssertEqual(blocked.unalignedCount, 2)
        XCTAssertEqual(blocked.primaryTitle, "先处理 2 处待对齐")
        XCTAssertFalse(blocked.primaryExports)
        XCTAssertFalse(blocked.segmentExportEnabled)
        XCTAssertEqual(blocked.segmentExportCaption, "还有 2 处待对齐，先处理再导出")
        XCTAssertEqual(StitchCopy.keepDedupe, "保持去重")
        XCTAssertEqual(StitchCopy.overlayDedupedChip, "已去掉重复固定栏 · 还原固定栏")

        model.select(boundary: 0)
        model.assembly.align(seam: 0, overlap: 0)
        model.focusFirstUnalignedSeam()
        XCTAssertEqual(model.selectedBoundary, 1)
        let oneLeft = model.assembly.restoreExportPrompt
        XCTAssertEqual(oneLeft.unalignedCount, 1)
        XCTAssertEqual(oneLeft.primaryTitle, "先处理 1 处待对齐")
        XCTAssertFalse(oneLeft.segmentExportEnabled)

        model.assembly.joinAsIs(seam: 1)
        let ready = model.assembly.restoreExportPrompt
        XCTAssertEqual(ready.unalignedCount, 0)
        XCTAssertEqual(ready.primaryTitle, "分段导出")
        XCTAssertTrue(ready.primaryExports)
        XCTAssertTrue(ready.segmentExportEnabled)
        XCTAssertNil(ready.segmentExportCaption)
        XCTAssertFalse(model.assembly.exportWithinLimits(dedupeStickyBars: true).isEmpty)
    }

    @MainActor
    func testReviewBottomBarPendingConfirmFollowsDuplicateChoices() {
        let sticky = PendingStickyConfirmation(headerRows: 6, footerRows: 0, seamCount: 2, keepOnce: nil)
        let model = StitchPreviewModel(
            assembly: ScrollAssembly(
                seams: [ScrollSeam(kind: .needsAlignment, suggestedOverlap: 9)],
                pendingSticky: sticky,
                duplicateCandidates: (1...3).map { DuplicateSegmentCandidate(id: "dup-\($0)") }
            ),
            notice: nil
        )

        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 3)
        XCTAssertEqual(model.assembly.unalignedSeamCount, 1)
        XCTAssertEqual(model.assembly.pendingSticky?.prompt, sticky.prompt)
        XCTAssertEqual(
            model.assembly.reviewBottomBar,
            "⚠ 还有 5 处没处理（待对齐 1 · 待确认 3 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertFalse(model.canCommit)

        model.resolveDuplicateCandidate("dup-1", choice: .keepOnce)
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 2)
        XCTAssertEqual(model.assembly.unalignedSeamCount, 1)
        XCTAssertTrue(model.assembly.pendingSticky?.isUnresolved == true)
        XCTAssertTrue(model.assembly.reviewBottomBar?.contains("待确认 2") == true)

        model.resolveDuplicateCandidate("dup-2", choice: .keepBoth)
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertTrue(model.assembly.reviewBottomBar?.contains("待确认 1") == true)

        model.resolveDuplicateCandidate("dup-3", choice: .keepOnce)
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertEqual(model.assembly.unalignedSeamCount, 1)
        XCTAssertEqual(
            model.assembly.reviewBottomBar,
            "⚠ 还有 2 处没处理（待对齐 1 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertFalse(model.assembly.reviewBottomBar?.contains("待确认 0") ?? false)
        XCTAssertFalse(model.canCommit)

        model.undoDuplicateCandidateChoice()
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(model.assembly.unalignedSeamCount, 1)
        XCTAssertTrue(model.assembly.reviewRemainder.stickyPending)
        XCTAssertEqual(
            model.assembly.reviewBottomBar,
            "⚠ 还有 3 处没处理（待对齐 1 · 待确认 1 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )

        let onlyCandidates = StitchPreviewModel(
            assembly: ScrollAssembly(
                duplicateCandidates: (1...3).map { DuplicateSegmentCandidate(id: "dup-\($0)") }
            ),
            notice: nil
        )
        XCTAssertEqual(
            onlyCandidates.assembly.reviewBottomBar,
            "⚠ 还有 3 处没处理（待确认 3）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        onlyCandidates.resolveDuplicateCandidate("dup-1", choice: .keepOnce)
        XCTAssertEqual(onlyCandidates.assembly.pendingDuplicateConfirmCount, 2)
        onlyCandidates.resolveDuplicateCandidate("dup-2", choice: .keepBoth)
        XCTAssertEqual(onlyCandidates.assembly.pendingDuplicateConfirmCount, 1)
        onlyCandidates.resolveDuplicateCandidate("dup-3", choice: .keepOnce)
        XCTAssertEqual(onlyCandidates.assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertNil(onlyCandidates.assembly.reviewBottomBar)
        XCTAssertTrue(onlyCandidates.canCommit)
        onlyCandidates.undoDuplicateCandidateChoice()
        XCTAssertEqual(onlyCandidates.assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(
            onlyCandidates.assembly.reviewBottomBar,
            "⚠ 还有 1 处没处理（待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertFalse(onlyCandidates.canCommit)
    }

    @MainActor
    func testRestoreByIdThenUndoHidesPendingConfirm() {
        let model = StitchPreviewModel(
            assembly: ScrollAssembly(
                duplicateCandidates: (1...3).map { DuplicateSegmentCandidate(id: "dup-\($0)") }
            ),
            notice: nil
        )
        model.resolveDuplicateCandidate("dup-1", choice: .keepOnce)
        model.resolveDuplicateCandidate("dup-2", choice: .keepBoth)
        model.resolveDuplicateCandidate("dup-3", choice: .keepOnce)
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertNil(model.assembly.reviewBottomBar)
        XCTAssertTrue(model.canCommit)

        model.restoreDuplicateCandidate("missing")
        XCTAssertNil(model.assembly.reviewBottomBar)

        model.restoreDuplicateCandidate("dup-2")
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(
            model.assembly.reviewBottomBar,
            "⚠ 还有 1 处没处理（待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertFalse(model.canCommit)

        model.undoDuplicateCandidateChoice()
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertEqual(model.assembly.duplicateCandidates.first { $0.id == "dup-2" }?.choice, .keepBoth)
        XCTAssertNil(model.assembly.reviewBottomBar)
        XCTAssertTrue(model.canCommit)
    }

    func testFrameCopyUsesGroupedNumbersAndOmitsEmptyRemainder() {
        XCTAssertEqual(StitchCopy.grouped(17_436), "17,436")
        XCTAssertEqual(StitchCopy.grouped(16_384), "16,384")
        XCTAssertEqual(StitchCopy.grouped(999), "999")
        XCTAssertEqual(StitchCopy.overLimit(height: 18_240), "还原后约 18,240 px，超过单张上限 16,384 px")
        XCTAssertEqual(StitchCopy.overLimitNote, "不会悄悄截断。可以分段导出（每段都不超上限），或保持去重。")
        XCTAssertEqual(StitchCopy.overlayDedupedChip, "已去掉重复固定栏 · 还原固定栏")
        XCTAssertEqual(StitchCopy.overlayRestoredChip, "已还原固定栏 · 撤销")
        XCTAssertEqual(OverlayStickyChip.deduped.line, "已去掉重复固定栏 · 还原固定栏")
        XCTAssertEqual(OverlayStickyChip.restored.line, "已还原固定栏 · 撤销")
        XCTAssertEqual(StitchCopy.keepOnceChoice, "当固定栏，只留一次")
        XCTAssertEqual(StitchCopy.keepAllChoice, "当内容，全部保留")
        XCTAssertEqual(
            StitchCopy.uncertainPrompt(headerRows: 8, footerRows: 0, seamCount: 7),
            "待确认 · 顶部这条可能是固定栏（涉及 7 处接缝）"
        )

        let all = StitchCopy.Remainder(unaligned: 2, pendingConfirm: 1, stickyPending: true)
        XCTAssertEqual(
            StitchCopy.bottomBar(all),
            "⚠ 还有 4 处没处理（待对齐 2 · 待确认 1 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        let omitConfirm = StitchCopy.Remainder(unaligned: 3, pendingConfirm: 0, stickyPending: true)
        XCTAssertEqual(
            StitchCopy.bottomBar(omitConfirm),
            "⚠ 还有 4 处没处理（待对齐 3 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        let onlyConfirm = StitchCopy.Remainder(unaligned: 0, pendingConfirm: 2, stickyPending: false)
        XCTAssertEqual(
            StitchCopy.bottomBar(onlyConfirm),
            "⚠ 还有 2 处没处理（待确认 2）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        let onlySticky = StitchCopy.Remainder(stickyPending: true)
        XCTAssertEqual(
            StitchCopy.bottomBar(onlySticky),
            "⚠ 还有 1 处没处理（固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertNil(StitchCopy.bottomBar(.init()))
    }

    @MainActor
    func testOverlayStitchLoadIsSharedOffTheMainThread() async throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 15)), .appended(15))
        let assembly = stitcher.takeAssembly()
        let deduped = try XCTUnwrap(assembly.flattenedIfResolved())
        let image = try XCTUnwrap(deduped.cgImage())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PrettyShotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(directory: directory, limit: 10)
        let item = try store.add(image: image, scale: 2, mode: .scrolling)
        try store.saveStitch(assembly, for: item)

        StitchLoadMetrics.reset()
        let warm = await store.loadStitchForOverlay(store.items[0])
        let warmAgain = await store.loadStitchForOverlay(store.items[0])
        XCTAssertEqual(warm?.flattenedIfResolved()?.height, deduped.height)
        XCTAssertEqual(warmAgain?.flattenedIfResolved()?.height, deduped.height)
        XCTAssertEqual(StitchLoadMetrics.diskReads, 1, "the overlay reads the sidecar once")
        XCTAssertFalse(StitchLoadMetrics.lastReadWasMainThread)

        let cold = HistoryStore(directory: directory, limit: 10)
        StitchLoadMetrics.reset()
        async let firstLoad = cold.loadStitchForOverlay(cold.items[0])
        async let secondLoad = cold.loadStitchForOverlay(cold.items[0])
        let first = await firstLoad
        let second = await secondLoad
        let loaded = try XCTUnwrap(first)
        let shared = try XCTUnwrap(second)
        XCTAssertEqual(loaded.flattenedIfResolved()?.height, shared.flattenedIfResolved()?.height)
        XCTAssertEqual(StitchLoadMetrics.diskReads, 1, "concurrent overlay loads must share one disk read")
        XCTAssertFalse(StitchLoadMetrics.lastReadWasMainThread)
    }

    @MainActor
    func testPruneAndDeleteReleaseTheStitchCache() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 15)), .appended(15))
        let assembly = stitcher.takeAssembly()
        let image = try XCTUnwrap(assembly.flattenedIfResolved()?.cgImage())

        let prunedDir = FileManager.default.temporaryDirectory.appendingPathComponent("PrettyShotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prunedDir) }
        let pruned = HistoryStore(directory: prunedDir, limit: 1)
        let first = try pruned.add(image: image, scale: 2, mode: .scrolling)
        try pruned.saveStitch(assembly, for: first)
        XCTAssertNotNil(pruned.loadStitch(for: pruned.items[0]))
        XCTAssertNotNil(pruned.cachedStitch(for: first))
        _ = try pruned.add(image: image, scale: 2, mode: .scrolling)
        XCTAssertNil(pruned.cachedStitch(for: first), "pruning a history item must drop its decoded stitch")

        let deletedDir = FileManager.default.temporaryDirectory.appendingPathComponent("PrettyShotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: deletedDir) }
        let deleted = HistoryStore(directory: deletedDir, limit: 4)
        let kept = try deleted.add(image: image, scale: 2, mode: .scrolling)
        try deleted.saveStitch(assembly, for: kept)
        XCTAssertNotNil(deleted.loadStitch(for: deleted.items[0]))
        deleted.delete(deleted.items[0])
        XCTAssertNil(deleted.cachedStitch(for: kept), "deleting a history item must drop its decoded stitch")
    }

    @MainActor
    func testInFlightStitchReadDoesNotRepopulateDeletedCache() async throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 15)), .appended(15))
        let assembly = stitcher.takeAssembly()
        let image = try XCTUnwrap(assembly.flattenedIfResolved()?.cgImage())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PrettyShotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(directory: directory, limit: 4)
        let item = try store.add(image: image, scale: 2, mode: .scrolling)
        try store.saveStitch(assembly, for: item)

        let gate = DispatchSemaphore(value: 0)
        let slot = StitchLoadSlot()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            StitchLoadMetrics.setBeforeRead {
                StitchLoadMetrics.setBeforeRead(nil)
                cont.resume()
                gate.wait()
            }
            slot.task = Task { @MainActor in
                await store.loadStitchForOverlay(item)
            }
        }
        store.delete(item)
        gate.signal()
        let loaded = await slot.task?.value
        XCTAssertNil(loaded)
        XCTAssertNil(store.cachedStitch(for: item), "a read that finishes after delete must not cache the stitch")
        StitchLoadMetrics.reset()
    }

    func testSeamLoupeIsFullResolutionAndTracksOverlap() throws {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, slot: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.page(scroll: 0, slot: 80)), .unmatched)
        let assembly = stitcher.takeAssembly()
        let first = try XCTUnwrap(assembly.seamLoupe(boundary: 0, overlap: 0))
        let second = try XCTUnwrap(assembly.seamLoupe(boundary: 0, overlap: 12))
        XCTAssertEqual(first.width, ScrollFixtures.width)
        XCTAssertLessThanOrEqual(first.height, 72 + 36)
        XCTAssertNotEqual(first.pixels, second.pixels)
    }
}

private final class StitchLoadSlot: @unchecked Sendable {
    var task: Task<ScrollAssembly?, Never>?
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

    static func color(slot: Int) -> [UInt8] {
        let index = palette[slot % palette.count]
        return [levels[index % 5], levels[(index / 5) % 5], levels[index / 25]]
    }

    static func row(_ image: RGBAImage, _ y: Int) -> [UInt8] {
        let i = y * image.width * 4
        return [image.pixels[i], image.pixels[i + 1], image.pixels[i + 2]]
    }

    /// Header rows stay put, but the first content row only drifts a little, so the bar is not safe to strip.
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

    /// Same distinctive row repeated every `period` rows, shifted by `scroll`.
    static func periodic(scroll: Int, height: Int = 180, period: Int = 60) -> RGBAImage {
        fill(width: width, height: height) { y in (y + scroll) % period }
    }

    static func gradient(scroll: Int, height: Int = 12) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let rgb = gradientColor(scroll: scroll, y: y)
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    static func gradientColor(scroll: Int, y: Int) -> [UInt8] {
        [UInt8(20 + (y + scroll) * 15), 180, 40]
    }

    /// Repeating card chrome plus a unique body on every page-Y, like a feed.
    static func cards(scroll: Int, height: Int = 160, cardHeight: Int = 32) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let pageY = y + scroll
            let offset = pageY % cardHeight
            let rgb: [UInt8]
            if offset < 5 {
                rgb = [30 + UInt8(offset) * 12, 44, 58]
            } else {
                let v = UInt8(truncatingIfNeeded: pageY &* 17)
                let u = UInt8(truncatingIfNeeded: pageY &* 13 &+ 40)
                rgb = [v, u, 200]
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

    /// Each pair of rows is nearly identical, so 10 px and 11 px both look plausible.
    /// Pairs themselves stay far apart so the page is not a slow gradient.
    static func softStep(scroll: Int, height: Int = 80) -> RGBAImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let pageY = y + scroll
            let pair = pageY / 2
            let rgb = color(slot: contentSlot + pair)
            let tint = UInt8(pageY % 2 == 0 ? 0 : 3)
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0] &+ tint
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    /// Mostly blank viewport. A short run of unique rows sits at the bottom and scrolls.
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

    /// A stationary top bar taller than the sticky cap, with unique content scrolling under it.
    static func fixedBarViewport(scroll: Int, height: Int, barRows: Int) -> RGBAImage {
        fill(width: width, height: height) { y in
            if y < barRows { return y }
            return contentSlot + y + scroll
        }
    }

    /// Period close to the frame height, so one row votes for both `s` and `s - period`.
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

    /// Inverts a few rows so the frame is not "unchanged", but most of the picture still matches.
    static func flashed(_ image: RGBAImage, rows: Int) -> RGBAImage {
        var copy = image
        let pixels = copy.pixels
        var next = pixels
        for y in 0..<min(rows, image.height) {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                next[i] = 255 - pixels[i]
                next[i + 1] = 255 - pixels[i + 1]
                next[i + 2] = 255 - pixels[i + 2]
            }
        }
        copy = RGBAImage(width: image.width, height: image.height, pixels: next)
        return copy
    }

    static func noised(_ image: RGBAImage, amplitude: Int) -> RGBAImage {
        var copy = image
        for index in stride(from: 0, to: copy.pixels.count, by: 4) {
            for channel in 0..<3 {
                let delta = ((index + channel) * 17 % (amplitude * 2 + 1)) - amplitude
                let mixed = Int(copy.pixels[index + channel]) + delta
                copy.pixels[index + channel] = UInt8(min(255, max(0, mixed)))
            }
        }
        return copy
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
