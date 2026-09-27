import AppKit
import Combine
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
    private var editors: [EditorWindowController] = []
    private var historyWindow: NSWindow?
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
        hotkeys.onEscape = { [weak self] in self?.cancelCapture() }
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
    func cancelCapture() {
        guard let session = captureSession else { return }
        captureTask?.cancel()
        session.cancel()
        endCapture()
        handle(.cancelled)
    }

    private func endCapture() {
        hotkeys.endEscapeMonitoring()
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
            do {
                let item = try history.add(image: result.image, scale: result.scale, mode: result.mode)
                showOverlay(for: item, image: result.image)
            } catch {
                // Still let the user copy what they captured even if history is unwritable.
                Clipboard.copy(result.image, scale: result.scale)
                ToastPresenter.shared.show("无法写入历史，已直接复制到剪贴板：\(error.localizedDescription)", style: .error, duration: 4)
            }
        case .cancelled:
            restoreFocus()
        case .failed(let error):
            if case .permissionDenied = error {
                permissions.refresh()
                showPermission(detail: error.errorDescription)
            } else {
                ToastPresenter.shared.show(error.errorDescription ?? "捕获失败", style: .error, duration: 4)
            }
        }
    }

    // MARK: - Quick Overlay

    private func showOverlay(for item: HistoryItem, image: CGImage) {
        let scale = CGFloat(item.scale)
        let dragURL = dragCopy(of: item) ?? history.url(for: item)
        overlay.show(
            image: ImageCodec.nsImage(image, scale: scale),
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
                dismiss: { [weak self] in self?.restoreFocus() }
            )
        )
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
        if let window = editors.first(where: { $0.document === doc })?.window {
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
                        self?.historyWindow?.orderOut(nil)
                        self?.startCapture(.region, trigger: .window)
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
            settingsWindow = makeWindow(title: "PrettyShot 设置", size: NSSize(width: 580, height: 440), root: view, resizable: false)
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
