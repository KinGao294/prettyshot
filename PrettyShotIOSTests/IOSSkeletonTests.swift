import CoreGraphics
import Darwin
import ImageIO
import PrettyShotCore
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
        XCTAssertEqual(IOSCopy.handoffProgressTitle, "正在交给 PrettyShot...")
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
        XCTAssertEqual(ExtensionMemoryBudget.fullSizeCopiesWhileExporting, 4)
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
        let measured = source.width * source.height * 4
            + redacted.width * redacted.height * 4
            + canvas.width * canvas.height * 4
            + shadowBytes
        XCTAssertEqual(
            ExtensionMemoryBudget.exportPeakBytes(
                sourcePixels: width * height,
                canvasPixels: canvas.width * canvas.height
            ),
            measured
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
        XCTAssertLessThanOrEqual(oldPeak, ExtensionMemoryBudget.limitBytes)
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
        XCTAssertEqual(PendingShareResume.stagedFileCount(pending), 3)
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

    private func makeTemp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accept-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

/// Frames 56–58 (L7e / L7f / L7g) on the shared bottom bar.
final class StitchDuplicateReviewTests: XCTestCase {
    func testL7ePendingCardNamesTheShotPairAndGatesTheBar() {
        let session = StitchSession(assembly: fourShotAssembly(choices: [nil]))
        let card = session.duplicateCard("dup-a")
        XCTAssertEqual(card?.isPending, true)
        XCTAssertEqual(card?.displayIndex, 1)
        XCTAssertEqual(card?.question, "这一行出现了两次")
        XCTAssertEqual(card?.detail, "第 1、2 张接缝处 · 程序判断不了是重叠还是本来就重复")
        XCTAssertNil(card?.handledLabel)
        XCTAssertEqual(
            session.bottomBar.line,
            "⚠ 还有 1 处没处理（待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertEqual(session.bottomBar.items.map(\.label), ["待确认 1"])
        XCTAssertEqual(session.bottomBar.primaryTitle, "先确认 1 处重复段")
        XCTAssertFalse(session.bottomBar.canAdvance)
        XCTAssertNil(session.toast)
    }

    func testL7eCardKeepsAbsoluteShotNumbersAfterAnUnalignedSeam() {
        let image = RGBAImage(width: 4, height: 40, pixels: [UInt8](repeating: 255, count: 4 * 40 * 4))
        // Shot 1 | unaligned seam | shots 2–3 joined at row 10. The repeat sits under the 2/3 join.
        let session = StitchSession(assembly: ScrollAssembly(
            segments: [
                ScrollSegment(image: image, confidentSeamYs: []),
                ScrollSegment(image: image, confidentSeamYs: [10]),
            ],
            seams: [ScrollSeam(kind: .needsAlignment, suggestedOverlap: 4)],
            duplicateCandidates: [
                DuplicateSegmentCandidate(id: "dup", seamNumber: 1, rowCount: 2, segmentIndex: 1, startRow: 10),
            ]
        ))
        XCTAssertEqual(session.duplicateCard("dup")?.detail, "第 2、3 张接缝处 · 程序判断不了是重叠还是本来就重复")
        XCTAssertEqual(session.bottomBar.primaryTitle, "处理下一处 · 1")
        XCTAssertEqual(session.bottomBar.items.map(\.label), ["待对齐 1", "待确认 1"])
    }

    func testL7eTappingThePrimaryScrollsToTheFirstPendingCard() {
        let model = StitchModel()
        model.session = StitchSession(assembly: fourShotAssembly(choices: [.keepOnce, nil]))
        model.primaryTapped()
        XCTAssertEqual(model.scrollToDuplicate, "dup-b")
        XCTAssertNil(model.flattened)
    }

    func testL7fHandledCardShowsCapsuleAndRestore() {
        var session = StitchSession(assembly: fourShotAssembly(choices: [nil, nil]))
        session.resolveDuplicate("dup-a", choice: .keepOnce)
        let handled = session.duplicateCard("dup-a")
        XCTAssertEqual(handled?.isPending, false)
        XCTAssertEqual(handled?.handledLabel, "已处理 · 只保留一次")
        XCTAssertEqual(session.duplicateCard("dup-b")?.detail, "第 2、3 张接缝处 · 程序判断不了是重叠还是本来就重复")
        XCTAssertNil(session.duplicateCard("dup-b")?.handledLabel)
        XCTAssertEqual(
            session.bottomBar.line,
            "⚠ 还有 1 处没处理（待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertEqual(session.bottomBar.primaryTitle, "先确认 1 处重复段")
        XCTAssertEqual(session.toast, StitchToast(title: "第 1 处重复段：只保留一次", detail: "待确认还剩 1 处", actionTitle: "撤销"))

        session.resolveDuplicate("dup-b", choice: .keepBoth)
        XCTAssertEqual(session.duplicateCard("dup-b")?.handledLabel, "已处理 · 都保留")
    }

    func testL7gRestorePutsOnlyThatCardBackAndCountsUp() {
        var session = StitchSession(assembly: fourShotAssembly(choices: [nil, nil]))
        session.resolveDuplicate("dup-a", choice: .keepOnce)
        session.restoreDuplicate("dup-a")

        XCTAssertEqual(session.duplicateCard("dup-a")?.isPending, true)
        XCTAssertNil(session.duplicateCard("dup-a")?.handledLabel)
        XCTAssertEqual(session.duplicateCard("dup-a")?.detail, "第 1、2 张接缝处 · 程序判断不了是重叠还是本来就重复")
        XCTAssertEqual(
            session.bottomBar.line,
            "⚠ 还有 2 处没处理（待确认 2）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertEqual(session.bottomBar.count, 2)
        XCTAssertEqual(session.bottomBar.primaryTitle, "先确认 2 处重复段")
        XCTAssertEqual(session.toast, StitchToast(title: "第 1 处重复段已还原为待确认", detail: "待确认还剩 2 处", actionTitle: "撤销"))
    }

    func testL7gRestoreTouchesOnlyItsOwnID() {
        var session = StitchSession(assembly: fourShotAssembly(choices: [.keepOnce, .keepBoth]))
        session.restoreDuplicate("dup-b")
        XCTAssertEqual(session.duplicateCard("dup-a")?.handledLabel, "已处理 · 只保留一次")
        XCTAssertEqual(session.duplicateCard("dup-b")?.isPending, true)
        XCTAssertEqual(session.toast?.title, "第 2 处重复段已还原为待确认")
        XCTAssertEqual(session.toast?.detail, "待确认还剩 1 处")
        XCTAssertEqual(session.bottomBar.primaryTitle, "先确认 1 处重复段")
    }

    func testL7gUndoingARestoreBringsTheChoiceBack() {
        var session = StitchSession(assembly: fourShotAssembly(choices: [nil, nil]))
        session.resolveDuplicate("dup-a", choice: .keepOnce)
        session.restoreDuplicate("dup-a")
        session.undoDuplicate()

        XCTAssertEqual(session.assembly.duplicateCandidates.first?.choice, .keepOnce)
        XCTAssertEqual(session.duplicateCard("dup-a")?.handledLabel, "已处理 · 只保留一次")
        XCTAssertEqual(session.bottomBar.items.map(\.label), ["待确认 1"])
        XCTAssertEqual(session.bottomBar.primaryTitle, "先确认 1 处重复段")
        XCTAssertEqual(session.toast, StitchToast(title: "已撤销", detail: "待确认还剩 1 处", actionTitle: nil))
    }

    func testL7gUndoingAChoicePutsTheCardBackToPending() {
        var session = StitchSession(assembly: fourShotAssembly(choices: [nil, nil]))
        session.resolveDuplicate("dup-b", choice: .keepBoth)
        XCTAssertEqual(session.bottomBar.count, 1)
        session.undoDuplicate()
        XCTAssertEqual(session.duplicateCard("dup-b")?.isPending, true)
        XCTAssertEqual(session.bottomBar.count, 2)
        XCTAssertEqual(session.bottomBar.primaryTitle, "先确认 2 处重复段")
        XCTAssertEqual(session.toast, StitchToast(title: "已撤销", detail: "待确认还剩 2 处", actionTitle: nil))
    }

    func testRestoringAPendingCardIsANoOp() {
        var session = StitchSession(assembly: fourShotAssembly(choices: [nil]))
        session.restoreDuplicate("dup-a")
        XCTAssertNil(session.toast)
        XCTAssertEqual(session.assembly.duplicateUndoCount, 0)
        XCTAssertEqual(session.bottomBar.count, 1)
    }

    func testRestoreAutoDropsTheUndoToast() {
        var session = StitchSession(assembly: fourShotAssembly(choices: [nil, nil]))
        session.resolveDuplicate("dup-a", choice: .keepOnce)
        session.restoreAuto(seam: 0)
        XCTAssertNil(session.toast?.actionTitle)
        XCTAssertEqual(session.assembly.duplicateUndoCount, 0)
    }

    /// Shots 1–4 in one segment (confident joins at rows 10 / 20 / 30), then shot 5 behind an aligned seam
    /// so 「还原自动」 has a seam to act on. Candidates sit under the 1/2 and 2/3 joins.
    func fourShotAssembly(choices: [DuplicateSegmentChoice?]) -> ScrollAssembly {
        let image = RGBAImage(width: 4, height: 40, pixels: [UInt8](repeating: 255, count: 4 * 40 * 4))
        let tail = RGBAImage(width: 4, height: 8, pixels: [UInt8](repeating: 255, count: 4 * 8 * 4))
        let ids = ["dup-a", "dup-b"]
        let rows = [10, 20]
        let candidates = choices.enumerated().map { index, choice in
            DuplicateSegmentCandidate(
                id: ids[index],
                choice: choice,
                seamNumber: index + 1,
                rowCount: 2,
                segmentIndex: 0,
                startRow: rows[index]
            )
        }
        return ScrollAssembly(
            segments: [
                ScrollSegment(image: image, confidentSeamYs: [10, 20, 30]),
                ScrollSegment(image: tail, confidentSeamYs: []),
            ],
            seams: [ScrollSeam(kind: .aligned(overlap: 0), suggestedOverlap: 0)],
            duplicateCandidates: candidates
        )
    }
}

/// Frames 59–60 (L7h / L7i). Same bar as L7e–L7g; only its state changes.
final class StitchBottomBarStateTests: XCTestCase {
    func testL7hAllHandledHidesTheGateAndOffersBeautify() {
        var session = StitchSession(assembly: fourShotAssembly(choices: [.keepOnce, nil]))
        session.resolveDuplicate("dup-b", choice: .keepBoth)

        let bar = session.bottomBar
        XCTAssertNil(bar.line)
        XCTAssertTrue(bar.isGateHidden)
        XCTAssertTrue(bar.items.isEmpty)
        XCTAssertEqual(bar.count, 0)
        XCTAssertEqual(bar.step, .ready)
        XCTAssertEqual(bar.primaryTitle, "下一步 · 美化")
        XCTAssertTrue(bar.canAdvance)
        XCTAssertEqual(session.gate.bottomBar, nil)
        XCTAssertEqual(session.duplicateCard("dup-a")?.handledLabel, "已处理 · 只保留一次")
        XCTAssertEqual(session.duplicateCard("dup-b")?.handledLabel, "已处理 · 都保留")
        XCTAssertEqual(session.toast, StitchToast(title: "第 2 处重复段：都保留", detail: "重复段都处理完了", actionTitle: "撤销"))
    }

    func testL7hUndoBringsTheGateBack() {
        var session = StitchSession(assembly: fourShotAssembly(choices: [.keepOnce, nil]))
        session.resolveDuplicate("dup-b", choice: .keepBoth)
        session.undoDuplicate()
        XCTAssertEqual(
            session.bottomBar.line,
            "⚠ 还有 1 处没处理（待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertEqual(session.bottomBar.primaryTitle, "先确认 1 处重复段")
        XCTAssertEqual(session.toast, StitchToast(title: "已撤销", detail: "待确认还剩 1 处", actionTitle: nil))
    }

    func testL7hPrimaryTapFlattensOnlyWhenReady() {
        let model = StitchModel()
        model.session = StitchSession(assembly: fourShotAssembly(choices: [.keepOnce, .keepBoth]))
        XCTAssertTrue(model.session.bottomBar.canAdvance)
        model.primaryTapped()
        XCTAssertNotNil(model.flattened)
        XCTAssertNil(model.scrollToDuplicate)
    }

    func testL7iDuplicateAndStickyAreTwoSeparateItems() {
        var assembly = fourShotAssembly(choices: [nil])
        assembly.pendingSticky = PendingStickyConfirmation(headerRows: 8, footerRows: 0, seamCount: 3, keepOnce: nil)
        var session = StitchSession(assembly: assembly)

        let bar = session.bottomBar
        XCTAssertEqual(bar.items, [
            StitchBottomBar.Item(kind: .duplicates, count: 1, label: "待确认 1"),
            StitchBottomBar.Item(kind: .sticky, count: 1, label: "固定栏待确认 1"),
        ])
        XCTAssertEqual(bar.count, 2)
        XCTAssertEqual(
            bar.line,
            "⚠ 还有 2 处没处理（待确认 1 · 固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertEqual(bar.step, .sticky)
        XCTAssertEqual(bar.primaryTitle, "处理下一处 · 1")
        XCTAssertFalse(bar.primaryTitle.contains("先确认"))
        XCTAssertFalse(bar.canAdvance)

        session.confirmSticky(keepOnce: true)
        XCTAssertEqual(session.bottomBar.items.map(\.kind), [.duplicates])
        XCTAssertEqual(session.bottomBar.primaryTitle, "先确认 1 处重复段")
        XCTAssertEqual(
            session.bottomBar.line,
            "⚠ 还有 1 处没处理（待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
    }

    func testL7iChoosingTheDuplicateFirstLeavesOnlyTheStickyItem() {
        var assembly = fourShotAssembly(choices: [nil])
        assembly.pendingSticky = PendingStickyConfirmation(headerRows: 8, footerRows: 0, seamCount: 3, keepOnce: nil)
        var session = StitchSession(assembly: assembly)
        session.resolveDuplicate("dup-a", choice: .keepOnce)

        XCTAssertEqual(session.bottomBar.items.map(\.label), ["固定栏待确认 1"])
        XCTAssertEqual(
            session.bottomBar.line,
            "⚠ 还有 1 处没处理（固定栏待确认 1）。为了不拼错，处理完才能继续——不会静默拼接。"
        )
        XCTAssertEqual(session.bottomBar.primaryTitle, "处理下一处 · 1")
        // The toast only counts duplicates; the sticky bar stays on the bar.
        XCTAssertEqual(session.toast, StitchToast(title: "第 1 处重复段：只保留一次", detail: "重复段都处理完了", actionTitle: "撤销"))
    }

    func testAllFourStatesShareOneBarType() {
        // L4 / L7e / L7i / L7h all come out of StitchBottomBar.evaluate; the gate just mirrors it.
        let seams = ScrollAssembly(seams: [ScrollSeam(kind: .needsAlignment, suggestedOverlap: 4)])
        for assembly in [seams, fourShotAssembly(choices: [nil]), ScrollAssembly()] {
            let gate = StitchGate.evaluate(assembly)
            XCTAssertEqual(gate.bar, StitchBottomBar.evaluate(assembly))
            XCTAssertEqual(gate.primaryTitle, gate.bar.primaryTitle)
            XCTAssertEqual(gate.bottomBar, gate.bar.line)
        }
        XCTAssertEqual(StitchBottomBar.evaluate(seams).items.map(\.label), ["待对齐 1"])
        XCTAssertEqual(StitchBottomBar.evaluate(seams).primaryTitle, "处理下一处 · 1")
    }

    /// Same layout as StitchDuplicateReviewTests: shots 1–4 joined at rows 10 / 20 / 30, shot 5 behind an aligned seam.
    private func fourShotAssembly(choices: [DuplicateSegmentChoice?]) -> ScrollAssembly {
        let image = RGBAImage(width: 4, height: 40, pixels: [UInt8](repeating: 255, count: 4 * 40 * 4))
        let tail = RGBAImage(width: 4, height: 8, pixels: [UInt8](repeating: 255, count: 4 * 8 * 4))
        let ids = ["dup-a", "dup-b"]
        let rows = [10, 20]
        let candidates = choices.enumerated().map { index, choice in
            DuplicateSegmentCandidate(
                id: ids[index],
                choice: choice,
                seamNumber: index + 1,
                rowCount: 2,
                segmentIndex: 0,
                startRow: rows[index]
            )
        }
        return ScrollAssembly(
            segments: [
                ScrollSegment(image: image, confidentSeamYs: [10, 20, 30]),
                ScrollSegment(image: tail, confidentSeamYs: []),
            ],
            seams: [ScrollSeam(kind: .aligned(overlap: 0), suggestedOverlap: 0)],
            duplicateCandidates: candidates
        )
    }
}
