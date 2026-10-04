import CoreGraphics
import Darwin
import ImageIO
import PrettyShotCore
import UIKit
import XCTest
@testable import PrettyShotIOS

final class HandoffStoreTests: XCTestCase {
    func testDirectoryRoundTripAndSafeNames() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sourceDir = tmp.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let photo = sourceDir.appendingPathComponent("shot.png")
        let manifestName = sourceDir.appendingPathComponent("manifest.json")
        try Data("png".utf8).write(to: photo)
        try Data("nope".utf8).write(to: manifestName)

        let store = DirectoryHandoffStore(root: tmp.appendingPathComponent("root", isDirectory: true))
        XCTAssertTrue(store.canTransferToApp)
        XCTAssertTrue(store.persistsAcrossProcesses)

        let ticket = try store.stage(copying: [photo, manifestName], kind: .stitch)
        XCTAssertEqual(ticket.kind, .stitch)
        XCTAssertEqual(ticket.fileNames, ["000-shot.png", "001.dat"])

        let again = DirectoryHandoffStore(root: store.root)
        let pending = try again.pendingTickets()
        XCTAssertEqual(pending.map(\.id), [ticket.id])
        let files = try again.files(for: ticket.id)
        XCTAssertEqual(try Data(contentsOf: files[0]), Data("png".utf8))
        XCTAssertEqual(try Data(contentsOf: files[1]), Data("nope".utf8))

        try again.discard(ticketID: ticket.id)
        XCTAssertTrue(try again.pendingTickets().isEmpty)
        XCTAssertThrowsError(try again.files(for: ticket.id)) { error in
            XCTAssertEqual(error as? HandoffError, .missingTicket)
        }
    }

    func testInlineStoreDoesNotCrossInstances() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("inline-\(UUID().uuidString).png")
        try Data("one".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let first = InlineHandoffStore()
        XCTAssertFalse(first.canTransferToApp)
        XCTAssertFalse(first.persistsAcrossProcesses)
        let ticket = try first.stage(copying: [file], kind: .singleImage)
        XCTAssertEqual(try first.pendingTickets().map(\.id), [ticket.id])

        let second = InlineHandoffStore()
        XCTAssertFalse(second.canTransferToApp)
        XCTAssertTrue(try second.pendingTickets().isEmpty)
    }

    func testFactoryModes() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let ignored = HandoffStoreFactory.make(mode: .inline, containerURL: container)
        XCTAssertFalse(ignored.canTransferToApp)
        XCTAssertFalse(ignored.persistsAcrossProcesses)

        let fallback = HandoffStoreFactory.make(mode: .appGroup, containerURL: nil)
        XCTAssertFalse(fallback.canTransferToApp)
        XCTAssertFalse(fallback.persistsAcrossProcesses)

        let shared = HandoffStoreFactory.make(mode: .appGroup, containerURL: container)
        XCTAssertTrue(shared.canTransferToApp)
        let file = container.appendingPathComponent("page.pdf")
        try Data("%PDF".utf8).write(to: file)
        let ticket = try shared.stage(copying: [file], kind: .pdf)
        let reread = DirectoryHandoffStore(root: container.appendingPathComponent("Handoff", isDirectory: true))
        XCTAssertEqual(try reread.pendingTickets().map(\.id), [ticket.id])
    }

    func testLiveStoreUsesInlineFlag() {
        XCTAssertTrue(HandoffStoreFactory.hasExplicitHandoffFlag)
        XCTAssertEqual(HandoffStoreFactory.compiledMode, .inline)
        XCTAssertEqual(HandoffStoreFactory.mode(in: .main), .inline)
        XCTAssertFalse(HandoffStoreFactory.live().canTransferToApp)
    }
}

final class SharePayloadTests: XCTestCase {
    func testRoutes() {
        XCTAssertEqual(SharePayloadParser.classify([]).route, .empty)
        XCTAssertEqual(SharePayloadParser.classify([item("public.text")]).route, .unreadable)
        XCTAssertEqual(SharePayloadParser.classify([item("public.jpeg")]).route, .singleImage(ignored: 0))
        XCTAssertEqual(
            SharePayloadParser.classify([item("public.jpeg"), item("public.plain-text")]).route,
            .singleImage(ignored: 1)
        )
        XCTAssertEqual(
            SharePayloadParser.classify([item("public.png"), item("public.heic")]).route,
            .stitch(images: 2, pdfs: 0, ignored: 0)
        )
        XCTAssertEqual(
            SharePayloadParser.classify([item("com.adobe.pdf")]).route,
            .stitch(images: 0, pdfs: 1, ignored: 0)
        )
        XCTAssertEqual(
            SharePayloadParser.classify([item("public.jpeg"), item("public.pdf")]).route,
            .stitch(images: 1, pdfs: 1, ignored: 0)
        )
    }

    private func item(_ uti: String) -> ShareAttachment {
        ShareAttachment(typeIdentifiers: [uti])
    }
}

