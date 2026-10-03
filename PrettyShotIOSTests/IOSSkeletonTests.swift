import CoreGraphics
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

    func testRestoreAutoDoesNotClaimRedetection() {
        let image = RGBAImage(width: 4, height: 8, pixels: [UInt8](repeating: 255, count: 4 * 8 * 4))
        let segment = ScrollSegment(image: image, confidentSeamYs: [])
        var session = StitchSession(assembly: ScrollAssembly(
            segments: [segment, segment],
            seams: [ScrollSeam(kind: .aligned(overlap: 1), suggestedOverlap: 3)],
            duplicateCandidates: [DuplicateSegmentCandidate(id: "dup", choice: .keepOnce)]
        ))
        session.restoreAuto(seam: 0)
        XCTAssertEqual(session.assembly.seams.first?.kind, .aligned(overlap: 3))
        XCTAssertEqual(session.assembly.duplicateCandidates.first?.choice, .keepOnce)
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
        XCTAssertEqual(IOSCopy.handoffProgressTitle, "正在交给 PrettyShot")
        XCTAssertEqual(IOSCopy.handoffProgressBody, "原图还在，没有改动。")
        XCTAssertTrue(IOSCopy.reselectBody.contains("原图没有被改动"))
        XCTAssertFalse(IOSCopy.reselectBody.contains("去 App 里处理"))
        XCTAssertFalse(IOSCopy.reselectBody.contains("预览尺寸"))
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
            ExtensionMemoryBudget.rgbaBytes(pixels: pixels, copies: ExtensionMemoryBudget.fullSizeCopiesWhileExporting),
            ExtensionMemoryBudget.limitBytes
        )
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelCount: pixels, canTransferToApp: true), .fullResolutionInline)
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelCount: pixels, canTransferToApp: false), .fullResolutionInline)
    }

    func testLargerImageHandsOffOnlyWhenTransferExists() {
        let pixels = 20_000_000
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelCount: pixels, canTransferToApp: true), .handoffToApp)
        XCTAssertEqual(ExtensionMemoryBudget.plan(pixelCount: pixels, canTransferToApp: false), .reselectInApp)
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
            ExportFidelityRouter.decide(pixelCount: pixels, canTransferToApp: false),
            .fullResolutionPNG
        )
        XCTAssertEqual(
            ExportFidelityRouter.decide(pixelCount: pixels, canTransferToApp: true),
            .fullResolutionPNG
        )
        XCTAssertEqual(
            ExportFidelityRouter.decide(pixelCount: 20_000_000, canTransferToApp: false),
            .reselectInApp
        )
        XCTAssertEqual(
            ExportFidelityRouter.decide(pixelCount: 20_000_000, canTransferToApp: true),
            .handOffOriginal
        )

        let previewPixels = ExtensionMemoryBudget.previewPixelCount(width: 4000, height: 3000)
        let editing = ExtensionMemoryBudget.inlineEditingHold(pixelCount: pixels, previewPixels: previewPixels)
        XCTAssertEqual(editing.fullDecodedCopies, 0)
        XCTAssertTrue(editing.passesFileWithoutDecode)
        XCTAssertLessThanOrEqual(editing.estimatedBytes, ExtensionMemoryBudget.limitBytes)

        let exporting = ExtensionMemoryBudget.fullExportHold(pixelCount: pixels)
        XCTAssertEqual(exporting.fullDecodedCopies, 2)
        XCTAssertLessThanOrEqual(exporting.estimatedBytes, ExtensionMemoryBudget.limitBytes)
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
        XCTAssertEqual(stitched.map { ($0.width, $0.height) }, [(width, height)])

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
