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

    @MainActor
    func testKeepOnceRestoreToastAndUndoReturnToTheEarlierChoice() {
        let model = StitchPreviewModel(
            assembly: ScrollAssembly(duplicateCandidates: [
                DuplicateSegmentCandidate(id: "dup-1", seamNumber: 2, rowCount: 2),
            ]),
            notice: nil
        )
        XCTAssertEqual(model.assembly.duplicateCandidates[0].pendingTitle(displayIndex: 1), "重复段 1 · 待确认")
        XCTAssertEqual(model.assembly.duplicateCandidates[0].locationLine, "接缝 2 下方 · 2 行")
        XCTAssertEqual(StitchCopy.duplicateDetail, "这段内容出现了两次")
        XCTAssertEqual(StitchCopy.keepDuplicateOnce, "只保留一次")
        XCTAssertEqual(StitchCopy.keepDuplicateBoth, "都保留")
        XCTAssertEqual(StitchCopy.duplicateHandled(.keepOnce), "✓ 已处理 · 只保留一次")
        XCTAssertEqual(StitchCopy.duplicateHandled(.keepBoth), "✓ 已处理 · 都保留")

        model.resolveDuplicateCandidate("dup-1", choice: .keepOnce)
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 0)
        model.resolveDuplicateCandidate("dup-1", choice: .keepBoth)

        let before = model.assembly.duplicateUndoCount
        model.restoreDuplicateCandidate("dup-1")
        model.restoreDuplicateCandidate("dup-1")
        XCTAssertEqual(model.assembly.duplicateUndoCount, before + 1)
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(
            model.duplicateToast,
            "重复段 1 已还原为待确认 · 待确认还剩 1 处"
        )
        XCTAssertFalse(model.assembly.reviewBottomBar?.contains("待确认 0") ?? false)
        XCTAssertEqual(
            model.assembly.reviewBottomBar,
            "⚠ 还有 1 处没处理（待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )

        model.undoDuplicateToast()
        XCTAssertNil(model.duplicateToast)
        XCTAssertEqual(model.assembly.duplicateCandidates[0].choice, .keepBoth)
        model.undoDuplicateCandidateChoice()
        XCTAssertEqual(model.assembly.duplicateCandidates[0].choice, .keepOnce)
    }

    @MainActor
    func testPreviewPrimaryStepsCountOneKindAtATime() {
        let model = StitchPreviewModel(
            assembly: ScrollAssembly(
                seams: [ScrollSeam(kind: .needsAlignment, suggestedOverlap: 4)],
                pendingSticky: PendingStickyConfirmation(headerRows: 8, footerRows: 0, seamCount: 7, keepOnce: nil),
                duplicateCandidates: [DuplicateSegmentCandidate(id: "dup-1", seamNumber: 2, rowCount: 2)]
            ),
            notice: nil
        )
        XCTAssertEqual(model.assembly.previewPrimaryTitle, "处理下一处 · 1")
        XCTAssertFalse(model.focusPreviewPrimary())
        XCTAssertEqual(model.selectedBoundary, 0)
        XCTAssertFalse(model.highlightPendingSticky)

        model.assembly.joinAsIs(seam: 0)
        XCTAssertEqual(model.assembly.previewPrimaryTitle, "处理下一处 · 1")
        XCTAssertFalse(model.focusPreviewPrimary())
        XCTAssertTrue(model.highlightPendingSticky)
        XCTAssertNil(model.selectedDuplicateID)

        model.confirmPendingSticky(keepOnce: true)
        XCTAssertEqual(model.assembly.previewPrimaryTitle, "先确认 1 处重复段")
        XCTAssertFalse(model.focusPreviewPrimary())
        XCTAssertEqual(model.selectedDuplicateID, "dup-1")

        model.resolveDuplicateCandidate("dup-1", choice: .keepOnce)
        XCTAssertEqual(model.assembly.previewPrimaryTitle, "下一步 · 美化 →")
        XCTAssertNil(model.assembly.reviewBottomBar)
        XCTAssertTrue(model.canCommit)
        XCTAssertTrue(model.focusPreviewPrimary())

        let seamsOnly = ScrollAssembly(seams: [
            ScrollSeam(kind: .needsAlignment, suggestedOverlap: 1),
            ScrollSeam(kind: .needsAlignment, suggestedOverlap: 2),
        ])
        XCTAssertEqual(seamsOnly.previewPrimaryTitle, "处理下一处 · 2")
        let stickyOnly = ScrollAssembly(
            pendingSticky: PendingStickyConfirmation(headerRows: 4, footerRows: 0, seamCount: 3, keepOnce: nil)
        )
        XCTAssertEqual(stickyOnly.previewPrimaryTitle, "处理下一处 · 1")
        let duplicatesOnly = ScrollAssembly(duplicateCandidates: [
            DuplicateSegmentCandidate(id: "a"),
            DuplicateSegmentCandidate(id: "b"),
        ])
        XCTAssertEqual(duplicatesOnly.previewPrimaryTitle, "先确认 2 处重复段")
    }

    @MainActor
    func testBottomBarExamplesDoNotAddDuplicateAndStickyCounts() {
        XCTAssertEqual(
            StitchCopy.bottomBar(.init(pendingConfirm: 1)),
            "⚠ 还有 1 处没处理（待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        let duplicateAndSticky = StitchPreviewModel(
            assembly: ScrollAssembly(
                pendingSticky: PendingStickyConfirmation(headerRows: 4, footerRows: 0, seamCount: 1, keepOnce: nil),
                duplicateCandidates: [DuplicateSegmentCandidate(id: "dup-1")]
            ),
            notice: nil
        )
        XCTAssertEqual(
            duplicateAndSticky.assembly.reviewBottomBar,
            "⚠ 还有 2 处没处理（待确认 1 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertEqual(duplicateAndSticky.assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(duplicateAndSticky.assembly.unresolvedItemCount, 2)

        let allThree = StitchPreviewModel(
            assembly: ScrollAssembly(
                seams: [ScrollSeam(kind: .needsAlignment, suggestedOverlap: 2)],
                pendingSticky: PendingStickyConfirmation(headerRows: 4, footerRows: 0, seamCount: 2, keepOnce: nil),
                duplicateCandidates: [DuplicateSegmentCandidate(id: "dup-1")]
            ),
            notice: nil
        )
        XCTAssertEqual(
            allThree.assembly.reviewBottomBar,
            "⚠ 还有 3 处没处理（待对齐 1 · 待确认 1 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertFalse(allThree.assembly.reviewRemainder.detail.contains("重复段待确认"))
        XCTAssertEqual(StitchCopy.handleUnaligned(1), "先处理 1 处待对齐")
    }

    @MainActor
    func testRestitchActionsOnThePreviewClearCandidatesAndUndo() {
        func model() -> StitchPreviewModel {
            let image = RGBAImage(width: 8, height: 12, pixels: [UInt8](repeating: 255, count: 8 * 12 * 4))
            let segment = ScrollSegment(image: image, confidentSeamYs: [])
            let preview = StitchPreviewModel(
                assembly: ScrollAssembly(
                    segments: [segment, segment],
                    seams: [ScrollSeam(kind: .needsAlignment, suggestedOverlap: 5)],
                    duplicateCandidates: [DuplicateSegmentCandidate(id: "dup-1", seamNumber: 2, rowCount: 2)]
                ),
                notice: nil
            )
            preview.resolveDuplicateCandidate("dup-1", choice: .keepOnce)
            preview.resolveDuplicateCandidate("dup-1", choice: .keepBoth)
            preview.select(boundary: 0)
            return preview
        }

        let started = model()
        started.beginStitch()
        XCTAssertTrue(started.assembly.duplicateCandidates.isEmpty)
        XCTAssertEqual(started.assembly.duplicateUndoCount, 0)
        started.undoDuplicateCandidateChoice()
        XCTAssertTrue(started.assembly.duplicateCandidates.isEmpty)

        let finished = model()
        finished.overlap = 4
        finished.finishManualAlignment()
        XCTAssertTrue(finished.assembly.duplicateCandidates.isEmpty)
        XCTAssertEqual(finished.assembly.duplicateUndoCount, 0)
        if case .aligned(let overlap) = finished.assembly.seams[0].kind {
            XCTAssertEqual(overlap, 4)
        } else {
            XCTFail("完成 keeps the manual overlap")
        }

        let restored = model()
        restored.restoreAutoAlignment()
        XCTAssertTrue(restored.assembly.duplicateCandidates.isEmpty)
        XCTAssertEqual(restored.assembly.duplicateUndoCount, 0)
        if case .aligned(let overlap) = restored.assembly.seams[0].kind {
            XCTAssertEqual(overlap, 5)
        } else {
            XCTFail("还原自动 applies the suggestion")
        }
    }

    @MainActor
    func testManualFinishOnThePreviewRerunsDetectionAndBlocksExport() throws {
        let model = StitchPreviewModel(assembly: try Self.duplicateAfterUnalignedSeam(), notice: nil)
        let id = try XCTUnwrap(model.assembly.duplicateCandidates.first).id
        model.resolveDuplicateCandidate(id, choice: .keepOnce)
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 0)
        model.select(boundary: 0)
        model.overlap = 4
        model.finishManualAlignment()
        XCTAssertEqual(model.assembly.duplicateUndoCount, 0)
        XCTAssertEqual(model.assembly.duplicateCandidates.count, 1)
        XCTAssertNil(model.assembly.duplicateCandidates[0].choice)
        XCTAssertTrue(model.assembly.duplicateCandidates[0].seamMoved)
        XCTAssertEqual(model.assembly.duplicateCandidates[0].movedSeamNumber, 1)
        XCTAssertEqual(model.assembly.duplicateCandidates[0].locationLine, "接缝 2 下方 · 2 行 · 接缝动过，需要重选")
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(model.assembly.previewPrimaryTitle, "先确认 1 处重复段")
        XCTAssertFalse(model.canCommit)
        XCTAssertNil(model.assembly.flattenedIfResolved())
        XCTAssertTrue(model.assembly.exportWithinLimits(dedupeStickyBars: true).isEmpty)
        XCTAssertEqual(
            model.duplicateToast,
            "接缝 1 已对齐（手动 +4 px） · 接缝 1 动过，那里的 1 处选择已清掉，需要重选"
        )
        XCTAssertFalse(model.duplicateToastCanUndo)
        XCTAssertEqual(model.duplicateMarks.map(\.id), [id])
    }

    @MainActor
    func testRestoreAutoOnThePreviewRerunsDetectionAndBlocksExport() throws {
        let model = StitchPreviewModel(assembly: try Self.duplicateAfterUnalignedSeam(), notice: nil)
        let id = try XCTUnwrap(model.assembly.duplicateCandidates.first).id
        model.assembly.seams[0].suggestedOverlap = 5
        model.resolveDuplicateCandidate(id, choice: .keepOnce)
        model.select(boundary: 0)
        model.restoreAutoAlignment()
        XCTAssertEqual(model.assembly.duplicateUndoCount, 0)
        XCTAssertEqual(model.assembly.duplicateCandidates.count, 1)
        XCTAssertNil(model.assembly.duplicateCandidates[0].choice)
        XCTAssertTrue(model.assembly.duplicateCandidates[0].seamMoved)
        XCTAssertEqual(model.assembly.duplicateCandidates[0].movedSeamNumber, 1)
        XCTAssertEqual(model.assembly.duplicateCandidates[0].locationLine, "接缝 2 下方 · 2 行 · 接缝动过，需要重选")
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertFalse(model.canCommit)
        XCTAssertNil(model.assembly.flattenedIfResolved())
        XCTAssertEqual(model.assembly.previewPrimaryTitle, "先确认 1 处重复段")
        XCTAssertEqual(
            model.duplicateToast,
            "接缝 1 已还原自动 · 接缝 1 动过，那里的 1 处选择已清掉，需要重选"
        )
        XCTAssertFalse(model.duplicateToastCanUndo)
        XCTAssertEqual(model.duplicateMarks.map(\.id), [id])
        if case .aligned(let overlap) = model.assembly.seams[0].kind {
            XCTAssertEqual(overlap, 5)
        } else {
            XCTFail("还原自动 applies the suggestion")
        }
    }

    @MainActor
    func testKeepOnceSurvivesHistoryOverLimitExport() throws {
        var assembly = try Self.seamAdjacentAssembly()
        let candidate = try XCTUnwrap(assembly.duplicateCandidates.first)
        assembly.resolveDuplicateCandidate(candidate.id, choice: .keepOnce)
        let keptHeight = assembly.stackedHeight(deduping: true)
        XCTAssertEqual(keptHeight, 30)
        let marker = ScrollFixtures.color(slot: 22)
        let image = try XCTUnwrap(assembly.flattenedIfResolved()?.cgImage())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PrettyShotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(directory: directory, limit: 4)
        let item = try store.add(image: image, scale: 2, mode: .scrolling)
        try store.saveStitch(assembly, for: item)
        let reloaded = HistoryStore(directory: directory, limit: 4)
        let loaded = try XCTUnwrap(reloaded.loadStitch(for: reloaded.items[0]))
        XCTAssertEqual(loaded.duplicateCandidates.first?.choice, .keepOnce)
        let chunks = loaded.exportWithinLimits(dedupeStickyBars: false, maxHeight: 16, maxPixels: 24_000_000)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.height }, keptHeight)
        let joined = try XCTUnwrap(RGBAImage.verticalJoin(chunks))
        var hits = 0
        for y in 0..<joined.height where ScrollFixtures.row(joined, y) == marker {
            hits += 1
        }
        XCTAssertEqual(hits, 1)
    }

    @MainActor
    func testChoiceToastsUndoBackToPendingAndRestoreRows() throws {
        let model = StitchPreviewModel(assembly: try Self.seamAdjacentAssembly(), notice: nil)
        let id = try XCTUnwrap(model.assembly.duplicateCandidates.first).id
        let raw = model.assembly.displayedSegmentHeight(0)
        model.refresh()
        XCTAssertEqual(model.duplicateMarks.map(\.label), ["重复段 1 · 待确认"])
        XCTAssertEqual(model.duplicateMarks.first?.height, 2)
        XCTAssertEqual(StitchPreviewModel.duplicatePreviewScrollID(id), "dup-region-\(id)")

        model.resolveDuplicateCandidate(id, choice: .keepOnce)
        XCTAssertEqual(
            model.duplicateToast,
            StitchCopy.duplicateChoiceToast(index: 1, choice: .keepOnce, remaining: 0)
        )
        XCTAssertTrue(model.duplicateToastCanUndo)
        XCTAssertEqual(model.assembly.displayedSegmentHeight(0), raw - 2)
        XCTAssertTrue(model.duplicateMarks.isEmpty)
        model.undoDuplicateToast()
        XCTAssertNil(model.duplicateToast)
        XCTAssertNil(model.assembly.duplicateCandidates[0].choice)
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(model.assembly.displayedSegmentHeight(0), raw)
        XCTAssertEqual(model.duplicateMarks.count, 1)

        model.resolveDuplicateCandidate(id, choice: .keepBoth)
        XCTAssertEqual(
            model.duplicateToast,
            StitchCopy.duplicateChoiceToast(index: 1, choice: .keepBoth, remaining: 0)
        )
        XCTAssertEqual(model.assembly.displayedSegmentHeight(0), raw)
        XCTAssertTrue(model.duplicateMarks.isEmpty)
        model.undoDuplicateToast()
        XCTAssertNil(model.assembly.duplicateCandidates[0].choice)
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(model.assembly.displayedSegmentHeight(0), raw)
        XCTAssertEqual(model.duplicateMarks.first?.label, "重复段 1 · 待确认")
    }

    func testCleanScrollStillFinishesWithoutDuplicateConfirmation() throws {
        var stitcher = ScrollStitcher()
        stitcher.beginStitch()
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 0)), .seeded)
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 15)), .appended(15))
        XCTAssertEqual(stitcher.ingest(ScrollFixtures.viewport(scroll: 30)), .appended(15))
        let assembly = stitcher.takeAssembly()
        XCTAssertTrue(assembly.duplicateCandidates.isEmpty)
        XCTAssertFalse(assembly.needsReview)
        XCTAssertEqual(assembly.flattenedIfResolved()?.height, 90)
        XCTAssertEqual(assembly.previewPrimaryTitle, "下一步 · 美化 →")
        XCTAssertNil(assembly.reviewBottomBar)
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

    @MainActor
    func testUnmovedSeamKeepsChoicesOnThePreview() throws {
        let model = StitchPreviewModel(assembly: Self.unmovedSeamAssembly(leaveOnePending: true), notice: nil)
        model.select(boundary: 0)
        model.overlap = 0
        model.finishManualAlignment()

        XCTAssertEqual(model.assembly.duplicateUndoCount, 0)
        XCTAssertEqual(model.assembly.duplicateCandidates.map(\.choice), [.keepOnce, .keepBoth, nil])
        XCTAssertTrue(model.assembly.duplicateCandidates.allSatisfy { !$0.seamMoved })
        XCTAssertEqual(model.assembly.duplicateCandidates[0].handledLine, "✓ 已处理 · 只保留一次")
        XCTAssertEqual(model.assembly.duplicateCandidates[1].handledLine, "✓ 已处理 · 都保留")
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 1)
        XCTAssertEqual(model.duplicateMarks.map(\.label), ["重复段 3 · 待确认"])
        XCTAssertEqual(model.assembly.previewPrimaryTitle, "先确认 1 处重复段")
        XCTAssertEqual(model.assembly.reviewBottomBar, Self.confirmBar(1))
        XCTAssertFalse(model.canCommit)
        XCTAssertEqual(
            model.duplicateToast,
            "接缝 1 已对齐（手动 +0 px） · 重复段已重新识别，保留了 2 处选择，1 处待确认"
        )
        XCTAssertFalse(model.duplicateToastCanUndo)
    }

    @MainActor
    func testAllKeptChoicesUseTheKeptToastOnThePreview() {
        let model = StitchPreviewModel(assembly: Self.unmovedSeamAssembly(leaveOnePending: false), notice: nil)
        model.select(boundary: 0)
        model.overlap = 0
        model.finishManualAlignment()

        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 0)
        XCTAssertTrue(model.duplicateMarks.isEmpty)
        XCTAssertTrue(model.assembly.duplicateCandidates.allSatisfy { $0.choice != nil && !$0.seamMoved })
        XCTAssertNil(model.assembly.reviewBottomBar)
        XCTAssertEqual(model.assembly.previewPrimaryTitle, "下一步 · 美化 →")
        XCTAssertTrue(model.canCommit)
        XCTAssertEqual(
            model.duplicateToast,
            "接缝 1 已对齐（手动 +0 px） · 重复段的选择都保留了"
        )
        XCTAssertFalse(model.duplicateToastCanUndo)
        XCTAssertEqual(model.assembly.duplicateUndoCount, 0)
    }

    @MainActor
    func testMovedSeamClearsOnlyThatCardOnThePreview() throws {
        let model = StitchPreviewModel(assembly: Self.movedSeamAssembly(), notice: nil)
        model.select(boundary: 0)
        model.overlap = 6
        model.finishManualAlignment()

        let kept = try XCTUnwrap(model.assembly.duplicateCandidates.first { $0.segmentIndex == 0 })
        let cleared = try XCTUnwrap(model.assembly.duplicateCandidates.first { $0.seamNumber == 3 })
        XCTAssertEqual(kept.choice, .keepOnce)
        XCTAssertEqual(kept.handledLine, "✓ 已处理 · 只保留一次")
        XCTAssertFalse(kept.seamMoved)
        XCTAssertEqual(kept.locationLine, "接缝 1 下方 · 2 行")
        XCTAssertFalse(model.duplicateMarks.contains { $0.id == kept.id })
        XCTAssertNil(cleared.choice)
        XCTAssertTrue(cleared.seamMoved)
        XCTAssertEqual(cleared.movedSeamNumber, 2)
        XCTAssertEqual(cleared.locationLine, "接缝 3 下方 · 2 行 · 接缝动过，需要重选")
        XCTAssertEqual(
            StitchCopy.duplicateSeamMovedNote(seam: 2),
            "接缝 2 动过，这里之前的选择已清掉，需要重选。"
        )
        XCTAssertTrue(model.duplicateMarks.contains { $0.id == cleared.id })
        XCTAssertEqual(model.assembly.pendingDuplicateConfirmCount, 2)
        XCTAssertEqual(model.assembly.previewPrimaryTitle, "先确认 2 处重复段")
        XCTAssertEqual(model.assembly.reviewBottomBar, Self.confirmBar(2))
        XCTAssertEqual(model.assembly.duplicateUndoCount, 0)
        XCTAssertEqual(
            model.duplicateToast,
            "接缝 2 已对齐（手动 +6 px） · 接缝 2 动过，那里的 1 处选择已清掉，需要重选"
        )
        XCTAssertFalse(model.duplicateToastCanUndo)

        model.resolveDuplicateCandidate(cleared.id, choice: .keepBoth)
        let rechosen = try XCTUnwrap(model.assembly.duplicateCandidates.first { $0.id == cleared.id })
        XCTAssertFalse(rechosen.seamMoved)
        XCTAssertEqual(rechosen.locationLine, "接缝 3 下方 · 2 行")
        XCTAssertFalse(model.duplicateMarks.contains { $0.id == cleared.id })
        XCTAssertTrue(model.duplicateToastCanUndo)
    }

    @MainActor
    func testDraggingSeamTwoResetsTheSegmentBelowAndKeepsTheCandidateUnderSeamOne() throws {
        let model = StitchPreviewModel(assembly: Self.movedSeamAssembly(), notice: nil)
        XCTAssertEqual(model.assembly.visibleSeamNumber(boundary: 0), 2)
        model.select(boundary: 0)
        model.overlap = 6
        model.finishManualAlignment()

        let underSeamOne = try XCTUnwrap(model.assembly.duplicateCandidates.first { $0.segmentIndex == 0 })
        XCTAssertEqual(underSeamOne.seamNumber, 1)
        XCTAssertEqual(underSeamOne.handledLine, "✓ 已处理 · 只保留一次")
        XCTAssertFalse(underSeamOne.seamMoved)
        XCTAssertFalse(model.duplicateMarks.contains { $0.id == underSeamOne.id })

        let belowSeamTwo = try XCTUnwrap(model.assembly.duplicateCandidates.first { $0.seamNumber == 3 })
        XCTAssertEqual(belowSeamTwo.segmentIndex, 1)
        XCTAssertNil(belowSeamTwo.choice)
        XCTAssertTrue(belowSeamTwo.locationLine.hasSuffix("· 接缝动过，需要重选"))
        XCTAssertTrue(model.duplicateMarks.contains { $0.id == belowSeamTwo.id })
    }

    private static func seamAdjacentAssembly() throws -> ScrollAssembly {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(slotted(Array(0..<24))), .seeded)
        XCTAssertEqual(stitcher.ingest(slotted(seamDuplicate(of: Array(8..<32), previousTail: [22, 23]))), .appended(8))
        let assembly = stitcher.takeAssembly()
        XCTAssertEqual(assembly.duplicateCandidates.count, 1)
        return assembly
    }

    private static func duplicateAfterUnalignedSeam() throws -> ScrollAssembly {
        var stitcher = ScrollStitcher()
        XCTAssertEqual(stitcher.ingest(slotted(Array(0..<24))), .seeded)
        XCTAssertEqual(stitcher.ingest(slotted(Array(80..<104))), .unmatched)
        let outcome = stitcher.ingest(slotted(seamDuplicate(of: Array(88..<112), previousTail: [102, 103])))
        guard case .appended(let rows) = outcome else {
            XCTFail("expected the second segment to join, got \(outcome)")
            return ScrollAssembly()
        }
        XCTAssertEqual(rows, 8)
        return stitcher.takeAssembly()
    }

    private static func seamDuplicate(of slots: [Int], previousTail: [Int]) -> [Int] {
        var copy = slots
        let start = copy.count - 8
        for (offset, slot) in previousTail.enumerated() where start + offset < copy.count {
            copy[start + offset] = slot
        }
        return copy
    }

    private static func confirmBar(_ count: Int) -> String {
        "⚠ 还有 \(count) 处没处理（待确认 \(count)）。为了不拼错，处理完才能继续——不会静默拼接。"
    }

    private static func plantedImage(height: Int, seams: [Int]) -> RGBAImage {
        var slots = (0..<height).map { $0 + 100 }
        for seam in seams {
            slots[seam - 2] = 20 + seam
            slots[seam] = 20 + seam
            slots[seam - 1] = 21 + seam
            slots[seam + 1] = 21 + seam
        }
        return slotted(slots)
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

    private static func slotted(_ slots: [Int]) -> RGBAImage {
        let width = ScrollFixtures.width
        var pixels = [UInt8](repeating: 255, count: width * slots.count * 4)
        for (y, slot) in slots.enumerated() {
            let rgb = ScrollFixtures.color(slot: slot)
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = rgb[0]
                pixels[i + 1] = rgb[1]
                pixels[i + 2] = rgb[2]
            }
        }
        return RGBAImage(width: width, height: slots.count, pixels: pixels)
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
}