final class StitchGateCopyTests: XCTestCase {
    func testPrimaryCountsOnlyItsOwnCategory() {
        let mixed = StitchGate.evaluate(assembly(
            unaligned: 2,
            duplicates: 3,
            sticky: true
        ))
        XCTAssertEqual(mixed.step, .seams(2))
        XCTAssertEqual(mixed.primaryTitle, "处理下一处 · 2")
        XCTAssertFalse(mixed.canAdvance)
        XCTAssertFalse(mixed.primaryTitle.contains("先确认"))
        XCTAssertFalse(mixed.primaryTitle.contains("先处理"))
        XCTAssertFalse(mixed.primaryTitle.contains("处理 1 处 · 固定栏待确认"))
        XCTAssertEqual(mixed.bottomBar, StitchCopy.bottomBar(mixedRemainder(unaligned: 2, duplicates: 3, sticky: true)))
        XCTAssertEqual(
            mixed.bottomBar,
            "⚠ 还有 6 处没处理（待对齐 2 · 待确认 3 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertEqual(mixed.overLimitPrompt.primaryTitle, StitchCopy.handleUnaligned(2))
        XCTAssertFalse(mixed.overLimitPrompt.primaryExports)
        XCTAssertFalse(mixed.overLimitPrompt.segmentExportEnabled)

        let seamsOnly = StitchGate.evaluate(assembly(unaligned: 2, duplicates: 0, sticky: false))
        XCTAssertEqual(seamsOnly.primaryTitle, "处理下一处 · 2")
        XCTAssertEqual(seamsOnly.bottomBar, StitchCopy.bottomBar(.init(unaligned: 2)))
        XCTAssertFalse(seamsOnly.bottomBar?.contains("待确认") ?? true)

        let sticky = StitchGate.evaluate(assembly(unaligned: 0, duplicates: 2, sticky: true))
        XCTAssertEqual(sticky.step, .sticky)
        XCTAssertEqual(sticky.primaryTitle, "处理下一处 · 1")
        XCTAssertFalse(sticky.primaryTitle.contains("先确认"))
        XCTAssertFalse(sticky.primaryTitle.contains("固定栏待确认"))
        XCTAssertEqual(sticky.bottomBar, StitchCopy.bottomBar(.init(pendingConfirm: 2, stickyPending: true)))

        let duplicates = StitchGate.evaluate(assembly(unaligned: 0, duplicates: 2, sticky: false))
        XCTAssertEqual(duplicates.step, .duplicates(2))
        XCTAssertEqual(duplicates.primaryTitle, "先确认 2 处重复段")

        let ready = StitchGate.evaluate(ScrollAssembly())
        XCTAssertEqual(ready.step, .ready)
        XCTAssertEqual(ready.primaryTitle, "下一步 · 美化")
        XCTAssertNil(ready.bottomBar)
        XCTAssertTrue(ready.canAdvance)
        XCTAssertEqual(ready.overLimitPrompt.primaryTitle, StitchCopy.exportSegments)
        XCTAssertTrue(ready.overLimitPrompt.primaryExports)
    }

    func testResolvingDuplicatesStepsTheGate() {
        var session = StitchSession(assembly: assembly(unaligned: 0, duplicates: 2, sticky: false))
        XCTAssertEqual(session.gate.primaryTitle, "先确认 2 处重复段")
        session.resolveDuplicate("dup-0", choice: .keepOnce)
        XCTAssertEqual(session.gate.primaryTitle, "先确认 1 处重复段")
        session.resolveDuplicate("dup-1", choice: .keepBoth)
        XCTAssertEqual(session.gate.step, .ready)
        XCTAssertTrue(session.gate.canAdvance)
        XCTAssertNil(session.gate.bottomBar)
    }

    func testAlignThenStickyUsesEachCategoryCount() {
        let image = RGBAImage(width: 4, height: 8, pixels: [UInt8](repeating: 255, count: 4 * 8 * 4))
        let segment = ScrollSegment(image: image, confidentSeamYs: [])
        var session = StitchSession(assembly: ScrollAssembly(
            segments: [segment, segment, segment],
            seams: [
                ScrollSeam(kind: .needsAlignment, suggestedOverlap: 2),
                ScrollSeam(kind: .needsAlignment, suggestedOverlap: 1),
            ],
            pendingSticky: PendingStickyConfirmation(headerRows: 2, footerRows: 0, seamCount: 2, keepOnce: nil)
        ))
        XCTAssertEqual(session.gate.primaryTitle, "处理下一处 · 2")
        session.align(seam: 0, overlap: 2)
        session.align(seam: 1, overlap: 1)
        XCTAssertEqual(session.gate.step, .sticky)
        XCTAssertEqual(session.gate.primaryTitle, IOSCopy.handleNext(1))
        session.confirmSticky(keepOnce: true)
        XCTAssertEqual(session.gate.step, .ready)
        XCTAssertEqual(session.gate.primaryTitle, IOSCopy.nextBeautify)
    }

    func testRestoreAutoRerunsDetection() {
        let image = RGBAImage(width: 4, height: 8, pixels: [UInt8](repeating: 255, count: 4 * 8 * 4))
        let segment = ScrollSegment(image: image, confidentSeamYs: [])
        var session = StitchSession(assembly: ScrollAssembly(
            segments: [segment, segment],
            seams: [ScrollSeam(kind: .aligned(overlap: 1), suggestedOverlap: 3)],
            duplicateCandidates: [DuplicateSegmentCandidate(id: "dup", choice: .keepOnce)]
        ))
        session.restoreAuto(seam: 0)
        XCTAssertEqual(session.assembly.seams.first?.kind, .aligned(overlap: 3))
        XCTAssertTrue(session.assembly.duplicateCandidates.isEmpty)
        XCTAssertEqual(session.gate.step, .ready)
        XCTAssertEqual(IOSCopy.reDetect, "还原自动")
        XCTAssertEqual(IOSCopy.alignDone, "完成")
    }

    func testRedetectCopyAndSeamNumbers() {
        XCTAssertEqual(
            IOSCopy.redetectToast(first: 2, second: 3, pending: 2),
            "第 2、3 张已对齐 · 重复段已重新识别，2 处待确认"
        )
        XCTAssertEqual(IOSCopy.seamMissTitle(seamIndex: 0), "第 1、2 张没对上")
        XCTAssertEqual(
            IOSCopy.duplicateSeamDetail(first: 1, second: 2),
            "第 1、2 张接缝处 · 程序判断不了是重叠还是本来就重复"
        )
        XCTAssertFalse(IOSCopy.redetectToast(first: 2, second: 3, pending: 2).contains("撤销"))
        XCTAssertEqual(IOSCopy.untrustedSeamTitle(seamIndex: 1), "第 2、3 张的位置无法唯一确定")
        XCTAssertEqual(IOSCopy.positionA(0), "位置 A · 0 pt · 当前")
        XCTAssertEqual(IOSCopy.positionB(delta: 22), "位置 B · +22 pt")
        XCTAssertEqual(IOSCopy.exportSeparate, "分开导出")
        XCTAssertEqual(IOSCopy.exportSeparateDetail, "不拼了，分别美化后存入相册")
        XCTAssertEqual(IOSCopy.confirmBlockedNote, "处理完所有「待确认」接缝前，不能进入下一步")
        XCTAssertEqual(IOSCopy.reselectInApp, "改用 PrettyShot App 选图")
        XCTAssertEqual(IOSCopy.handoffProgressTitle, "正在交给 PrettyShot…")
        XCTAssertTrue(IOSCopy.handoffProgressBody.contains("原图始终不动"))
        XCTAssertFalse(IOSCopy.handoffProgressBody.contains("预览尺寸"))
        XCTAssertEqual(IOSCopy.handoffFailedTitle, "没能交给 PrettyShot")
        XCTAssertEqual(IOSCopy.cannotHandTitle, "这张图没法从分享菜单直接交给 App")
        XCTAssertFalse(IOSCopy.cannotHandBody.contains("去 App 里处理"))
        XCTAssertFalse(IOSCopy.cannotHandBody.contains("预览尺寸"))
        XCTAssertEqual(IOSCopy.continuePartial(3), "用读出的 3 张继续")
        XCTAssertEqual(IOSCopy.missingBanner([3]), "少了 1 张 · 第 3 张没读出来")
        XCTAssertEqual(IOSCopy.missingEditorLine([3]), "这张长图少了 1 张（第 3 张没读出来）")
        XCTAssertEqual(IOSCopy.stagedTitle(3), "已暂存 3 张")
        XCTAssertEqual(IOSCopy.stagedBody, "打开 PrettyShot 即可继续拼接，图片不会丢。")
        XCTAssertEqual(IOSCopy.stagedHint, "打开 App 后，首页会出现「继续上次分享」")
        XCTAssertFalse(IOSCopy.largeBody.contains("样式"))
        XCTAssertFalse(IOSCopy.tooLongBody.contains("真机实测"))
        XCTAssertEqual(IOSCopy.addedBack(ordinal: 3, total: 4), "已加回第 3 张 · 4 张齐了")
        XCTAssertEqual(IOSCopy.memoryFailedTitle, "这张图片打不开")
        XCTAssertEqual(IOSCopy.readFailedOK, "好的")
        XCTAssertEqual(IOSCopy.continueInApp, "在 App 中继续")
    }

    private func assembly(unaligned: Int, duplicates: Int, sticky: Bool) -> ScrollAssembly {
        ScrollAssembly(
            seams: (0..<unaligned).map { _ in ScrollSeam(kind: .needsAlignment, suggestedOverlap: 4) },
            pendingSticky: sticky ? PendingStickyConfirmation(headerRows: 8, footerRows: 0, seamCount: max(unaligned, 1), keepOnce: nil) : nil,
            duplicateCandidates: (0..<duplicates).map { DuplicateSegmentCandidate(id: "dup-\($0)") }
        )
    }

    private func mixedRemainder(unaligned: Int, duplicates: Int, sticky: Bool) -> StitchCopy.Remainder {
        StitchCopy.Remainder(unaligned: unaligned, pendingConfirm: duplicates, stickyPending: sticky)
    }
}

final class ExtensionMemoryBudgetTests: XCTestCase {
    func testTwelveMegapixelStaysUnderTwoCopies() {
        let pixels = 12_000_000
        XCTAssertGreaterThan(
            ExtensionMemoryBudget.rgbaBytes(pixels: pixels, copies: ExtensionMemoryBudget.forbiddenSimultaneousFullSizeCopies),
            ExtensionMemoryBudget.limitBytes
        )
        XCTAssertLessThanOrEqual(
            ExtensionMemoryBudget.rgbaBytes(pixels: pixels, copies: 2),
            ExtensionMemoryBudget.limitBytes
        )
        let peak = ExtensionMemoryBudget.exportPeakBytes(sourcePixels: pixels, canvasPixels: pixels)
        XCTAssertEqual(ExtensionMemoryBudget.fullSizeCopiesWhileExporting, 5)
        XCTAssertGreaterThan(peak, ExtensionMemoryBudget.limitBytes)
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelWidth: 4000, pixelHeight: 3000, canTransferToApp: true), .handoffToApp)
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelWidth: 4000, pixelHeight: 3000, canTransferToApp: false), .reselectInApp)
    }

    func testLargerImageHandsOffOnlyWhenTransferExists() {
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelWidth: 5000, pixelHeight: 4000, canTransferToApp: true), .handoffToApp)
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelWidth: 5000, pixelHeight: 4000, canTransferToApp: false), .reselectInApp)
    }

    func testPreviewLongSideAndHeaderSize() throws {
        let count = ExtensionMemoryBudget.previewPixelCount(width: 4000, height: 3000)
        XCTAssertLessThanOrEqual(count, 1280 * 960)
        XCTAssertLessThan(ExtensionMemoryBudget.rgbaBytes(pixels: count, copies: 1), 8 * 1024 * 1024)

        let data = try png(width: 8, height: 4)
        XCTAssertEqual(ImagePrep.pixelSize(data)?.width, 8)
        XCTAssertEqual(ImagePrep.pixelSize(data)?.height, 4)
        let thumb = try XCTUnwrap(ImagePrep.downsample(data, maxLongSide: 4))
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), 4)
    }

    func testRealRenderPeakCountsFourBuffers() throws {
        let width = 640
        let height = 480
        let data = try png(width: width, height: height)
        let source = try XCTUnwrap(ImagePrep.fullImage(data))
        let redacted = Redactor.apply(
            [PixelRedaction(rect: CGRect(x: 8, y: 8, width: 40, height: 40))],
            to: source,
            scale: 1
        )
        let canvas = try XCTUnwrap(BeautifyRenderer.render(BeautifyInput(
            base: redacted,
            crop: CGRect(x: 0, y: 0, width: redacted.width, height: redacted.height),
            background: BackgroundStyle.default,
            scale: 1
        )))
        let alive = [source, redacted, canvas]
        XCTAssertEqual(alive.count, 3)
        XCTAssertEqual(redacted.width, width)
        XCTAssertEqual(redacted.height, height)
        XCTAssertGreaterThan(canvas.width, width)
        XCTAssertGreaterThan(canvas.height, height)
        XCTAssertGreaterThan(max(canvas.width, canvas.height), max(width, height))
        let shadowBytes = canvas.width * canvas.height * ExtensionMemoryBudget.bytesPerPixel
        let fifthBuffer = shadowBytes
        let measured = source.width * source.height * 4
            + redacted.width * redacted.height * 4
            + canvas.width * canvas.height * 4
            + shadowBytes
            + fifthBuffer
        // Five buffers under-count a 1320×2868 export by about 9.8MB once the
        // resident source is added back. The margin stays visible for (36).
        XCTAssertEqual(
            ExtensionMemoryBudget.exportPeakBytes(
                sourcePixels: width * height,
                canvasPixels: canvas.width * canvas.height
            ),
            measured + 12 * 1024 * 1024
        )
        XCTAssertGreaterThan(measured, ExtensionMemoryBudget.rgbaBytes(pixels: width * height, copies: 2))
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelWidth: 1290, pixelHeight: 20_000, canTransferToApp: true), .handoffToApp)
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelWidth: 1290, pixelHeight: 20_000, canTransferToApp: false), .reselectInApp)
        XCTAssertEqual(
            ExtensionMemoryBudget.plan(pixelWidth: 1179, pixelHeight: 2556, canTransferToApp: false),
            .fullResolutionInline
        )
    }

    /// Samples `phys_footprint` around a real render and PNG encode.
    /// About 7.5MP with redaction and shadow used to pass the old gate (canvas treated as the source, no headroom).
    func testPhysFootprintSamplesSevenAndTwelveMegapixelExports() throws {
        let seven = try footprintOfExport(width: 3000, height: 2500, redact: true)
        print("PRETTYSHOT_FOOTPRINT 7.5MP before=\(seven.before) afterRender=\(seven.afterRender) afterEncode=\(seven.afterEncode) deltaRender=\(seven.afterRender &- seven.before) deltaEncode=\(seven.afterEncode &- seven.before)")
        XCTAssertGreaterThan(seven.afterRender, seven.before)
        XCTAssertGreaterThan(seven.afterRender &- seven.before, 20 * 1024 * 1024)
        let canvas = ExtensionMemoryBudget.canvasPixelCount(width: 3000, height: 2500, scale: 1)
        XCTAssertGreaterThan(canvas, 3000 * 2500)
        let paddedPeak = ExtensionMemoryBudget.exportPeakBytes(sourcePixels: 3000 * 2500, canvasPixels: canvas)
        let oldPeak = ExtensionMemoryBudget.exportPeakBytes(sourcePixels: 3000 * 2500, canvasPixels: 3000 * 2500)
        XCTAssertGreaterThan(oldPeak, ExtensionMemoryBudget.limitBytes)
        XCTAssertGreaterThan(paddedPeak + ExtensionMemoryBudget.headroomBytes, ExtensionMemoryBudget.limitBytes)
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelWidth: 3000, pixelHeight: 2500, canTransferToApp: true, scale: 1), .handoffToApp)
        XCTAssertNotEqual(ExtensionMemoryBudget.plan(pixelWidth: 3000, pixelHeight: 2500, canTransferToApp: false, scale: 1), .fullResolutionInline)

        let twelve = try footprintOfExport(width: 4000, height: 3000, redact: false)
        print("PRETTYSHOT_FOOTPRINT 12MP before=\(twelve.before) afterRender=\(twelve.afterRender) afterEncode=\(twelve.afterEncode) deltaRender=\(twelve.afterRender &- twelve.before) deltaEncode=\(twelve.afterEncode &- twelve.before)")
        XCTAssertGreaterThan(twelve.afterRender, twelve.before)
        XCTAssertGreaterThan(twelve.afterRender &- twelve.before, 20 * 1024 * 1024)
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelWidth: 4000, pixelHeight: 3000, canTransferToApp: true), .handoffToApp)
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelWidth: 4000, pixelHeight: 3000, canTransferToApp: false), .reselectInApp)
        XCTAssertGreaterThan(twelve.encodedBytes, 100_000)
        XCTAssertGreaterThan(seven.encodedBytes, 100_000)
    }

    private struct FootprintSample {
        var before: UInt64
        var afterRender: UInt64
        var afterEncode: UInt64
        var encodedBytes: Int
    }

    private func footprintOfExport(width: Int, height: Int, redact: Bool) throws -> FootprintSample {
        let source = try solidImage(width: width, height: height)
        let before = physFootprint()
        let base: CGImage
        if redact {
            base = Redactor.apply(
                [PixelRedaction(rect: CGRect(x: 8, y: 8, width: 80, height: 80))],
                to: source,
                scale: 1
            )
        } else {
            base = source
        }
        let canvas = try XCTUnwrap(BeautifyRenderer.render(BeautifyInput(
            base: base,
            crop: CGRect(x: 0, y: 0, width: base.width, height: base.height),
            background: BackgroundStyle.default,
            scale: 1
        )))
        let afterRender = physFootprint()
        let encoded = try XCTUnwrap(ShotEncoder.pngData(canvas))
        let afterEncode = physFootprint()
        XCTAssertEqual(source.width, width)
        XCTAssertEqual(canvas.width, width + Int((BackgroundStyle.default.padding * 2).rounded()))
        withExtendedLifetime(base) {}
        withExtendedLifetime(encoded) {}
        return FootprintSample(before: before, afterRender: afterRender, afterEncode: afterEncode, encodedBytes: encoded.count)
    }

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for y in stride(from: 0, to: height, by: 64) {
            let shade = CGFloat(y) / CGFloat(height)
            context.setFillColor(CGColor(srgbRed: shade, green: 0.3, blue: 1 - shade, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 64))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    /// Default padding stays inside the extension. Padding 64 on the same pixels must hand off.
    /// 1830×1830 is just under the gate at padding 28 once the 12MB render margin is counted,
    /// and over it at padding 64 (scale 1, plus 40MB headroom).
    func testLargePaddingHandsOffWhileDefaultStaysInTheExtension() throws {
        let width = 1830
        let height = 1830
        XCTAssertEqual(
            ExtensionMemoryBudget.plan(pixelWidth: width, pixelHeight: height, canTransferToApp: true),
            .fullResolutionInline
        )
        let wide = BackgroundStyle(presetKey: "pastel-air", padding: 64, radius: 12, shadow: 48)
        XCTAssertEqual(
            ExtensionMemoryBudget.plan(pixelWidth: width, pixelHeight: height, canTransferToApp: true, style: wide),
            .handoffToApp
        )
        let model = EditorModel()
        model.load(try png(width: width, height: height))
        model.removeStatusBar = false
        model.style = wide
        let attempt = try XCTUnwrap(model.export(canTransferToApp: true))
        guard case .handoff = attempt else {
            XCTFail("export must use the current padding, got \(attempt)")
            return
        }
    }

    /// 1320×2868 at the default style is over the 5-buffer gate, so it hands off to the app.
    /// The sample is the current `phys_footprint` during the render, not the lifetime ledger peak.
    func testInsideGateScreenshotStaysInTheExtension() throws {
        let width = 1320
        let height = 2868
        XCTAssertEqual(
            ExtensionMemoryBudget.plan(pixelWidth: width, pixelHeight: height, canTransferToApp: true),
            .handoffToApp
        )
        XCTAssertEqual(
            ExtensionMemoryBudget.plan(pixelWidth: width, pixelHeight: height, canTransferToApp: false),
            .reselectInApp
        )
        let sourcePixels = width * height
        let canvasPixels = ExtensionMemoryBudget.canvasPixelCount(width: width, height: height, scale: 3)
        let exportPeak = ExtensionMemoryBudget.exportPeakBytes(sourcePixels: sourcePixels, canvasPixels: canvasPixels)
        XCTAssertGreaterThan(exportPeak + ExtensionMemoryBudget.headroomBytes, ExtensionMemoryBudget.limitBytes)
        let source = try solidImage(width: width, height: height)
        let before = FootprintSampler.current()
        let sampler = FootprintSampler()
        sampler.start()
        let redacted = Redactor.apply(
            [PixelRedaction(rect: CGRect(x: 40, y: 200, width: 120, height: 80))],
            to: source,
            scale: 3
        )
        let canvas = try XCTUnwrap(BeautifyRenderer.render(BeautifyInput(
            base: redacted,
            crop: CGRect(x: 0, y: 0, width: redacted.width, height: redacted.height),
            background: BackgroundStyle.default,
            scale: 3
        )))
        let encoded = try XCTUnwrap(ShotEncoder.pngData(canvas))
        let during = sampler.stop()
        let delta = during - before
        let residentSource = Int64(sourcePixels * ExtensionMemoryBudget.bytesPerPixel)
        let sameBasis = delta + residentSource
        print("PRETTYSHOT_RENDER_DELTA 1320x2868 before=\(before) during=\(during) delta=\(delta) residentSource=\(residentSource) sameBasis=\(sameBasis) exportPeak=\(exportPeak) margin=\(Int64(exportPeak) - sameBasis) encodedBytes=\(encoded.count)")
        XCTAssertGreaterThan(delta, 0)
        XCTAssertLessThanOrEqual(delta, Int64(exportPeak))
        XCTAssertLessThanOrEqual(sameBasis, Int64(exportPeak))
        XCTAssertGreaterThan(encoded.count, 100_000)
        XCTAssertEqual(source.width, width)
        XCTAssertEqual(redacted.width, width)

        let fitWidth = 1179
        let fitHeight = 2556
        XCTAssertEqual(
            ExtensionMemoryBudget.plan(pixelWidth: fitWidth, pixelHeight: fitHeight, canTransferToApp: true),
            .fullResolutionInline
        )
        let fitSource = try solidImage(width: fitWidth, height: fitHeight)
        let fitBefore = FootprintSampler.current()
        let fitSampler = FootprintSampler()
        fitSampler.start()
        let fitRedacted = Redactor.apply(
            [PixelRedaction(rect: CGRect(x: 20, y: 80, width: 40, height: 24))],
            to: fitSource,
            scale: 3
        )
        let fitCanvas = try XCTUnwrap(BeautifyRenderer.render(BeautifyInput(
            base: fitRedacted,
            crop: CGRect(x: 0, y: 0, width: fitRedacted.width, height: fitRedacted.height),
            background: BackgroundStyle.default,
            scale: 3
        )))
        _ = try XCTUnwrap(ShotEncoder.pngData(fitCanvas))
        let fitDuring = fitSampler.stop()
        let fitDelta = fitDuring - fitBefore
        let fitSourceBytes = fitWidth * fitHeight * ExtensionMemoryBudget.bytesPerPixel
        let fitPeak = ExtensionMemoryBudget.exportPeakBytes(
            sourcePixels: fitWidth * fitHeight,
            canvasPixels: ExtensionMemoryBudget.canvasPixelCount(width: fitWidth, height: fitHeight, scale: 3)
        )
        let fitSameBasis = fitDelta + Int64(fitSourceBytes)
        print("PRETTYSHOT_RENDER_DELTA 1179x2556 before=\(fitBefore) during=\(fitDuring) delta=\(fitDelta) residentSource=\(fitSourceBytes) sameBasis=\(fitSameBasis) exportPeak=\(fitPeak) margin=\(Int64(fitPeak) - fitSameBasis)")
        XCTAssertGreaterThan(fitDelta, 0)
        XCTAssertLessThanOrEqual(fitDelta, Int64(fitPeak))
        XCTAssertLessThanOrEqual(
            ExtensionMemoryBudget.headroomBytes + fitSourceBytes + Int(fitDelta),
            ExtensionMemoryBudget.limitBytes
        )
    }

    /// (36) Redaction keeps one full-size buffer. Drawing the source through Core Graphics also left
    /// a cached full-size copy attached to the source for as long as the source lived.
    func testRedactionHoldsOneFullSizeBuffer() throws {
        // Core Image setup happens on first use. Do it here so test order does not matter.
        _ = Redactor.apply([PixelRedaction(rect: CGRect(x: 0, y: 0, width: 8, height: 8))], to: try solidImage(width: 16, height: 16), scale: 1)
        let width = 1320
        let height = 2868
        let source = try solidImage(width: width, height: height)
        let sourceBytes = Int64(width * height * ExtensionMemoryBudget.bytesPerPixel)
        let slack = Int64(2 * 1024 * 1024)
        // A `makeImage()` source is only charged to this process once its pixels are first touched
        // (CI run 37167419555: 0.05MB after makeImage, +15.1MB on first draw, back to 0 when released;
        // asking for the provider's length does not touch them). Touch every page before sampling,
        // so the numbers below are what redaction itself holds.
        let pixels = try XCTUnwrap(source.dataProvider?.data)
        XCTAssertGreaterThanOrEqual(CFDataGetLength(pixels), Int(sourceBytes))
        let pixelBytes = try XCTUnwrap(CFDataGetBytePtr(pixels))
        var touched = 0
        for offset in stride(from: 0, to: CFDataGetLength(pixels), by: 4096) {
            touched &+= Int(pixelBytes[offset])
        }
        XCTAssertGreaterThanOrEqual(touched, 0)
        let before = FootprintSampler.current()
        let sampler = FootprintSampler()
        sampler.start()
        var redacted: CGImage? = Redactor.apply(
            [PixelRedaction(rect: CGRect(x: 40, y: 200, width: 120, height: 80))],
            to: source,
            scale: 3
        )
        let peak = sampler.stop() - before
        XCTAssertEqual(redacted?.width, width)
        XCTAssertEqual(redacted?.height, height)
        redacted = nil
        let retained = FootprintSampler.current() - before
        print("PRETTYSHOT_REDACT_PEAK 1320x2868 peak=\(peak) retained=\(retained) sourceBytes=\(sourceBytes)")
        XCTAssertLessThanOrEqual(peak, sourceBytes + slack)
        XCTAssertLessThanOrEqual(retained, slack)
        withExtendedLifetime(source) {}
    }

    private final class FootprintSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = false
        private var high = Int64.min

        func start() {
            high = Self.current()
            lock.lock()
            running = true
            lock.unlock()
            Thread.detachNewThread { [weak self] in
                while let self {
                    self.lock.lock()
                    let still = self.running
                    self.lock.unlock()
                    if !still { break }
                    let sample = Self.current()
                    self.lock.lock()
                    if sample > self.high { self.high = sample }
                    self.lock.unlock()
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        }

        func stop() -> Int64 {
            lock.lock()
            running = false
            let value = high
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
            lock.lock()
            let latest = high
            lock.unlock()
            return max(value, latest)
        }

        static func current() -> Int64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            return Int64(info.phys_footprint)
        }
    }

    private func ledgerPhysFootprintPeak() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.ledger_phys_footprint_peak
    }

    private func png(width: Int, height: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

final class StatusBarAndPhotoRouteTests: XCTestCase {
    func testKnownPortraitCropsAndUnknownSizesDoNot() {
        let crop = StatusBarCropTable.match(width: 1179, height: 2556)
        XCTAssertEqual(crop?.topPixels, 162)
        let rect = crop?.cropRect(width: 1179, height: 2556)
        XCTAssertEqual(rect?.origin.y, 162)
        XCTAssertEqual(rect?.height, 2394)
        XCTAssertNil(StatusBarCropTable.match(width: 1178, height: 2556))
        XCTAssertNil(StatusBarCropTable.match(width: 2556, height: 1179))
    }

    func testPhotoSaveRoutes() {
        XCTAssertEqual(PhotoSaveRouter.route(for: .notDetermined), .requestThenSave)
        XCTAssertEqual(PhotoSaveRouter.route(for: .authorized), .save)
        XCTAssertEqual(PhotoSaveRouter.route(for: .denied), .offerCopy)
    }
}

final class ShareAcceptanceTests: XCTestCase {
    func testInlineHandoffRoundTripKeepsPixels() throws {
        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try patternedPNG(width: 6, height: 4, directory: tmp)
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let receipt = HandoffTransfer.persist(copying: [source.url], kind: .singleImage, store: store)
        guard case .waitingForApp(let ticket) = receipt else {
            XCTFail("expected a stored ticket, got \(receipt)")
            return
        }
        let stagedURL = try store.files(for: ticket.id)[0]
        let staged = try Data(contentsOf: stagedURL)
        XCTAssertEqual(staged, source.png)
        XCTAssertEqual(try rgba(of: staged), try rgba(of: source.png))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.path))
    }

    func testInterruptedHandoffStaysUntilTheAppConfirms() throws {
        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try patternedPNG(width: 4, height: 3, directory: tmp)
        let root = tmp.appendingPathComponent("inbox", isDirectory: true)
        let store = InlineHandoffStore(root: root)
        let receipt = HandoffTransfer.persist(copying: [source.url], kind: .singleImage, store: store)
        guard case .waitingForApp(let ticket) = receipt else {
            XCTFail("expected a stored ticket")
            return
        }

        let opened = HandoffTransfer.resolveOpen(succeeded: true, ticket: ticket, store: store)
        guard case .waitingForApp = opened else {
            XCTFail("a successful open still waits for the app to confirm")
            return
        }
        XCTAssertEqual(try store.pendingTickets().map(\.id), [ticket.id])

        let interrupted = HandoffTransfer.resolveOpen(succeeded: false, ticket: ticket, store: store)
        guard case .interrupted(let same) = interrupted else {
            XCTFail("expected a retryable interrupt, got \(interrupted)")
            return
        }
        let reopened = InlineHandoffStore(root: root)
        let recovered = try Data(contentsOf: try reopened.files(for: same.id)[0])
        XCTAssertEqual(recovered, source.png)
        XCTAssertEqual(try rgba(of: recovered), try rgba(of: source.png))

        try reopened.confirmReceipt(ticketID: same.id)
        XCTAssertTrue(try reopened.pendingTickets().isEmpty)
    }

    func testUnreadableSourceFailsWithoutDeletingTheOriginal() throws {
        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try patternedPNG(width: 2, height: 2, directory: tmp)
        let missing = tmp.appendingPathComponent("missing.png")
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let receipt = HandoffTransfer.persist(copying: [source.url, missing], kind: .stitch, store: store)
        XCTAssertEqual(receipt, .failed(.unreadable))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.path))
        XCTAssertEqual(try Data(contentsOf: source.url), source.png)
        XCTAssertTrue(try store.pendingTickets().isEmpty)
    }

    func testTwelveMegapixelPathDoesNotDecodeUntilExport() throws {
        let pixels = 12_000_000
        XCTAssertEqual(
            ExportFidelityRouter.decide(pixelWidth: 4000, pixelHeight: 3000, canTransferToApp: false),
            .reselectInApp
        )
        XCTAssertEqual(
            ExportFidelityRouter.decide(pixelWidth: 4000, pixelHeight: 3000, canTransferToApp: true),
            .handOffOriginal
        )
        XCTAssertEqual(
            ExportFidelityRouter.decide(pixelWidth: 5000, pixelHeight: 4000, canTransferToApp: false),
            .reselectInApp
        )
        XCTAssertEqual(
            ExportFidelityRouter.decide(pixelWidth: 5000, pixelHeight: 4000, canTransferToApp: true),
            .handOffOriginal
        )

        let previewPixels = ExtensionMemoryBudget.previewPixelCount(width: 4000, height: 3000)
        let editing = ExtensionMemoryBudget.inlineEditingHold(pixelCount: pixels, previewPixels: previewPixels)
        XCTAssertEqual(editing.fullDecodedCopies, 0)
        XCTAssertTrue(editing.passesFileWithoutDecode)
        XCTAssertLessThanOrEqual(editing.estimatedBytes, ExtensionMemoryBudget.limitBytes)

        let exporting = ExtensionMemoryBudget.fullExportHold(pixelCount: pixels)
        XCTAssertEqual(exporting.fullDecodedCopies, 4)
        XCTAssertGreaterThan(exporting.estimatedBytes, ExtensionMemoryBudget.limitBytes)
        XCTAssertGreaterThan(
            ExtensionMemoryBudget.rgbaBytes(pixels: pixels, copies: ExtensionMemoryBudget.forbiddenSimultaneousFullSizeCopies),
            ExtensionMemoryBudget.limitBytes
        )

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = try solidPNG(width: 2400, height: 1600, directory: tmp)
        let carrier = try ShareImageCarrier(fileURL: url)
        XCTAssertEqual(carrier.fullDecodedCopiesHeld, 0)
        XCTAssertEqual(carrier.pixelWidth, 2400)
        XCTAssertEqual(carrier.pixelHeight, 1600)
        let preview = try XCTUnwrap(carrier.preview())
        XCTAssertLessThanOrEqual(max(preview.width, preview.height), ExtensionMemoryBudget.previewMaxLongSide)
        XCTAssertLessThan(preview.width * preview.height, 2400 * 1600)

        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let receipt = HandoffTransfer.persist(copying: [carrier.fileURL], kind: .singleImage, store: store)
        guard case .waitingForApp(let ticket) = receipt else {
            XCTFail("expected the file to be copied")
            return
        }
        XCTAssertEqual(try Data(contentsOf: try store.files(for: ticket.id)[0]), try Data(contentsOf: url))
        XCTAssertEqual(carrier.fullDecodedCopiesHeld, 0)
    }

    func testStitchInputAndExportKeepSourcePixelSize() throws {
        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let width = 1800
        let height = 40
        let data = try patternedPNG(width: width, height: height, directory: tmp).png
        let stitched = StitchSourceLoader.images(from: [data])
        XCTAssertEqual(stitched.count, 1)
        XCTAssertEqual(stitched.first?.width, width)
        XCTAssertEqual(stitched.first?.height, height)

        let full = try XCTUnwrap(ImagePrep.fullImage(data))
        XCTAssertEqual(full.width, width)
        XCTAssertEqual(full.height, height)
        let preview = try XCTUnwrap(ImagePrep.downsample(data, maxLongSide: ExtensionMemoryBudget.previewMaxLongSide))
        XCTAssertLessThanOrEqual(max(preview.width, preview.height), ExtensionMemoryBudget.previewMaxLongSide)
        XCTAssertLessThan(max(preview.width, preview.height), width)

        let model = EditorModel()
        model.load(data)
        model.removeStatusBar = false
        let exported = try XCTUnwrap(model.exportOriginalResolution())
        let padding = Int((model.style.padding * 2).rounded())
        XCTAssertEqual(exported.width, width + padding)
        XCTAssertEqual(exported.height, height + padding)
        XCTAssertGreaterThanOrEqual(exported.width, width)
        XCTAssertGreaterThanOrEqual(exported.height, height)

        let attempt = try XCTUnwrap(model.export(canTransferToApp: false))
        guard case .image(let inline) = attempt else {
            XCTFail("a source under the extension budget exports full resolution, got \(attempt)")
            return
        }
        XCTAssertEqual(inline.width, width + padding)
        XCTAssertEqual(inline.height, height + padding)
        XCTAssertGreaterThan(inline.width, 1280)
    }

    func testAbortClearsStagingAndLeavesTheSource() throws {
        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try patternedPNG(width: 5, height: 4, directory: tmp)
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let receipt = HandoffTransfer.persist(copying: [source.url], kind: .singleImage, store: store)
        guard case .waitingForApp(let ticket) = receipt else {
            XCTFail("expected a ticket")
            return
        }
        HandoffCancellation.abort(ticketID: ticket.id, store: store)
        XCTAssertTrue(try store.pendingTickets().isEmpty)
        XCTAssertEqual(try Data(contentsOf: source.url), source.png)
    }

    func testPartialGatherOrdersTheReplacementByCaptureTime() throws {
        let gathered = ShareFileGather.gather([
            (ordinal: 1, url: URL(fileURLWithPath: "/a")),
            (ordinal: 2, url: nil),
            (ordinal: 3, url: URL(fileURLWithPath: "/c")),
            (ordinal: 4, url: URL(fileURLWithPath: "/d")),
        ])
        XCTAssertEqual(gathered.missingOrdinals, [2])
        XCTAssertEqual(gathered.loadedCount, 3)
        let early = Date(timeIntervalSince1970: 10)
        let mid = Date(timeIntervalSince1970: 20)
        let late = Date(timeIntervalSince1970: 30)
        let placed = ShotOrdering.inserting(
            OrderedShot(id: "new", capturedAt: mid),
            into: [
                OrderedShot(id: "a", capturedAt: early),
                OrderedShot(id: "c", capturedAt: late),
            ],
            missingOrdinal: 2
        )
        XCTAssertEqual(placed.map(\.id), ["a", "new", "c"])

        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try patternedPNG(width: 3, height: 3, directory: tmp)
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let receipt = HandoffTransfer.persist(
            copying: [source.url],
            kind: .stitch,
            store: store,
            missingShots: [MissingShot(ordinal: 3)]
        )
        guard case .waitingForApp(let ticket) = receipt else {
            XCTFail("expected a ticket")
            return
        }
        let again = InlineHandoffStore(root: store.root)
        XCTAssertEqual(try again.pendingTickets().first?.missingShots, [MissingShot(ordinal: 3)])
        try again.confirmReceipt(ticketID: ticket.id)
        XCTAssertTrue(try again.pendingTickets().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.url.path))
    }

    func testStagedOpenFailureShowsManualResumeNotStagingFailure() throws {
        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try patternedPNG(width: 4, height: 3, directory: tmp)
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let receipt = HandoffTransfer.persist(copying: [source.url, source.url, source.url], kind: .stitch, store: store)
        guard case .waitingForApp(let ticket) = receipt else {
            XCTFail("expected a staged ticket")
            return
        }
        let outcome = ExtensionLaunchRouter.afterHandoffOpen(succeeded: false, ticket: ticket, store: store)
        XCTAssertEqual(outcome, .stagedNeedsManualOpen(count: 3))
        XCTAssertEqual(try store.pendingTickets().map(\.id), [ticket.id])
        XCTAssertNotEqual(outcome, .stagingFailed)
        try store.confirmReceipt(ticketID: ticket.id)
        XCTAssertEqual(
            ExtensionLaunchRouter.afterHandoffOpen(succeeded: false, ticket: ticket, store: store),
            .stagingFailed
        )
    }

    func testPickerOpenFailureStaysOnReselectAndDoesNotLoop() {
        XCTAssertEqual(ExtensionLaunchRouter.afterPickerOpen(succeeded: false), .stayAndAskToOpenApp)
        XCTAssertEqual(ExtensionLaunchRouter.afterPickerOpen(succeeded: true), .opened)
        let stayed = ExtensionLaunchRouter.afterPickerOpen(succeeded: false)
        XCTAssertEqual(stayed, .stayAndAskToOpenApp)
        XCTAssertNotEqual(ExtensionLaunchRouter.afterPickerOpen(succeeded: false), .opened)
    }

    func testRetryAbortsPreviousTicketBeforeStagingAnother() throws {
        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try patternedPNG(width: 4, height: 3, directory: tmp)
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let first = HandoffTransfer.persist(copying: [source.url], kind: .stitch, store: store)
        guard case .waitingForApp(let previous) = first else {
            XCTFail("expected the first ticket")
            return
        }
        ExtensionLaunchRouter.prepareRetry(previousTicketID: previous.id, store: store)
        XCTAssertTrue(try store.pendingTickets().isEmpty)
        let second = HandoffTransfer.persist(copying: [source.url, source.url], kind: .stitch, store: store)
        guard case .waitingForApp(let next) = second else {
            XCTFail("expected the replacement ticket")
            return
        }
        let pending = try store.pendingTickets()
        XCTAssertEqual(pending.map(\.id), [next.id])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(next.fileNames.count, 2)
    }

    func testResumeBannerCountsThisAttemptAndClearsAfterConfirm() throws {
        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source = try patternedPNG(width: 3, height: 2, directory: tmp)
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        _ = HandoffTransfer.persist(
            copying: [source.url],
            kind: .stitch,
            store: store,
            missingShots: [MissingShot(ordinal: 2)]
        )
        let latest = HandoffTransfer.persist(copying: [source.url, source.url, source.url], kind: .stitch, store: store)
        guard case .waitingForApp(let ticket) = latest else {
            XCTFail("expected the ticket this attempt staged")
            return
        }
        let pending = try store.pendingTickets()
        XCTAssertEqual(PendingShareResume.ticket(pending)?.id, ticket.id)
        XCTAssertEqual(PendingShareResume.stagedFileCount(pending), 4)
        let summed = pending.reduce(0) { $0 + $1.fileNames.count + $1.missingShots.count }
        XCTAssertGreaterThan(summed, 3)
        try store.confirmReceipt(ticketID: ticket.id)
        let left = try store.pendingTickets()
        XCTAssertFalse(left.contains { $0.id == ticket.id })
        XCTAssertEqual(PendingShareResume.stagedFileCount(left), 1)
        try store.confirmReceipt(ticketID: try XCTUnwrap(left.first).id)
        XCTAssertTrue(try store.pendingTickets().isEmpty)
        XCTAssertEqual(PendingShareResume.stagedFileCount([]), 0)
    }

    func testMissingBannerListsEveryOrdinalAndStaysUntilAllReturn() {
        XCTAssertEqual(IOSCopy.missingBanner([2, 4]), "少了 2 张 · 第 2 张、第 4 张没读出来")
        XCTAssertEqual(IOSCopy.missingEditorLine([2, 4]), "这张长图少了 2 张（第 2 张、第 4 张没读出来）")
        let session = MissingShotSession.remember(failedOrdinals: [4, 2], loadedCount: 2)
        XCTAssertEqual(session.ordinals, [2, 4])
        let once = session.addingBackOne()
        XCTAssertEqual(once.restored, 2)
        XCTAssertEqual(once.session.ordinals, [4])
        XCTAssertFalse(once.session.ordinals.isEmpty)
        let twice = once.session.addingBackOne()
        XCTAssertEqual(twice.restored, 4)
        XCTAssertTrue(twice.session.ordinals.isEmpty)
    }

    func testInAppStitchDoesNotDropUnreadableImages() throws {
        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let good = try patternedPNG(width: 8, height: 6, directory: tmp).png
        let loaded = StitchSourceLoader.load([good, Data("nope".utf8), good])
        XCTAssertEqual(loaded.images.count, 2)
        XCTAssertEqual(loaded.missingOrdinals, [2])
        XCTAssertEqual(loaded.images.first?.width, 8)
        XCTAssertEqual(InAppStitchLoader.outcome(readableCount: 2, failedOrdinals: [2]), .missing(ordinals: [2]))
        XCTAssertEqual(InAppStitchLoader.outcome(readableCount: 1, failedOrdinals: [2]), .failed)
        XCTAssertEqual(InAppStitchLoader.outcome(readableCount: 0, failedOrdinals: [1, 2]), .failed)
        XCTAssertEqual(InAppStitchLoader.outcome(readableCount: 3, failedOrdinals: []), .ready)
    }

    func testNewPickClearsPreviousMissingShots() {
        let previous = MissingShotSession.remember(failedOrdinals: [2, 5], loadedCount: 1)
        let cleared = MissingShotSession.beginNewPick(replacing: previous, failedOrdinals: [], loadedCount: 2)
        XCTAssertEqual(cleared.ordinals, [])
        XCTAssertFalse(cleared.ordinals.contains(2))
        XCTAssertFalse(cleared.ordinals.contains(5))
        let thisPick = MissingShotSession.beginNewPick(replacing: previous, failedOrdinals: [1], loadedCount: 2)
        XCTAssertEqual(thisPick.ordinals, [1])
    }

    func testExtensionPhotoDeniedOmitsSettingsWhileAppKeepsIt() {
        XCTAssertEqual(PhotoDeniedAction.actions(inApp: false), [.useCopyInstead, .later])
        XCTAssertFalse(PhotoDeniedAction.actions(inApp: false).contains(.openSettings))
        XCTAssertEqual(PhotoDeniedAction.actions(inApp: true), [.useCopyInstead, .openSettings, .later])
        XCTAssertEqual(IOSCopy.deniedPath, "设置 › PrettyShot › 照片 › 仅添加照片")
        XCTAssertFalse(IOSCopy.tooLongBody.contains("iOS 具体数值"))
        XCTAssertTrue(IOSCopy.largeBody.contains("在分享菜单里按原分辨率导出可能内存不足"))
        XCTAssertFalse(IOSCopy.largeBody.contains("样式会一起带过去"))
    }

    func testDownsampleChipOnlyOnOverBudgetExtensionImages() {
        XCTAssertFalse(PreviewDownsampleChip.shows(inExtension: false, pixelWidth: 4000, pixelHeight: 3000, canTransferToApp: true))
        XCTAssertFalse(PreviewDownsampleChip.shows(inExtension: true, pixelWidth: 1179, pixelHeight: 2556, canTransferToApp: false))
        XCTAssertTrue(PreviewDownsampleChip.shows(inExtension: true, pixelWidth: 4000, pixelHeight: 3000, canTransferToApp: true))
        XCTAssertTrue(PreviewDownsampleChip.shows(inExtension: true, pixelWidth: 3000, pixelHeight: 2500, canTransferToApp: false))
    }

    func testSeparateExportBeautifiesBeforeSaving() throws {
        let tmp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let shot = try patternedPNG(width: 40, height: 20, directory: tmp)
        let raw = try XCTUnwrap(ImagePrep.fullImage(shot.png))
        let styled = try XCTUnwrap(SegmentBeautifier.beautify(raw, style: .default, scale: 1))
        let padding = Int((BackgroundStyle.default.padding * 2).rounded())
        XCTAssertEqual(styled.width, 40 + padding)
        XCTAssertEqual(styled.height, 20 + padding)
        XCTAssertGreaterThan(styled.width, raw.width)
        XCTAssertGreaterThan(styled.height, raw.height)
    }

    func testTwoSharesMergeInShareOrder() throws {
        let pending = try stageShares([2, 1])
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(PendingShareResume.stagedFileCount(pending), 3)
        XCTAssertEqual(IOSCopy.handoffBannerDetail(for: pending), "已暂存 3 张 · 来自 2 次分享")
        let ordered = pending.sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(ordered.map(\.fileNames.count), [2, 1])
    }

    func testThreeSharesMergeInShareOrder() throws {
        let pending = try stageShares([1, 2, 3])
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(PendingShareResume.stagedFileCount(pending), 6)
        XCTAssertEqual(IOSCopy.handoffBannerDetail(for: pending), "已暂存 6 张 · 来自 3 次分享")
        let ordered = pending.sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(ordered.map(\.fileNames.count), [1, 2, 3])
    }

    func testOneShareBannerOmitsTheShareCount() {
        XCTAssertEqual(IOSCopy.handoffBannerDetail(count: 4), "已暂存 4 张")
        XCTAssertFalse(IOSCopy.handoffBannerDetail(count: 4).contains("次分享"))
    }

    /// Share 1 is 4 images with #3 missing. Share 2 is 3 images with #2 missing.
    /// The banner must say 第 3 张、第 6 张, not the per-share numbers 第 2 张、第 3 张.
    func testMissingOrdinalsOffsetByEarlierShareCounts() throws {
        let pending = try stageSharesWithMissing(files: [3, 2], missing: [[3], [2]])
        let missing = pending.flatMap { $0.missingShots.map(\.ordinal) }.sorted()
        XCTAssertEqual(missing, [3, 6])
        XCTAssertEqual(IOSCopy.missingBanner(missing), "少了 2 张 · 第 3 张、第 6 张没读出来")
    }

    /// Both shares are missing their own #2. That must not become 「第 2 张、第 2 张」.
    /// Putting the second share's image back lands between the global neighbors, not at the end.
    func testBothSharesMissingTheirSecondImageUseGlobalOrdinals() throws {
        let pending = try stageSharesWithMissing(files: [3, 2], missing: [[2], [2]])
        let missing = pending.flatMap { $0.missingShots.map(\.ordinal) }.sorted()
        XCTAssertEqual(missing, [2, 6])
        XCTAssertEqual(Set(missing).count, missing.count)
        XCTAssertEqual(IOSCopy.missingBanner(missing), "少了 2 张 · 第 2 张、第 6 张没读出来")
        XCTAssertFalse(IOSCopy.missingBanner(missing).contains("第 2 张、第 2 张"))
        let placed = ShotOrdering.inserting(
            OrderedShot(id: "6", capturedAt: nil),
            into: [
                OrderedShot(id: "1", capturedAt: nil),
                OrderedShot(id: "3", capturedAt: nil),
                OrderedShot(id: "4", capturedAt: nil),
                OrderedShot(id: "5", capturedAt: nil),
                OrderedShot(id: "7", capturedAt: nil),
            ],
            missingOrdinal: 6
        )
        XCTAssertEqual(placed.map(\.id), ["1", "3", "4", "5", "6", "7"])
    }

    /// Two shares both missing their own #2. Putting one back must leave the other.
    func testReaddingOneOfTwoMissingNumberTwosClearsOnlyThatOne() {
        let session = MissingShotSession(ordinals: [2, 2], expectedTotal: 7)
        let step = session.addingBack(ordinal: 2)
        XCTAssertEqual(step.restored, 2)
        XCTAssertEqual(step.session.ordinals, [2])
        XCTAssertEqual(step.session.ordinals.count, 1)
    }

    /// Missing 2 and 4. Putting 4 back, then 2, restores 1…5. Capture time must not reshuffle them.
    func testReaddFourThenTwoRestoresOneThroughFive() {
        let present = [
            OrderedShot(id: "1", capturedAt: nil),
            OrderedShot(id: "3", capturedAt: nil),
            OrderedShot(id: "5", capturedAt: nil),
        ]
        let after4 = ShotOrdering.inserting(
            OrderedShot(id: "4", capturedAt: nil),
            into: present,
            missingOrdinal: 4
        )
        XCTAssertEqual(after4.map(\.id), ["1", "3", "4", "5"])
        let after2 = ShotOrdering.inserting(
            OrderedShot(id: "2", capturedAt: nil),
            into: after4,
            missingOrdinal: 2
        )
        XCTAssertEqual(after2.map(\.id), ["1", "2", "3", "4", "5"])
    }

    func testReaddDoesNotResortWhenCaptureTimesArePresent() {
        let early = Date(timeIntervalSince1970: 10)
        let mid = Date(timeIntervalSince1970: 20)
        let late = Date(timeIntervalSince1970: 30)
        let placed = ShotOrdering.inserting(
            OrderedShot(id: "4", capturedAt: early),
            into: [
                OrderedShot(id: "5", capturedAt: mid),
                OrderedShot(id: "1", capturedAt: late),
                OrderedShot(id: "3", capturedAt: late),
            ],
            missingOrdinal: 4
        )
        XCTAssertEqual(placed.map(\.id), ["5", "1", "3", "4"])
    }

    func testSingleAndMultiSharesMergeInShareOrder() throws {
        let tmp = try makeTemp()
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let first = try writePNG(bytes: [1, 2, 3, 4], directory: tmp, name: "one.png")
        var later: [URL] = []
        for index in 0..<3 {
            later.append(try writePNG(bytes: [UInt8(10 + index), 9, 8, 7], directory: tmp, name: "m\(index).png"))
        }
        let one = HandoffTransfer.persist(copying: [first], kind: .singleImage, store: store)
        guard case .waitingForApp = one else {
            XCTFail("expected the single image to stage")
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
        let many = HandoffTransfer.persist(copying: later, kind: .stitch, store: store)
        guard case .waitingForApp = many else {
            XCTFail("expected the multi-image share to stage")
            return
        }
        let pending = try store.pendingTickets()
        XCTAssertEqual(pending.map(\.kind), [.singleImage, .stitch])
        XCTAssertEqual(PendingShareResume.stagedFileCount(pending), 4)
        XCTAssertEqual(IOSCopy.handoffBannerDetail(for: pending), "已暂存 4 张 · 来自 2 次分享")
        let urls = try PendingShareResume.fileURLs(pending, store: store)
        XCTAssertEqual(urls.count, 4)
        let bytes = try urls.map { try Data(contentsOf: $0) }
        XCTAssertEqual(bytes[0], Data([1, 2, 3, 4]))
        XCTAssertEqual(bytes[1], Data([10, 9, 8, 7]))
        XCTAssertEqual(bytes[2], Data([11, 9, 8, 7]))
        XCTAssertEqual(bytes[3], Data([12, 9, 8, 7]))
    }

    func testPdfsStayOutOfTheStitchListAndTheBannerCount() throws {
        let tmp = try makeTemp()
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let image = try writePNG(bytes: [4, 5, 6, 7], directory: tmp, name: "shot.png")
        let pdf = tmp.appendingPathComponent("page.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        let picture = HandoffTransfer.persist(copying: [image], kind: .singleImage, store: store)
        guard case .waitingForApp = picture else {
            XCTFail("expected the image to stage")
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
        let document = HandoffTransfer.persist(copying: [pdf], kind: .pdf, store: store)
        guard case .waitingForApp = document else {
            XCTFail("expected the pdf to stage")
            return
        }
        let pending = try store.pendingTickets()
        XCTAssertEqual(pending.map(\.kind), [.singleImage, .pdf])
        XCTAssertEqual(PendingShareResume.stagedFileCount(pending), 1)
        XCTAssertTrue(IOSCopy.handoffBannerDetail(for: pending).hasPrefix("已暂存 1 张"))
        XCTAssertFalse(IOSCopy.handoffBannerDetail(for: pending).contains("2 张"))
        let urls = try PendingShareResume.fileURLs(pending, store: store)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(try Data(contentsOf: urls[0]), Data([4, 5, 6, 7]))
        XCTAssertFalse(urls.contains { $0.lastPathComponent.contains("pdf") || $0.pathExtension == "pdf" })
    }

    /// One image plus one PDF is a single image share. M must not count the PDF.
    func testImagePlusPdfCountsAsOneShare() throws {
        let tmp = try makeTemp()
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let image = try writePNG(bytes: [4, 5, 6, 7], directory: tmp, name: "shot.png")
        let pdf = tmp.appendingPathComponent("page.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        guard case .waitingForApp = HandoffTransfer.persist(copying: [image], kind: .singleImage, store: store) else {
            XCTFail("expected the image to stage")
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
        guard case .waitingForApp = HandoffTransfer.persist(copying: [pdf], kind: .pdf, store: store) else {
            XCTFail("expected the pdf to stage")
            return
        }
        let pending = try store.pendingTickets()
        XCTAssertEqual(IOSCopy.handoffBannerDetail(for: pending), "已暂存 1 张")
        XCTAssertFalse(IOSCopy.handoffBannerDetail(for: pending).contains("次分享"))
        XCTAssertFalse(IOSCopy.handoffBannerDetail(for: pending).contains("2 次"))
    }

    /// A PDF share before the images must not take an ordinal slot.
    /// 3 image files with local #2 missing stay cards 1、3、4 and the banner says 第 2 张. N stays 3.
    func testPdfBeforeImagesDoesNotShiftMissingOrdinals() throws {
        let tmp = try makeTemp()
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let pdf = tmp.appendingPathComponent("page.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        let source = try patternedPNG(width: 4, height: 3, directory: tmp)
        guard case .waitingForApp = HandoffTransfer.persist(copying: [pdf], kind: .pdf, store: store) else {
            XCTFail("expected the pdf to stage")
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
        guard case .waitingForApp = HandoffTransfer.persist(
            copying: Array(repeating: source.url, count: 3),
            kind: .stitch,
            store: store,
            missingShots: [MissingShot(ordinal: 2)]
        ) else {
            XCTFail("expected the images to stage")
            return
        }
        let pending = try store.pendingTickets()
        let missing = pending.flatMap { $0.missingShots.map(\.ordinal) }
        XCTAssertEqual(missing, [2])
        XCTAssertEqual(IOSCopy.missingBanner(missing), "少了 1 张 · 第 2 张没读出来")
        XCTAssertEqual(PendingShareResume.globalFileOrdinals(pending), [1, 3, 4])
        XCTAssertEqual(PendingShareResume.stagedFileCount(pending), 3)
        XCTAssertEqual(IOSCopy.handoffBannerDetail(for: pending), "已暂存 3 张")
    }

    /// 「继续拼接」 reads images and must leave the PDF ticket on disk.
    func testContinuingDoesNotDeleteAPdfTicket() throws {
        let tmp = try makeTemp()
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let image = try writePNG(bytes: [8, 8, 8, 8], directory: tmp, name: "shot.png")
        let pdf = tmp.appendingPathComponent("only.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        guard case .waitingForApp = HandoffTransfer.persist(copying: [image], kind: .singleImage, store: store) else {
            XCTFail("expected the image to stage")
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
        guard case .waitingForApp = HandoffTransfer.persist(copying: [pdf], kind: .pdf, store: store) else {
            XCTFail("expected the pdf to stage")
            return
        }
        let pending = try store.pendingTickets()
        let data = try ReceiptConfirmation.imageData(of: pending, store: store)
        XCTAssertEqual(data, [Data([8, 8, 8, 8])])
        let left = try store.pendingTickets()
        XCTAssertEqual(left.map(\.kind), [.pdf])
        let pdfTicket = try XCTUnwrap(left.first)
        XCTAssertEqual(try store.files(for: pdfTicket.id).count, 1)
    }

    func testLaterTicketDeleteDoesNotDropImagesAlreadyRead() throws {
        let tmp = try makeTemp()
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let inner = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        let first = try writePNG(bytes: [1, 1, 1, 1], directory: tmp, name: "a.png")
        let second = try writePNG(bytes: [2, 2, 2, 2], directory: tmp, name: "b.png")
        let third = try writePNG(bytes: [3, 3, 3, 3], directory: tmp, name: "c.png")
        guard case .waitingForApp = HandoffTransfer.persist(copying: [first], kind: .singleImage, store: inner) else {
            XCTFail("expected the first share to stage")
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
        guard case .waitingForApp = HandoffTransfer.persist(copying: [second, third], kind: .stitch, store: inner) else {
            XCTFail("expected the second share to stage")
            return
        }
        let tickets = try inner.pendingTickets()
        XCTAssertEqual(tickets.count, 2)
        let store = SecondDiscardFails(inner: inner)
        do {
            let data = try ReceiptConfirmation.imageData(of: tickets, store: store)
            XCTAssertEqual(data.count, 3)
            XCTAssertEqual(data[0], Data([1, 1, 1, 1]))
            XCTAssertEqual(data[1], Data([2, 2, 2, 2]))
            XCTAssertEqual(data[2], Data([3, 3, 3, 3]))
        } catch {
            XCTFail("a later delete must not drop images already read: \(error)")
        }
    }

    private func stageSharesWithMissing(files: [Int], missing: [[Int]]) throws -> [HandoffTicket] {
        let tmp = try makeTemp()
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let source = try patternedPNG(width: 4, height: 3, directory: tmp)
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        for (index, count) in files.enumerated() {
            if index > 0 {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let shots = missing[index].map { MissingShot(ordinal: $0) }
            let receipt = HandoffTransfer.persist(
                copying: Array(repeating: source.url, count: count),
                kind: .stitch,
                store: store,
                missingShots: shots
            )
            guard case .waitingForApp = receipt else {
                XCTFail("expected a staged share, got \(receipt)")
                continue
            }
        }
        return try store.pendingTickets()
    }

    func testBeginNewPickDropsPreviousOrdinals() {
        let previous = MissingShotSession.remember(failedOrdinals: [2, 5], loadedCount: 4)
        let next = MissingShotSession.beginNewPick(replacing: previous, failedOrdinals: [9], loadedCount: 2)
        XCTAssertEqual(next.ordinals, [9])
        XCTAssertEqual(next.expectedTotal, 3)
        XCTAssertFalse(next.ordinals.contains(2))
        XCTAssertFalse(next.ordinals.contains(5))
    }

    private func stageShares(_ counts: [Int]) throws -> [HandoffTicket] {
        let tmp = try makeTemp()
        addTeardownBlock { try? FileManager.default.removeItem(at: tmp) }
        let source = try patternedPNG(width: 4, height: 3, directory: tmp)
        let store = InlineHandoffStore(root: tmp.appendingPathComponent("inbox", isDirectory: true))
        for (index, count) in counts.enumerated() {
            if index > 0 {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let files = Array(repeating: source.url, count: count)
            let receipt = HandoffTransfer.persist(copying: files, kind: .stitch, store: store)
            guard case .waitingForApp = receipt else {
                XCTFail("expected a staged share, got \(receipt)")
                continue
            }
        }
        return try store.pendingTickets()
    }

    private func makeTemp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accept-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePNG(bytes: [UInt8], directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func patternedPNG(width: Int, height: Int, directory: URL) throws -> (url: URL, png: Data) {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(ShotEncoder.pngData(image))
        let url = directory.appendingPathComponent("shot.png")
        try png.write(to: url)
        return (url, png)
    }

    private func solidPNG(width: Int, height: Int, directory: URL) throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(ShotEncoder.pngData(image))
        let url = directory.appendingPathComponent("large.png")
        try png.write(to: url)
        return url
    }

    private func rgba(of data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

private final class SecondDiscardFails: HandoffStore {
    let inner: InlineHandoffStore
    private var discards = 0

    init(inner: InlineHandoffStore) {
        self.inner = inner
    }

    var canTransferToApp: Bool { inner.canTransferToApp }
    var persistsAcrossProcesses: Bool { inner.persistsAcrossProcesses }

    func stage(copying files: [URL], kind: HandoffKind, missingShots: [MissingShot]) throws -> HandoffTicket {
        try inner.stage(copying: files, kind: kind, missingShots: missingShots)
    }

    func pendingTickets() throws -> [HandoffTicket] {
        try inner.pendingTickets()
    }

    func files(for ticketID: String) throws -> [URL] {
        try inner.files(for: ticketID)
    }

    func discard(ticketID: String) throws {
        discards += 1
        if discards >= 2 {
            throw HandoffError.unreadable
        }
        try inner.discard(ticketID: ticketID)
    }
}

final class FollowUp34CopyTests: XCTestCase {
    func testReaddedFourthIsNamedRatherThanTheSmallestOrdinal() {
        let session = MissingShotSession.remember(failedOrdinals: [2, 4], loadedCount: 2)
        let step = session.addingBack(ordinal: 4)
        XCTAssertEqual(step.restored, 4)
        XCTAssertEqual(step.session.ordinals, [2])
        XCTAssertEqual(IOSCopy.missingBanner(step.session.ordinals), "少了 1 张 · 第 2 张没读出来")
        XCTAssertEqual(IOSCopy.addedBack(ordinal: 4, total: 4), "已加回第 4 张 · 4 张齐了")
    }

    func testTwoPickedOneUnreadableUsesTheMultiErrorPage() {
        XCTAssertEqual(InAppStitchLoader.outcome(readableCount: 1, failedOrdinals: [2]), .failed)
        XCTAssertEqual(IOSCopy.memoryFailedTitle, "这张图片打不开")
        XCTAssertEqual(IOSCopy.multiUnreadableTitle, "有图片没读出来")
        XCTAssertEqual(
            IOSCopy.multiUnreadableBody,
            "可能还在 iCloud 中未下载，或文件已损坏。拼长图至少要 2 张，请重新选图。相册里的原图没动。"
        )
        XCTAssertEqual(InAppStitchLoader.errorTitle(pickedCount: 2), "有图片没读出来")
        XCTAssertEqual(
            InAppStitchLoader.errorBody(pickedCount: 2),
            "可能还在 iCloud 中未下载，或文件已损坏。拼长图至少要 2 张，请重新选图。相册里的原图没动。"
        )
        XCTAssertFalse(InAppStitchLoader.errorBody(pickedCount: 2).contains("读出来的那张"))
        XCTAssertEqual(InAppStitchLoader.outcome(readableCount: 0, failedOrdinals: [1, 2]), .failed)
        XCTAssertEqual(InAppStitchLoader.errorTitle(pickedCount: 2), "有图片没读出来")
        XCTAssertEqual(InAppStitchLoader.errorTitle(pickedCount: 1), "这张图片打不开")
        XCTAssertFalse(InAppStitchLoader.reselectOpensMultiPicker(pickedCount: 1))
        XCTAssertTrue(InAppStitchLoader.reselectOpensMultiPicker(pickedCount: 2))
        XCTAssertEqual(IOSCopy.pickAgain, "重新选图")
    }

    func testS12OpenFailureStaysOnS12WithOneHint() {
        XCTAssertEqual(IOSCopy.readFailedTitle, "没能读取这张图片")
        XCTAssertEqual(IOSCopy.reselectInApp, "改用 PrettyShot App 选图")
        XCTAssertEqual(
            IOSCopy.s12OpenFailedHint,
            "没能打开 PrettyShot。请从主屏幕打开它，在 App 里选图。"
        )
        XCTAssertNotEqual(IOSCopy.s12OpenFailedHint, IOSCopy.pickerOpenFailedHint)
        XCTAssertNotEqual(IOSCopy.s12OpenFailedHint, IOSCopy.cannotHandTitle)
    }

    func testMultiImagePageSaysImagesCannotBeHandedOff() {
        XCTAssertEqual(
            IOSCopy.multiInlineFootnote,
            "这些图没法从分享菜单交给 App · 原图没动。请打开 PrettyShot，用「拼长图」从相册再选一次。"
        )
        XCTAssertEqual(IOSCopy.multiFootnote, "若没有自动打开，手动打开 PrettyShot 即可继续。")
    }

    func testSingleImageStagedBodyOmitsStitchWord() {
        XCTAssertEqual(IOSCopy.stagedTitle(1), "已暂存 1 张")
        XCTAssertEqual(IOSCopy.stagedBody(count: 1), "打开 PrettyShot 即可继续，图片不会丢。")
        XCTAssertEqual(IOSCopy.stagedBody(count: 3), "打开 PrettyShot 即可继续拼接，图片不会丢。")
        XCTAssertEqual(IOSCopy.stagedHint, "打开 App 后，首页会出现「继续上次分享」")
        XCTAssertEqual(IOSCopy.readFailedOK, "好的")
    }

    func testHandoffProgressUsesEllipsis() {
        XCTAssertEqual(IOSCopy.handoffProgressTitle, "正在交给 PrettyShot…")
        XCTAssertFalse(IOSCopy.handoffProgressTitle.contains("..."))
    }

    func testDownsampleChipHasLargeImagePrefix() {
        XCTAssertEqual(IOSCopy.chipDownsampled, "大图 · 预览已降采样")
    }

    func testExtensionSaveUsesFrame10Toast() {
        XCTAssertEqual(IOSCopy.toastSaved, "已存入相册")
        XCTAssertEqual(IOSCopy.toastSavedDetail, "原图未改动 · 即将返回")
        XCTAssertEqual(IOSCopy.inAppSavedDetail, "原图未改动 · 已存为新图片")
        XCTAssertNotEqual(IOSCopy.toastSavedDetail, IOSCopy.inAppSavedDetail)
        XCTAssertEqual(ExtensionSavedToast.dismissAfter, 1.6, accuracy: 0.001)
        XCTAssertFalse(ExtensionSavedToast.hasButtons)
    }

    func testReaddToastNamesTheShotAndKeepsTheBannerUntilTheLastOne() {
        let session = MissingShotSession.remember(failedOrdinals: [2, 6], loadedCount: 5)
        let partial = session.addingBack(ordinal: 2)
        XCTAssertEqual(partial.session.ordinals, [6])
        XCTAssertFalse(partial.session.ordinals.isEmpty)
        XCTAssertEqual(IOSCopy.missingBanner(partial.session.ordinals), "少了 1 张 · 第 6 张没读出来")
        XCTAssertEqual(IOSCopy.addedBackStillMissing(ordinal: 2, stillMissing: 1), "已加回第 2 张 · 还少 1 张")
        let done = partial.session.addingBack(ordinal: 6)
        XCTAssertTrue(done.session.ordinals.isEmpty)
        XCTAssertEqual(IOSCopy.addedBack(ordinal: 6, total: 7), "已加回第 6 张 · 7 张齐了")
    }

    func testFrame11TitleAndBodyStayOnTheUneditedCopy() {
        XCTAssertEqual(IOSCopy.largeTitle, "图片较大，去 App 里处理")
        XCTAssertEqual(
            IOSCopy.largeBody,
            "这张图尺寸很大，在分享菜单里按原分辨率导出可能内存不足。为了不丢图，请在 PrettyShot App 中继续。"
        )
    }

    func testFrame11StyleChangeAppendsTheEditWarning() {
        let remembered = rememberedLastStyle()
        let session = sessionReusing(remembered)
        session.style = BackgroundStyle(presetKey: "moss-quiet", padding: remembered.padding, radius: remembered.radius, shadow: remembered.shadow)
        XCTAssertNotEqual(session.style, remembered)
        assertEditWarningShown(frame11Body(remembered: remembered, session: session))
    }

    func testFrame11CropChangeAppendsTheEditWarning() {
        let remembered = rememberedLastStyle()
        let session = sessionReusing(remembered)
        session.removeStatusBar = false
        XCTAssertEqual(session.style, remembered)
        assertEditWarningShown(frame11Body(remembered: remembered, session: session))
    }

    func testFrame11ArrowAppendsTheEditWarning() {
        let remembered = rememberedLastStyle()
        let session = sessionReusing(remembered)
        session.arrows.append(ArrowMark(start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 0.5, y: 0.7)))
        XCTAssertEqual(session.style, remembered)
        assertEditWarningShown(frame11Body(remembered: remembered, session: session))
    }

    func testFrame11RedactionAppendsTheEditWarning() {
        let remembered = rememberedLastStyle()
        let session = sessionReusing(remembered)
        session.redactions.append(PixelRedaction(rect: CGRect(x: 12, y: 18, width: 40, height: 24)))
        XCTAssertEqual(session.style, remembered)
        assertEditWarningShown(frame11Body(remembered: remembered, session: session))
    }

    /// Opened the extension and changed nothing. The comparison is the style at open.
    /// The extension does not remember a style from a previous session.
    func testFrame11OpeningTheExtensionWithoutEditsOmitsTheEditWarning() throws {
        let model = EditorModel()
        let styleAtOpen = model.style
        model.load(try XCTUnwrap(ShotEncoder.pngData(try solid(width: 8, height: 8))))
        XCTAssertEqual(model.style, styleAtOpen)
        XCTAssertFalse(model.changedStyleThisSession)
        XCTAssertFalse(model.changedCropThisSession)
        XCTAssertFalse(model.addedArrowThisSession)
        XCTAssertFalse(model.addedRedactionThisSession)
        let body = LargeHandoff.body(
            changedStyle: model.changedStyleThisSession,
            changedCrop: model.changedCropThisSession,
            addedArrow: model.addedArrowThisSession,
            addedRedaction: model.addedRedactionThisSession
        )
        XCTAssertEqual(body, IOSCopy.largeBody)
        XCTAssertFalse(body.contains(LargeHandoff.editedNote))
    }

    func testFrame11DropsTheManualOpenFooter() {
        XCTAssertFalse(LargeHandoff.showsManualOpenFooter())
        XCTAssertFalse(IOSCopy.largeBody.contains("如果没有自动打开"))
        XCTAssertFalse(IOSCopy.largeTitle.contains("图片已暂存"))
    }

    func testFrame11CancelKeepsEdits() {
        let kept = LargeHandoff.editsSurviveCancel(padding: 64, arrowCount: 1, redactionCount: 2, removeStatusBar: false)
        XCTAssertEqual(kept.padding, 64)
        XCTAssertEqual(kept.arrowCount, 1)
        XCTAssertEqual(kept.redactionCount, 2)
        XCTAssertFalse(kept.removeStatusBar)
    }

    func testFrame11CancelKeepsFractionalPadding() {
        let kept = Frame11Cancel.preserved(padding: 37.4, arrowCount: 1, redactionCount: 2, removeStatusBar: false)
        XCTAssertEqual(kept.padding, 37.4, accuracy: 0.001)
        XCTAssertEqual(kept.arrowCount, 1)
        XCTAssertEqual(kept.redactionCount, 2)
        XCTAssertFalse(kept.removeStatusBar)
    }

    func testReaddToastIsSingleLineOnTheScreenTheUserLandsOn() {
        XCTAssertEqual(IOSCopy.addedBack(ordinal: 3, total: 4), "已加回第 3 张 · 4 张齐了")
        XCTAssertEqual(IOSCopy.addedBackStillMissing(ordinal: 2, stillMissing: 1), "已加回第 2 张 · 还少 1 张")
        XCTAssertNil(ReaddToast.subtitle)
        XCTAssertEqual(ReaddToast.topOffset, 70, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(ReaddToast.dismissAfter, 1.6)
        XCTAssertLessThanOrEqual(ReaddToast.dismissAfter, 1.8)
        XCTAssertTrue(ReaddToast.showsMintCheck)
        XCTAssertTrue(ReaddToast.usesDarkBlur)
        XCTAssertTrue(ReaddToast.playsSuccessHaptic)

        let fromEditor = ReaddToast.surfaceAfterReadd(from: .editor)
        XCTAssertEqual(fromEditor, .stitch)
        XCTAssertTrue(ReaddToast.draws(on: fromEditor))

        let fromOrder = ReaddToast.surfaceAfterReadd(from: .order)
        XCTAssertEqual(fromOrder, .order)
        XCTAssertTrue(ReaddToast.draws(on: fromOrder))

        let partial = MissingShotSession(ordinals: [2, 6], expectedTotal: 7).addingBack(ordinal: 2)
        XCTAssertEqual(partial.session.ordinals, [6])
        XCTAssertEqual(IOSCopy.missingBanner(partial.session.ordinals), "少了 1 张 · 第 6 张没读出来")
    }

    func testReaddToastDismissesAndDoesNotReturn() throws {
        let model = EditorModel()
        model.showReaddToast(IOSCopy.addedBack(ordinal: 3, total: 4))
        XCTAssertEqual(model.toastTitle, "已加回第 3 张 · 4 张齐了")
        XCTAssertNil(model.toastDetail)
        XCTAssertTrue(model.lastFeedbackIsSuccess)
        model.expireToast(after: 1.7)
        XCTAssertNil(model.toastTitle)
        XCTAssertNil(model.toastDetail)
        model.load(try XCTUnwrap(ShotEncoder.pngData(try solid(width: 8, height: 8))))
        XCTAssertNil(model.toastTitle)
        XCTAssertNil(model.toastDetail)
    }

    /// A non-default style left over from the previous extension session.
    private func rememberedLastStyle() -> BackgroundStyle {
        BackgroundStyle(presetKey: "night-ink", padding: 40, radius: 16, shadow: 24)
    }

    private func sessionReusing(_ remembered: BackgroundStyle) -> EditorModel {
        let model = EditorModel()
        model.style = remembered
        return model
    }

    private func frame11Body(remembered: BackgroundStyle, session: EditorModel) -> String {
        LargeHandoff.body(
            changedStyle: session.style != remembered,
            changedCrop: session.removeStatusBar != true,
            addedArrow: !session.arrows.isEmpty,
            addedRedaction: !session.redactions.isEmpty
        )
    }

    private func assertEditWarningShown(_ body: String) {
        let note = "App 会打开原图，样式和标注要重新调一下。"
        XCTAssertEqual(body, IOSCopy.largeBody + note)
        XCTAssertEqual(body.components(separatedBy: "重新调一下").count, 2)
    }

    func testReadFailedOpenStaysOnThatPageAndMultiImageReselectsOnS10f() {
        XCTAssertEqual(
            ExtensionLaunchRouter.afterPickerOpen(succeeded: false, fromReadFailedPage: true),
            .stayOnReadFailedPage
        )
        XCTAssertEqual(ExtensionLaunchRouter.afterPickerOpen(succeeded: false), .stayAndAskToOpenApp)
        XCTAssertEqual(S12Launch.afterOpenFailed(stagedFileCount: 0), .reselectOnS10f)
    }

    func testSizeMismatchNamesTheSkippedImage() throws {
        XCTAssertEqual(
            IOSCopy.stitchSizeMismatch(ordinals: [2]),
            "第 2 张尺寸不一致，拼接时被跳过。请用同一台手机的竖屏截图。"
        )
        XCTAssertTrue(IOSCopy.stitchSizeMismatch(ordinals: [2]).contains("第 2 张"))
        XCTAssertEqual(
            IOSCopy.stitchSizeMismatch(ordinals: [2, 4]),
            "第 2、4 张尺寸不一致，拼接时被跳过。请用同一台手机的竖屏截图。"
        )
        let model = StitchModel()
        model.ingest([try solid(width: 40, height: 80), try solid(width: 40, height: 120)])
        XCTAssertEqual(model.skippedOrdinals, [2])
        XCTAssertEqual(model.note, IOSCopy.stitchSizeMismatch(ordinals: [2]))
    }

    /// Card 2 never decoded. The later size mismatch is card 3, not the second decoded image.
    func testSizeMismatchUsesTheCardNumberWhenAnEarlierImageWasUnreadable() throws {
        let model = StitchModel()
        model.ingest(
            [try solid(width: 40, height: 80), try solid(width: 48, height: 80)],
            ordinals: [1, 3]
        )
        XCTAssertEqual(model.skippedOrdinals, [3])
        XCTAssertEqual(model.note, IOSCopy.stitchSizeMismatch(ordinals: [3]))
    }

    func testStagedMarkUsesMintInDarkMode() {
        let light = IOSTheme.stagedCheckColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = IOSTheme.stagedCheckColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var lightRed: CGFloat = 0
        var lightGreen: CGFloat = 0
        var lightBlue: CGFloat = 0
        var lightAlpha: CGFloat = 0
        var darkRed: CGFloat = 0
        var darkGreen: CGFloat = 0
        var darkBlue: CGFloat = 0
        var darkAlpha: CGFloat = 0
        XCTAssertTrue(light.getRed(&lightRed, green: &lightGreen, blue: &lightBlue, alpha: &lightAlpha))
        XCTAssertTrue(dark.getRed(&darkRed, green: &darkGreen, blue: &darkBlue, alpha: &darkAlpha))
        XCTAssertEqual(Self.rgbHex(lightRed, lightGreen, lightBlue), 0x4F8F7E)
        XCTAssertEqual(Self.rgbHex(darkRed, darkGreen, darkBlue), 0x7EB8A8)
        let circleLight = IOSTheme.stagedCircleColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let circleDark = IOSTheme.stagedCircleColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var circleLightRed: CGFloat = 0
        var circleLightGreen: CGFloat = 0
        var circleLightBlue: CGFloat = 0
        var circleLightAlpha: CGFloat = 0
        var circleDarkRed: CGFloat = 0
        var circleDarkGreen: CGFloat = 0
        var circleDarkBlue: CGFloat = 0
        var circleDarkAlpha: CGFloat = 0
        XCTAssertTrue(circleLight.getRed(&circleLightRed, green: &circleLightGreen, blue: &circleLightBlue, alpha: &circleLightAlpha))
        XCTAssertTrue(circleDark.getRed(&circleDarkRed, green: &circleDarkGreen, blue: &circleDarkBlue, alpha: &circleDarkAlpha))
        XCTAssertNotEqual(circleLightRed, circleDarkRed)
    }

    private static func rgbHex(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UInt32 {
        func channel(_ value: CGFloat) -> UInt32 { UInt32((value * 255).rounded()) }
        return (channel(red) << 16) | (channel(green) << 8) | channel(blue)
    }

    private func solid(width: Int, height: Int) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

/// PRD (35) a (frame 11b), b, c, e, f. v0.3.45 puts all five in the device-test build.
final class FollowUp35Tests: XCTestCase {
    private let wideMargins = BackgroundStyle(presetKey: BackgroundStyle.default.presetKey, padding: 64, radius: 12, shadow: 48)

    // MARK: a · frame 11b

    func test11bOnlyWhenTheDefaultStyleFitsButTheCurrentOneDoesNot() {
        // 1179×2556 matches the 6.1-inch table entry, so scale 3: padding 28 → 84 px, 64 → 192 px.
        XCTAssertEqual(
            ExtensionMemoryBudget.plan(pixelWidth: 1179, pixelHeight: 2556, canTransferToApp: true),
            .fullResolutionInline,
            "precondition: the default style fits"
        )
        XCTAssertEqual(
            ExtensionMemoryBudget.plan(pixelWidth: 1179, pixelHeight: 2556, canTransferToApp: true, style: wideMargins),
            .handoffToApp,
            "precondition: padding 64 does not"
        )
        XCTAssertEqual(LargeHandoff.kind(pixelWidth: 1179, pixelHeight: 2556, style: wideMargins), .style)
        XCTAssertNil(LargeHandoff.kind(pixelWidth: 1179, pixelHeight: 2556, style: .default))
        XCTAssertEqual(LargeHandoff.kind(pixelWidth: 4000, pixelHeight: 3000, style: .default), .large)
        XCTAssertEqual(LargeHandoff.kind(pixelWidth: 4000, pixelHeight: 3000, style: wideMargins), .large)
    }

    func test11bTitleBodyAndLossSentence() {
        XCTAssertEqual(LargeHandoff.title(.style), "按这个样式导出太大，去 App 里处理")
        XCTAssertEqual(LargeHandoff.title(.large), "图片较大，去 App 里处理")
        XCTAssertEqual(
            LargeHandoff.body(.style, padding: 64, edited: true),
            "这张图本身不大，但当前样式（边距 64）让导出尺寸变得很大，在分享菜单里按原分辨率导出可能内存不足。为了不丢图，请在 PrettyShot App 中继续。App 会打开原图，样式和标注要重新调一下。"
        )
        XCTAssertEqual(
            LargeHandoff.body(.style, padding: 64, edited: false),
            "这张图本身不大，但当前样式（边距 64）让导出尺寸变得很大，在分享菜单里按原分辨率导出可能内存不足。为了不丢图，请在 PrettyShot App 中继续。"
        )
        // Padding not above the default 28: the bracket goes away.
        XCTAssertEqual(
            LargeHandoff.body(.style, padding: 28, edited: false),
            "这张图本身不大，但当前样式让导出尺寸变得很大，在分享菜单里按原分辨率导出可能内存不足。为了不丢图，请在 PrettyShot App 中继续。"
        )
        XCTAssertEqual(LargeHandoff.body(.large, padding: 64, edited: false), IOSCopy.largeBody)
        XCTAssertEqual(LargeHandoff.body(.large, padding: 64, edited: true), IOSCopy.largeBody + LargeHandoff.editedNote)
        XCTAssertFalse(LargeHandoff.body(.style, padding: 64, edited: true).contains("预览尺寸"))
    }

    func test11bShrinkPaddingOnlyWhenPadding28WouldFit() {
        XCTAssertTrue(LargeHandoff.showsShrinkPadding(pixelWidth: 1179, pixelHeight: 2556, style: wideMargins))
        // Frame 11: even padding 28 is over, so the button would not help.
        XCTAssertFalse(LargeHandoff.showsShrinkPadding(pixelWidth: 4000, pixelHeight: 3000, style: wideMargins))
        // Nothing over budget: no sheet, no button.
        XCTAssertFalse(LargeHandoff.showsShrinkPadding(pixelWidth: 1179, pixelHeight: 2556, style: .default))
    }

    func test11bShrinkPaddingOpensTheStylePanelWithoutChangingValues() throws {
        let model = EditorModel()
        model.load(try XCTUnwrap(ShotEncoder.pngData(try solid(width: 8, height: 8))))
        model.style = wideMargins
        model.tool = .background
        model.openPaddingControl()
        XCTAssertEqual(model.tool, .style)
        XCTAssertEqual(model.style, wideMargins)
        XCTAssertTrue(model.changedStyleThisSession)
    }

    // MARK: b · A1b button

    func testA1bSingleStagedShotSaysContinueEditing() {
        XCTAssertEqual(IOSCopy.handoffBannerAction(stagedCount: 1), "继续编辑")
        XCTAssertEqual(IOSCopy.handoffBannerAction(stagedCount: 2), "继续拼接")
        XCTAssertEqual(IOSCopy.handoffBannerAction(stagedCount: 4), "继续拼接")

        let now = Date()
        let one = HandoffTicket(id: "a", kind: .singleImage, fileNames: ["000.png"], createdAt: now)
        let pdf = HandoffTicket(id: "p", kind: .pdf, fileNames: ["000.pdf"], createdAt: now.addingTimeInterval(1))
        let three = HandoffTicket(id: "s", kind: .stitch, fileNames: ["0.png", "1.png", "2.png"], createdAt: now.addingTimeInterval(2))
        XCTAssertEqual(IOSCopy.handoffBannerAction(for: [one]), "继续编辑")
        // A PDF is not counted, so one image plus a PDF still opens the editor.
        XCTAssertEqual(IOSCopy.handoffBannerAction(for: [one, pdf]), "继续编辑")
        XCTAssertEqual(IOSCopy.handoffBannerAction(for: [one, three]), "继续拼接")
    }

    // MARK: c · re-add button

    func testReaddButtonDropsTheOrdinalWhenOnlyOneShotIsMissing() {
        XCTAssertEqual(IOSCopy.readdButton(ordinal: 3, missingCount: 1), "重新加入")
        XCTAssertEqual(IOSCopy.readdButton(ordinal: 3, missingCount: 2), "重新加入 · 第 3 张")
        XCTAssertEqual(IOSCopy.readdButton(ordinal: 6, missingCount: 2), "重新加入 · 第 6 张")
    }

    // MARK: e · every error path resets failedPickCount

    func testEveryErrorPathSetsThePickedCount() {
        // Start from a stale value on purpose: a previous failure must not pick the copy.
        XCTAssertEqual(InAppStitchLoader.pickedCount(after: .singlePick, previous: 4), 1)
        XCTAssertEqual(InAppStitchLoader.pickedCount(after: .multiPick(picked: 3), previous: 1), 3)
        XCTAssertEqual(InAppStitchLoader.pickedCount(after: .stitchStart(picked: 3), previous: 1), 3)
        XCTAssertEqual(InAppStitchLoader.pickedCount(after: .pendingResume(staged: 4), previous: 1), 4)
        XCTAssertEqual(InAppStitchLoader.pickedCount(after: .pendingResume(staged: 1), previous: 4), 1)
        XCTAssertEqual(InAppStitchLoader.pickedCount(after: .editorExport, previous: 4), 1)

        let afterStart = InAppStitchLoader.pickedCount(after: .stitchStart(picked: 3), previous: 1)
        XCTAssertEqual(InAppStitchLoader.errorTitle(pickedCount: afterStart), IOSCopy.multiUnreadableTitle)
        let afterExport = InAppStitchLoader.pickedCount(after: .editorExport, previous: 4)
        XCTAssertEqual(InAppStitchLoader.errorTitle(pickedCount: afterExport), IOSCopy.memoryFailedTitle)
    }

    // MARK: f · downsample chip follows the current style

    func testDownsampleChipFollowsTheCurrentStyle() {
        let narrow = BackgroundStyle(presetKey: BackgroundStyle.default.presetKey, padding: 8, radius: 12, shadow: 48)
        // 1242×2688 (scale 3): over the gate at padding 28, inside it at padding 8.
        XCTAssertNotEqual(
            ExtensionMemoryBudget.plan(pixelWidth: 1242, pixelHeight: 2688, canTransferToApp: true),
            .fullResolutionInline,
            "precondition: the default style is over"
        )
        XCTAssertEqual(
            ExtensionMemoryBudget.plan(pixelWidth: 1242, pixelHeight: 2688, canTransferToApp: true, style: narrow),
            .fullResolutionInline,
            "precondition: padding 8 fits"
        )
        XCTAssertTrue(PreviewDownsampleChip.shows(inExtension: true, pixelWidth: 1242, pixelHeight: 2688, canTransferToApp: true))
        XCTAssertFalse(PreviewDownsampleChip.shows(
            inExtension: true, pixelWidth: 1242, pixelHeight: 2688, canTransferToApp: true, style: narrow
        ))
        // 11b has no chip (r7 §15 rule 1).
        XCTAssertFalse(PreviewDownsampleChip.shows(
            inExtension: true, pixelWidth: 1179, pixelHeight: 2556, canTransferToApp: true, style: wideMargins
        ))
        XCTAssertTrue(PreviewDownsampleChip.shows(
            inExtension: true, pixelWidth: 4000, pixelHeight: 3000, canTransferToApp: true, style: wideMargins
        ))
    }

    private func solid(width: Int, height: Int) throws -> CGImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

/// Card ① task 3. A shot still over the gate at the default style goes to the app through the
/// existing frame 11 flow and copy. Never a silent failure, never frame 11b.
final class LargeHandoffRoutingTests: XCTestCase {
    func testDefaultStyleOverflowShowsFrame11WithLargeBody() throws {
        let model = EditorModel()
        model.load(try png(width: 1320, height: 2868))
        let attempt = try XCTUnwrap(model.export(canTransferToApp: true))
        guard case .handoff = attempt else {
            XCTFail("1320×2868 at the default style must hand off, got \(attempt)")
            return
        }
        let frame = LargeHandoff.frame(
            changedStyle: model.changedStyleThisSession,
            changedCrop: model.changedCropThisSession,
            addedArrow: model.addedArrowThisSession,
            addedRedaction: model.addedRedactionThisSession
        )
        XCTAssertEqual(frame, .frame11)
        XCTAssertEqual(
            LargeHandoff.body(
                changedStyle: model.changedStyleThisSession,
                changedCrop: model.changedCropThisSession,
                addedArrow: model.addedArrowThisSession,
                addedRedaction: model.addedRedactionThisSession
            ),
            IOSCopy.largeBody
        )
    }

    func testEditedOverflowShowsFrame11a() throws {
        let model = EditorModel()
        model.load(try png(width: 1320, height: 2868))
        model.addArrow(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 200, y: 300), in: CGSize(width: 440, height: 956))
        let attempt = try XCTUnwrap(model.export(canTransferToApp: true))
        guard case .handoff = attempt else {
            XCTFail("an edited 1320×2868 must still hand off, got \(attempt)")
            return
        }
        XCTAssertEqual(LargeHandoff.frame(changedStyle: false, changedCrop: false, addedArrow: true, addedRedaction: false), .frame11a)
        XCTAssertEqual(
            LargeHandoff.body(changedStyle: false, changedCrop: false, addedArrow: true, addedRedaction: false),
            IOSCopy.largeBody + LargeHandoff.editedNote
        )
    }

    /// 11b is only for a shot that fits at the default style and is pushed over by larger margins.
    /// A default-style overflow stays on 11 / 11a even when the user also enlarged the margins.
    func testDefaultStyleOverflowNeverShowsFrame11b() throws {
        let model = EditorModel()
        model.load(try png(width: 1320, height: 2868))
        model.style = BackgroundStyle(presetKey: "pastel-air", padding: 64, radius: 12, shadow: 48)
        let attempt = try XCTUnwrap(model.export(canTransferToApp: true))
        guard case .handoff = attempt else {
            XCTFail("1320×2868 at padding 64 must hand off, got \(attempt)")
            return
        }
        let frame = LargeHandoff.frame(
            changedStyle: model.changedStyleThisSession,
            changedCrop: model.changedCropThisSession,
            addedArrow: model.addedArrowThisSession,
            addedRedaction: model.addedRedactionThisSession
        )
        XCTAssertNotEqual(frame, .frame11b)
        XCTAssertEqual(frame, .frame11a)
        for edited in [false, true] {
            XCTAssertNotEqual(
                LargeHandoff.frame(changedStyle: edited, changedCrop: false, addedArrow: false, addedRedaction: false),
                .frame11b
            )
        }
    }

    /// Without a transfer channel the extension asks the user to reselect in the app. It does not fail silently.
    func testOverflowWithoutTransferIsNotSilent() throws {
        let model = EditorModel()
        model.load(try png(width: 1320, height: 2868))
        let attempt = try XCTUnwrap(model.export(canTransferToApp: false))
        guard case .reselectInApp = attempt else {
            XCTFail("expected reselectInApp, got \(attempt)")
            return
        }
    }

    /// A4: the app opens a single handed-off image straight into the editor, not the home banner.
    func testAppOpensSingleImageHandoffDirectlyInA4() {
        let older = HandoffTicket(id: "a", kind: .stitch, fileNames: ["000-a.png", "001-b.png"], createdAt: Date(timeIntervalSince1970: 10))
        let single = HandoffTicket(id: "b", kind: .singleImage, fileNames: ["000-big.png"], createdAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(HandoffLaunch.ticketToOpen(host: "handoff", pending: [single]), single)
        XCTAssertEqual(HandoffLaunch.ticketToOpen(host: "handoff", pending: [single, older]), single)
        XCTAssertNil(HandoffLaunch.ticketToOpen(host: "handoff", pending: [older]))
        XCTAssertNil(HandoffLaunch.ticketToOpen(host: "pick", pending: [single]))
        XCTAssertNil(HandoffLaunch.ticketToOpen(host: "handoff", pending: []))
    }

    private func png(width: Int, height: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
