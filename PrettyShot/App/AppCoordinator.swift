import AppKit
import Combine
import PrettyShotCore
import SwiftUI
import UniformTypeIdentifiers

/// Central wiring: capture → Quick Overlay → editor / save / pin, plus History, Settings and Permission windows.
@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    let preferences = Preferences.shared
    let permissions = PermissionManager()
    let hotkeys = HotkeyManager()
    let pins = PinManager()
    let history = HistoryStore()

    private let captureService = ScreenCaptureService()
    private let overlay = QuickOverlayController()
    private var statusItem: StatusItemController?
    private var captureSession: CaptureSession?
    /// The in-flight capture (popover fade + ScreenCaptureKit + HUD); cancelled on toggle / Esc.
    private var captureTask: Task<Void, Never>?
    /// Once a scrolling capture has locked its region, Esc finishes the stitch instead of discarding it.
    private var escapeFinishesScrolling = false
    private var editors: [EditorWindowController] = []
    private var stitchPreview: StitchPreviewController?
    private var historyWindow: NSWindow?
    /// Capture was started from History. Bring that window back if the shot is cancelled or fails.
    private var returnToHistoryOnCancel = false
    private var settingsWindow: NSWindow?
    private var permissionWindow: NSWindow?
    /// Frontmost app before the capture HUD took focus; re-activated after Copy / Dismiss so ⌘V lands there.
    private var appBeforeCapture: NSRunningApplication?
    /// Frontmost app sampled right before the popover activated PrettyShot (by then `frontmostApplication` is us).
    private var appBeforePopover: NSRunningApplication?

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func start() {
        guard !Self.isRunningTests else { return }
        statusItem = StatusItemController(coordinator: self)
        hotkeys.onTrigger = { [weak self] action in self?.perform(action) }
        hotkeys.onEscape = { [weak self] in self?.handleEscape() }
        hotkeys.registerAll()
        permissions.refresh()
    }

    func stop() {
        hotkeys.unregisterAll()
    }

    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureRegion: startCapture(.region)
        case .captureWindow: startCapture(.window)
        case .captureFullscreen: startCapture(.fullscreen)
        case .captureScrolling: startCapture(.scrolling)
        case .openHistory: showHistory()
        case .pinLatest: pinLatest()
        }
    }

    // MARK: - Capture

    /// Where a capture was started from — decides which previously-frontmost app gets focus back.
    enum CaptureTrigger {
        case hotkey, popover, window
    }

    func startCapture(_ mode: CaptureMode, trigger: CaptureTrigger = .hotkey) {
        if captureSession != nil {
            // Pressing a capture hotkey again while a capture is in flight cancels it (toggle).
            cancelCapture()
            return
        }
        if stitchPreview != nil {
            ToastPresenter.shared.show("请先完成或关闭拼接预览", style: .info, duration: 3)
            return
        }
        // Sample before anything below (popover close, HUD) can activate PrettyShot.
        let focusTarget = focusTarget(for: trigger)
        statusItem?.closePopover()

        permissions.refresh()
        guard permissions.screenCaptureGranted else {
            permissions.requestIfNeeded()
            showPermission(detail: nil)
            return
        }

        appBeforeCapture = focusTarget
        let session = CaptureSession(mode: mode, service: captureService, retryBlankFrames: permissions.grantIsFresh)
        session.onScrollingBegan = { [weak self] in
            self?.escapeFinishesScrolling = true
        }
        captureSession = session
        hotkeys.beginEscapeMonitoring()
        captureTask = Task { @MainActor [weak self] in
            // Let the popover fade out before the frame is frozen (sleep throws on cancel → run() sees it).
            try? await Task.sleep(nanoseconds: 180_000_000)
            let outcome = await session.run()
            guard let self, self.captureSession === session else { return } // superseded / already cancelled
            self.endCapture()
            self.handle(outcome)
        }
    }

    /// Cancels the in-flight capture immediately (Esc, or the capture hotkey pressed again) — also while
    /// still in the popover delay or awaiting ScreenCaptureKit, and for fullscreen, which has no HUD.
    /// Scrolling capture is the exception once the region is locked: Esc finishes instead (see `handleEscape`).
    func cancelCapture() {
        guard let session = captureSession else { return }
        captureTask?.cancel()
        session.cancel()
        endCapture()
        handle(.cancelled)
    }

    /// Global Esc. During region / window / fullscreen, and during scrolling *selection*, this cancels.
    /// After a scrolling region is locked, Esc ends the capture and keeps the stitched image.
    private func handleEscape() {
        if escapeFinishesScrolling {
            captureSession?.finishActiveScrolling()
        } else {
            cancelCapture()
        }
    }

    private func endCapture() {
        hotkeys.endEscapeMonitoring()
        escapeFinishesScrolling = false
        captureSession = nil
        captureTask = nil
    }

    /// Called by the status item right before it activates PrettyShot to show the popover.
    func popoverWillShow() {
        appBeforePopover = Self.externalFrontmost() ?? appBeforePopover
    }

    private func focusTarget(for trigger: CaptureTrigger) -> NSRunningApplication? {
        let popoverApp = appBeforePopover.flatMap { $0.isTerminated ? nil : $0 }
        switch trigger {
        case .popover: return popoverApp ?? Self.externalFrontmost()
        case .hotkey, .window: return Self.externalFrontmost() ?? popoverApp
        }
    }

    private static func externalFrontmost() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
    }

    private func handle(_ outcome: CaptureSession.Outcome) {
        switch outcome {
        case .captured(let result):
            returnToHistoryOnCancel = false
            if let notice = result.notice {
                ToastPresenter.shared.show(notice, style: .info, duration: 5)
            }
            deliverCaptured(image: result.image, scale: result.scale, mode: result.mode, assembly: result.scrollingAssembly)
        case .reviewScrolling(let review):
            returnToHistoryOnCancel = false
            if let notice = review.notice {
                ToastPresenter.shared.show(notice, style: .info, duration: 5)
            }
            showStitchPreview(review)
        case .cancelled:
            restoreFocus()
            resumeHistoryIfNeeded()
        case .failed(let error):
            if case .permissionDenied = error {
                permissions.refresh()
                showPermission(detail: error.errorDescription)
            } else {
                ToastPresenter.shared.show(error.errorDescription ?? "捕获失败", style: .error, duration: 4)
            }
            resumeHistoryIfNeeded()
        }
    }

    private func deliverCaptured(image: CGImage, scale: CGFloat, mode: CaptureMode, assembly: ScrollAssembly? = nil) {
        do {
            var item = try history.add(image: image, scale: scale, mode: mode)
            if let assembly, assembly.hasStickyRepeats {
                try history.saveStitch(assembly, for: item)
                item = history.items.first(where: { $0.id == item.id }) ?? item
            }
            showOverlay(for: item, image: image)
        } catch {
            // Still let the user copy what they captured even if history is unwritable.
            Clipboard.copy(image, scale: scale)
            ToastPresenter.shared.show("无法写入历史，已直接复制到剪贴板：\(error.localizedDescription)", style: .error, duration: 4)
        }
    }

    private func showStitchPreview(_ review: ScrollingReview) {
        let controller = StitchPreviewController(review: review)
        controller.onCommit = { [weak self] image, assembly in
            guard let self else { return }
            self.stitchPreview = nil
            self.deliverCaptured(image: image, scale: review.scale, mode: .scrolling, assembly: assembly)
        }
        controller.onExportSegments = { [weak self] images in
            guard let self else { return }
            self.stitchPreview = nil
            var first: (HistoryItem, CGImage)?
            var failed = 0
            for image in images {
                do {
                    let item = try self.history.add(image: image, scale: review.scale, mode: .scrolling)
                    if first == nil { first = (item, image) }
                } catch {
                    failed += 1
                }
            }
            if failed > 0 {
                ToastPresenter.shared.show("有 \(failed) 段没有写入历史", style: .error, duration: 4)
            } else if images.count > 1 {
                ToastPresenter.shared.show("已把 \(images.count) 段分别放进历史", style: .success, duration: 4)
            }
            if let first {
                self.showOverlay(for: first.0, image: first.1)
            } else if let image = images.first {
                self.deliverCaptured(image: image, scale: review.scale, mode: .scrolling)
            }
        }
        controller.onDiscard = { [weak self] in
            self?.stitchPreview = nil
            ToastPresenter.shared.show("已关闭拼接预览，这次长图没有保存", style: .info, duration: 3)
            self?.restoreFocus()
        }
        stitchPreview = controller
        controller.present()
    }

    /// Leave History only after permission is confirmed, so a denied grant does not close the page.
    private func startCaptureFromHistory() {
        permissions.refresh()
        guard permissions.screenCaptureGranted else {
            permissions.requestIfNeeded()
            showPermission(detail: nil)
            return
        }
        returnToHistoryOnCancel = true
        historyWindow?.orderOut(nil)
        startCapture(.region, trigger: .window)
    }

    private func resumeHistoryIfNeeded() {
        guard returnToHistoryOnCancel else { return }
        returnToHistoryOnCancel = false
        present(historyWindow)
    }

    // MARK: - Quick Overlay

    private func showOverlay(for item: HistoryItem, image: CGImage) {
        if let assembly = history.cachedStitch(for: item) {
            presentOverlay(for: item, image: image, assembly: assembly)
            return
        }
        // A stitch sidecar is the only reason to touch disk. Load it once, off the main thread.
        guard item.hasStickyRestore else {
            presentOverlay(for: item, image: image, assembly: nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let assembly = await self.history.loadStitchForOverlay(item)
            self.presentOverlay(for: item, image: image, assembly: assembly)
        }
    }

    private func presentOverlay(for item: HistoryItem, image: CGImage, assembly: ScrollAssembly?) {
        let scale = CGFloat(item.scale)
        let dragURL = dragCopy(of: item) ?? history.url(for: item)
        let chip = stickyChip(from: assembly)
        overlay.show(
            image: ImageCodec.nsImage(Self.overlayPreview(of: image), scale: scale),
            fileURL: dragURL,
            actions: QuickOverlayActions(
                copy: { [weak self] in
                    guard let self, self.copy(image: image, scale: scale) else { return false }
                    self.restoreFocus()
                    return true
                },
                annotate: { [weak self] in
                    self?.overlay.hide()
                    self?.openEditor(image: image, scale: scale, mode: item.mode, historyID: item.id)
                },
                save: { [weak self] in self?.save(image: image) },
                pin: { [weak self] in self?.pins.pin(image: image, scale: scale) },
                dismiss: { [weak self] in self?.restoreFocus() },
                stickyChip: chip,
                onStickyChip: chip == nil ? nil : { [weak self] in
                    self?.handleStickyChip(for: item, fromOverlay: true)
                }
            )
        )
    }

    /// Deduped stitch offers restore; a restored stitch offers undo. Nil when this image has no sticky bars.
    private func stickyChip(from assembly: ScrollAssembly?) -> OverlayStickyChip? {
        guard let assembly,
              assembly.hasStickyRepeats,
              assembly.pendingSticky?.isUnresolved != true else { return nil }
        return assembly.dedupeStickyBars ? .deduped : .restored
    }

    private func handleStickyChip(for item: HistoryItem, fromOverlay: Bool) {
        guard let assembly = history.loadStitch(for: item) else { return }
        if assembly.dedupeStickyBars {
            restoreStickyBars(for: item, fromOverlay: fromOverlay)
        } else {
            undoStickyBars(for: item, fromOverlay: fromOverlay)
        }
    }

    /// Puts the deduped image back after a restore on this history item.
    private func undoStickyBars(for item: HistoryItem, fromOverlay: Bool) {
        guard var assembly = history.loadStitch(for: item) else { return }
        assembly.confirmStickyBars(keepOnce: true)
        guard let image = assembly.flattenedIfResolved()?.cgImage() else { return }
        do {
            try history.replaceImage(of: item.id, with: image)
            if let updated = history.items.first(where: { $0.id == item.id }) {
                try history.saveStitch(assembly, for: updated)
                if fromOverlay {
                    showOverlay(for: updated, image: image)
                }
            }
        } catch {
            ToastPresenter.shared.show(StitchCopy.restoreFailed(error.localizedDescription), style: .error, duration: 4)
        }
    }

    /// Restores sticky bars on this history image only. Over the single-image cap, offers a split export.
    private func restoreStickyBars(for item: HistoryItem, fromOverlay: Bool) {
        guard var assembly = history.loadStitch(for: item) else { return }
        switch assembly.restoreStickyBars() {
        case .restored:
            guard let image = assembly.flattenedIfResolved()?.cgImage() else { return }
            do {
                try history.replaceImage(of: item.id, with: image)
                if let updated = history.items.first(where: { $0.id == item.id }) {
                    try history.saveStitch(assembly, for: updated)
                }
            } catch {
                ToastPresenter.shared.show(StitchCopy.restoreFailed(error.localizedDescription), style: .error, duration: 4)
                return
            }
            if fromOverlay, let updated = history.items.first(where: { $0.id == item.id }) {
                showOverlay(for: updated, image: image)
            }
        case .exceedsLimit(_, let message):
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = StitchCopy.overLimitNote
            alert.addButton(withTitle: StitchCopy.exportSegments)
            alert.addButton(withTitle: StitchCopy.keepDedupe)
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            let chunks = assembly.exportWithinLimits(dedupeStickyBars: false)
            guard !chunks.isEmpty else { return }
            var saved = 0
            for chunk in chunks {
                guard let image = chunk.cgImage() else { continue }
                if (try? history.add(image: image, scale: CGFloat(item.scale), mode: .scrolling)) != nil {
                    saved += 1
                }
            }
            ToastPresenter.shared.show(StitchCopy.savedSegments(saved), style: .success, duration: 4)
        case .alreadyRestored, .nothingToRestore:
            break
        }
    }

    /// The overlay is a small thumbnail. Very tall scrolling captures stay full size for copy / edit / save,
    /// but the panel itself only holds a bounded preview so a long image isn't uploaded to the window server twice.
    private static func overlayPreview(of image: CGImage) -> CGImage {
        let pixels = Int64(image.width) * Int64(image.height)
        guard max(image.width, image.height) > 1600 || pixels > 1_600_000 else { return image }
        return Redactor.previewSource(for: image, maxSide: 1600, maxPixels: 1_600_000)?.image ?? image
    }

    /// Drag-out uses a nicely named temp copy ("PrettyShot 2026-09-27 at 10.35.06.png") instead of the UUID file.
    private func dragCopy(of item: HistoryItem) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrettyShot-Drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(FileNaming.screenshotName(date: item.createdAt))
        if !FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.copyItem(at: history.url(for: item), to: target)
            } catch {
                return nil
            }
        }
        return target
    }

    private func restoreFocus() {
        _ = appBeforeCapture?.activate(options: [])
    }

    // MARK: - Actions

    @discardableResult
    func copy(image: CGImage, scale: CGFloat) -> Bool {
        let ok = Clipboard.copy(image, scale: scale)
        if ok {
            if preferences.copySoundEnabled { NSSound(named: "Pop")?.play() }
        } else {
            ToastPresenter.shared.show("复制失败，请重试", style: .error)
        }
        return ok
    }

    func save(image: CGImage) {
        let directory = preferences.saveDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = FileNaming.uniqueURL(in: directory)
            try ImageCodec.writePNG(image, to: url)
            ToastPresenter.shared.show("已保存到 \(directory.lastPathComponent) · \(url.lastPathComponent)", style: .success)
        } catch {
            ToastPresenter.shared.show("保存失败：\(error.localizedDescription)", style: .error, duration: 4)
        }
    }

    func pinLatest() {
        guard let item = history.latest, let image = history.image(for: item) else {
            ToastPresenter.shared.show("还没有截图可以 Pin", style: .info)
            return
        }
        pins.pin(image: image, scale: CGFloat(item.scale))
    }

    // MARK: - Editor

    func openEditor(image: CGImage, scale: CGFloat, mode: CaptureMode, historyID: UUID?) {
        let document = EditorDocument(
            image: image,
            scale: scale,
            mode: mode,
            background: preferences.background,
            sourceHistoryID: historyID
        )
        document.onBackgroundChange = { [weak self] style in self?.preferences.background = style }

        let actions = EditorActions(
            copy: { [weak self] doc in
                guard let self, let output = self.finalize(doc) else { return false }
                return self.copy(image: output, scale: doc.scale)
            },
            export: { [weak self] doc in self?.export(doc) },
            pin: { [weak self] doc in
                guard let self, let output = self.finalize(doc) else { return }
                self.pins.pin(image: output, scale: doc.scale)
            }
        )

        let controller = EditorWindowController(document: document, actions: actions)
        controller.onClose = { [weak self] closed in
            self?.editors.removeAll { $0 === closed }
        }
        editors.append(controller)
        controller.present()
    }

    func openEditor(for item: HistoryItem) {
        guard let image = history.image(for: item) else {
            ToastPresenter.shared.show("找不到这张截图的文件", style: .error)
            return
        }
        openEditor(image: image, scale: CGFloat(item.scale), mode: item.mode, historyID: item.id)
    }

    /// Renders the editor result and records it in History (one entry per editor session, overwritten on re-export).
    private func finalize(_ doc: EditorDocument) -> CGImage? {
        guard let output = doc.exportImage() else {
            ToastPresenter.shared.show("渲染失败", style: .error)
            return nil
        }
        if let existing = doc.exportedHistoryID, (try? history.replaceImage(of: existing, with: output)) != nil {
            return output
        }
        if let item = try? history.add(image: output, scale: doc.scale, mode: doc.mode, edited: true) {
            doc.exportedHistoryID = item.id
        }
        return output
    }

    private func export(_ doc: EditorDocument) {
        guard let output = finalize(doc) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = FileNaming.screenshotName()
        panel.directoryURL = preferences.saveDirectory
        panel.canCreateDirectories = true
        NSApp.activate()
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ImageCodec.writePNG(output, to: url)
                ToastPresenter.shared.show("已导出 \(url.lastPathComponent)", style: .success)
            } catch {
                ToastPresenter.shared.show("导出失败：\(error.localizedDescription)", style: .error, duration: 4)
            }
        }
        if let window = editors.first(where: { $0.editorDocument === doc })?.window {
            panel.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(panel.runModal())
        }
    }

    // MARK: - Windows

    func showHistory() {
        statusItem?.closePopover()
        if historyWindow == nil {
            let view = HistoryView(
                store: history,
                hotkeys: hotkeys,
                actions: HistoryActions(
                    open: { [weak self] item in self?.openEditor(for: item) },
                    pin: { [weak self] item in
                        guard let self, let image = self.history.image(for: item) else { return }
                        self.pins.pin(image: image, scale: CGFloat(item.scale))
                    },
                    copy: { [weak self] item in
                        guard let self, let image = self.history.image(for: item) else { return }
                        if self.copy(image: image, scale: CGFloat(item.scale)) {
                            ToastPresenter.shared.show("已复制到剪贴板", style: .success)
                        }
                    },
                    reveal: { [weak self] item in
                        guard let self else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([self.history.url(for: item)])
                    },
                    captureRegion: { [weak self] in
                        self?.startCaptureFromHistory()
                    },
                    restoreSticky: { [weak self] item in
                        self?.restoreStickyBars(for: item, fromOverlay: false)
                    }
                )
            )
            historyWindow = makeWindow(title: "PrettyShot History", size: NSSize(width: 820, height: 580), root: view)
        }
        present(historyWindow)
    }

    func showSettings() {
        statusItem?.closePopover()
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences, hotkeys: hotkeys, permissions: permissions, history: history)
            settingsWindow = makeWindow(title: "PrettyShot 设置", size: NSSize(width: 580, height: 520), root: view, resizable: false)
        }
        present(settingsWindow)
    }

    func showPermission(detail: String?) {
        statusItem?.closePopover()
        permissionWindow?.close()
        let view = PermissionView(
            permissions: permissions,
            detail: detail,
            onLater: { [weak self] in self?.permissionWindow?.close() },
            onRetryCapture: { [weak self] in
                self?.permissionWindow?.close()
                self?.startCapture(.region, trigger: .window)
            }
        )
        permissionWindow = makeWindow(title: "PrettyShot · 权限", size: NSSize(width: 520, height: 520), root: view, resizable: false)
        present(permissionWindow)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, root: Content, resizable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
