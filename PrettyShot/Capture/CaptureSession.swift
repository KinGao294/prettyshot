import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

@MainActor
final class CaptureHUDModel: ObservableObject {
    @Published var mode: CaptureMode

    init(mode: CaptureMode) {
        self.mode = mode
    }
}

/// One capture attempt: freezes all screens, shows the Capture HUD (F2) and resolves to an outcome.
@MainActor
final class CaptureSession {
    enum Outcome {
        case captured(CaptureResult)
        /// Scrolling capture ended with at least one seam that was not safe to join automatically.
        case reviewScrolling(ScrollingReview)
        case cancelled
        case failed(CaptureError)
    }

    private let service: ScreenCaptureService
    private let model: CaptureHUDModel
    /// Right after a Screen Recording grant ScreenCaptureKit can hand back black frames; retry once.
    private let retryBlankFrames: Bool
    private var overlays: [CaptureOverlayWindow] = []
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var finished = false
    /// Set by `cancel()` at any point — also before `run()` has reached the HUD (no continuation yet).
    private var cancelled = false
    private var scrolling: ScrollingCaptureController?
    /// Fired once the region is locked and scrolling capture is running. Esc should finish, not discard.
    var onScrollingBegan: (() -> Void)?

    init(mode: CaptureMode, service: ScreenCaptureService, retryBlankFrames: Bool = false) {
        self.service = service
        self.model = CaptureHUDModel(mode: mode)
        self.retryBlankFrames = retryBlankFrames
    }

    var isCancelled: Bool { cancelled || Task.isCancelled }

    /// Resolves to `.cancelled` whenever `cancel()` was called or the calling task was cancelled —
    /// checked before and after every await, so a cancelled session never yields `.captured`.
    func run() async -> Outcome {
        guard !isCancelled else { return finishedCancelled() }
        do {
            if model.mode == .fullscreen {
                let result = try await captureFullscreen()
                guard !isCancelled else { return finishedCancelled() }
                finished = true
                return .captured(result)
            }
            let (snapshots, windows) = try await snapshotAll()
            guard !isCancelled else { return finishedCancelled() }
            let outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                    if self.finished || self.isCancelled {
                        continuation.resume(returning: .cancelled)
                        return
                    }
                    self.continuation = continuation
                    self.present(snapshots: snapshots, windows: windows)
                }
            } onCancel: {
                Task { @MainActor in self.cancel() }
            }
            return isCancelled ? .cancelled : outcome
        } catch {
            guard !isCancelled else { return finishedCancelled() }
            finished = true
            return .failed(ScreenCaptureService.map(error))
        }
    }

    func cancel() {
        cancelled = true
        finish(.cancelled)
    }

    /// Esc during an active scrolling capture: stitch and finish instead of discarding.
    func finishActiveScrolling() {
        scrolling?.finish()
    }

    private func finishedCancelled() -> Outcome {
        finish(.cancelled)
        return .cancelled
    }

    // MARK: - Capture (with one retry for fresh-grant blank frames)

    private func captureFullscreen() async throws -> CaptureResult {
        let screen = NSScreen.underMouse
        for attempt in 0...1 {
            let content = try await shareableContent()
            try checkCancelled()
            let result = try await service.captureScreen(screen, content: content)
            try checkCancelled()
            guard retryBlankFrames, ScreenCaptureService.looksBlank(result.image) else { return result }
            if attempt == 0 { try await pauseBeforeRetry() }
        }
        throw CaptureError.notReady
    }

    private func snapshotAll() async throws -> ([ScreenSnapshot], [CapturableWindow]) {
        for attempt in 0...1 {
            let content = try await shareableContent()
            try checkCancelled()
            let snapshots = try await service.snapshotAllScreens(content: content)
            try checkCancelled()
            if !retryBlankFrames || !snapshots.allSatisfy({ ScreenCaptureService.looksBlank($0.image) }) {
                return (snapshots, WindowCatalog.windows(from: content))
            }
            if attempt == 0 { try await pauseBeforeRetry() }
        }
        throw CaptureError.notReady
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            let content = try await service.shareableContent()
            if !content.displays.isEmpty || !retryBlankFrames { return content }
        } catch CaptureError.permissionDenied {
            throw CaptureError.permissionDenied
        } catch {
            if !retryBlankFrames { throw error }
        }
        // Fresh grant: the display list is sometimes empty / erroring for a moment.
        try await pauseBeforeRetry()
        return try await service.shareableContent()
    }

    private func pauseBeforeRetry() async throws {
        try await Task.sleep(nanoseconds: 450_000_000)
        try checkCancelled()
    }

    private func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }

    // MARK: - HUD

    private func present(snapshots: [ScreenSnapshot], windows: [CapturableWindow]) {
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        var keyWindow: CaptureOverlayWindow?

        for snapshot in snapshots {
            let view = CaptureSelectionView(snapshot: snapshot, windows: windows, model: model)
            view.onRegion = { [weak self] rect in
                guard let self else { return }
                if self.model.mode == .scrolling {
                    self.beginScrolling(rect, snapshot: snapshot)
                } else {
                    self.finishRegion(rect, in: snapshot)
                }
            }
            view.onWindow = { [weak self] window in self?.finishWindow(window, fallback: snapshot) }
            view.onFullscreen = { [weak self] in
                self?.finish(.captured(CaptureResult(image: snapshot.image, scale: snapshot.scale, mode: .fullscreen)))
            }
            view.onCancel = { [weak self] in self?.finish(.cancelled) }

            let window = CaptureOverlayWindow.make(frame: snapshot.screen.frame, content: view)
            overlays.append(window)
            window.orderFrontRegardless()
            if NSMouseInRect(mouse, snapshot.screen.frame, false) { keyWindow = window }
        }
        (keyWindow ?? overlays.first)?.makeKeyAndOrderFront(nil)
    }

    private func finishRegion(_ rect: CGRect, in snapshot: ScreenSnapshot) {
        let pixelRect = CaptureGeometry.pixelRect(
            for: rect,
            viewSize: snapshot.screen.frame.size,
            imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height)
        )
        guard !pixelRect.isEmpty, let cropped = snapshot.image.cropping(to: pixelRect) else {
            finish(.failed(.failed("选区无效")))
            return
        }
        finish(.captured(CaptureResult(image: cropped, scale: snapshot.scale, mode: .region)))
    }

    private func finishWindow(_ window: CapturableWindow, fallback snapshot: ScreenSnapshot) {
        overlays.forEach { $0.orderOut(nil) }
        Task { @MainActor in
            do {
                finish(.captured(try await service.captureWindow(window.scWindow)))
            } catch {
                // Fall back to the frozen frame so the user still gets what they clicked.
                let local = window.frame.offsetBy(dx: -snapshot.screen.frame.minX, dy: -snapshot.screen.frame.minY)
                let pixelRect = CaptureGeometry.pixelRect(
                    for: local,
                    viewSize: snapshot.screen.frame.size,
                    imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height)
                )
                if !pixelRect.isEmpty, let cropped = snapshot.image.cropping(to: pixelRect) {
                    finish(.captured(CaptureResult(image: cropped, scale: snapshot.scale, mode: .window)))
                } else {
                    finish(.failed(ScreenCaptureService.map(error)))
                }
            }
        }
    }

    private func beginScrolling(_ rect: CGRect, snapshot: ScreenSnapshot) {
        guard rect.width >= 24, rect.height >= 48 else {
            finish(.failed(.failed("滚动区域太小，请框选更高的一块")))
            return
        }
        let local = rect.intersection(CGRect(origin: .zero, size: snapshot.screen.frame.size))
        let sourceRect = ScrollingCaptureGeometry.sourceRect(selection: local, screenSize: snapshot.screen.frame.size)
        guard !sourceRect.isNull, sourceRect.width >= 24, sourceRect.height >= 48 else {
            finish(.failed(.failed("滚动区域太小，请框选更高的一块")))
            return
        }
        let pixelWidth = max(1, Int((sourceRect.width * snapshot.scale).rounded()))
        let pixelHeight = max(1, Int((sourceRect.height * snapshot.scale).rounded()))
        // Drop the frozen HUD so the user can scroll the real page. Our chrome is excluded from capture.
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()

        let global = local.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
        let controller = ScrollingCaptureController(service: service)
        scrolling = controller
        onScrollingBegan?()
        controller.onComplete = { [weak self] output in
            guard let self else { return }
            let notice = output.reachedLimit ? ScrollOutputLimit.notice : nil
            if output.assembly.needsReview {
                self.finish(.reviewScrolling(ScrollingReview(scale: snapshot.scale, assembly: output.assembly, notice: notice)))
            } else if let image = output.assembly.flattenedIfResolved()?.cgImage() {
                self.finish(.captured(CaptureResult(image: image, scale: snapshot.scale, mode: .scrolling, notice: notice)))
            } else {
                self.finish(.failed(.failed("没有可保存的画面")))
            }
        }
        controller.onCancel = { [weak self] in
            self?.finish(.cancelled)
        }
        controller.onFail = { [weak self] error in
            self?.finish(.failed(error))
        }
        controller.start(
            screen: snapshot.screen,
            globalRect: global,
            sourceRect: sourceRect,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        scrolling?.stop()
        scrolling = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

enum CaptureGeometry {
    /// Converts a rect in a screen-sized view (points, y-up) to a pixel rect in the frozen image (y-down).
    static func pixelRect(for rect: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .null }
        let sx = imageSize.width / viewSize.width
        let sy = imageSize.height / viewSize.height
        let converted = CGRect(
            x: rect.minX * sx,
            y: (viewSize.height - rect.maxY) * sy,
            width: rect.width * sx,
            height: rect.height * sy
        ).integral
        return converted.intersection(CGRect(origin: .zero, size: imageSize))
    }
}

// MARK: - Overlay window

final class CaptureOverlayWindow: NSWindow {
    static func make(frame: CGRect, content: NSView) -> CaptureOverlayWindow {
        let window = CaptureOverlayWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = content
        return window
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Selection view

final class CaptureSelectionView: NSView {
    var onRegion: ((CGRect) -> Void)?
    var onWindow: ((CapturableWindow) -> Void)?
    var onFullscreen: (() -> Void)?
    var onCancel: (() -> Void)?

    private let snapshot: ScreenSnapshot
    private let windows: [CapturableWindow]
    private let localFrames: [CGRect]
    private let model: CaptureHUDModel
    private var cancellable: AnyCancellable?

    /// Local copy of the HUD mode (the publisher fires on willSet, so read the value it delivers).
    private var mode: CaptureMode
    private var dragStart: NSPoint?
    private var selection: NSRect?
    private var hoveredIndex: Int?

    private let rose = NSColor(hex: 0xE8A0A8)
    private let chrome = NSColor(hex: 0x1C1C1E, alpha: 0.88)
    private let ivory = NSColor(hex: 0xF5F2EC)

    init(snapshot: ScreenSnapshot, windows: [CapturableWindow], model: CaptureHUDModel) {
        self.snapshot = snapshot
        self.windows = windows
        self.model = model
        let origin = snapshot.screen.frame.origin
        self.localFrames = windows.map { $0.frame.offsetBy(dx: -origin.x, dy: -origin.y) }
        self.mode = model.mode
        super.init(frame: NSRect(origin: .zero, size: snapshot.screen.frame.size))

        let bar = NSHostingView(rootView: CaptureModeBar(model: model) { [weak self] mode in
            guard let self else { return }
            if mode == .fullscreen {
                self.onFullscreen?()
            } else {
                self.model.mode = mode
            }
        })
        let size = bar.fittingSize
        bar.frame = NSRect(x: (bounds.width - size.width) / 2, y: 56, width: size.width, height: size.height)
        bar.autoresizingMask = [.minXMargin, .maxXMargin]
        addSubview(bar)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))

        cancellable = model.$mode.dropFirst().sink { [weak self] newMode in
            self?.modeDidChange(to: newMode)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if let window {
            updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .region || mode == .scrolling ? .crosshair : .pointingHand)
    }

    private func modeDidChange(to newMode: CaptureMode) {
        mode = newMode
        selection = nil
        dragStart = nil
        window?.invalidateCursorRects(for: self)
        if let window {
            updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        needsDisplay = true
    }

    // MARK: Events

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .region || mode == .scrolling else { return }
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region || mode == .scrolling, let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let rect = NSRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        )
        selection = rect.intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .region, .scrolling:
            defer { dragStart = nil }
            if let selection, selection.width >= 4, selection.height >= 4 {
                onRegion?(selection)
            } else {
                selection = nil
                needsDisplay = true
            }
        case .window:
            if let index = hoveredIndex { onWindow?(windows[index]) }
        case .fullscreen:
            onFullscreen?()
        }
    }

    private func updateHover(at point: NSPoint) {
        guard mode == .window else {
            if hoveredIndex != nil { hoveredIndex = nil; needsDisplay = true }
            return
        }
        let index = localFrames.firstIndex { $0.contains(point) }
        if index != hoveredIndex {
            hoveredIndex = index
            needsDisplay = true
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(snapshot.image, in: bounds)

        let highlight: NSRect? = {
            switch mode {
            case .region, .scrolling: return selection
            case .window: return hoveredIndex.map { localFrames[$0].intersection(bounds) }
            case .fullscreen: return nil
            }
        }()

        let dim = NSBezierPath(rect: bounds)
        if let highlight {
            dim.append(NSBezierPath(rect: highlight))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.38).setFill()
        dim.fill()

        if let highlight {
            if mode == .window {
                rose.withAlphaComponent(0.14).setFill()
                NSBezierPath(rect: highlight).fill()
            }
            let border = NSBezierPath(rect: highlight.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            rose.setStroke()
            border.stroke()

            if mode == .region || mode == .scrolling {
                drawHandles(around: highlight)
            }
            drawSizeLabel(for: highlight)
        }

        drawHint()
    }

    private func drawHandles(around rect: NSRect) {
        let corners = [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
        ]
        for corner in corners {
            let handle = NSBezierPath(ovalIn: NSRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8))
            ivory.setFill()
            handle.fill()
            rose.setStroke()
            handle.lineWidth = 1.5
            handle.stroke()
        }
    }

    private func drawSizeLabel(for rect: NSRect) {
        let scale = snapshot.scale
        var text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
        if mode == .window, let index = hoveredIndex {
            let name = windows[index].appName
            if !name.isEmpty { text = "\(name) · \(text)" }
        }
        let origin = NSPoint(x: rect.minX, y: rect.minY - 30 >= 0 ? rect.minY - 30 : rect.minY + 8)
        drawPill(text, at: origin)
    }

    private func drawHint() {
        let text: String
        switch mode {
        case .region: text = "拖拽选择区域 · Esc 取消"
        case .window: text = "点击选择窗口 · Esc 取消"
        case .fullscreen: text = "点击捕获全屏 · Esc 取消"
        case .scrolling: text = "拖拽选择滚动区域 · Esc 取消"
        }
        let attributed = pillText(text)
        let size = attributed.size()
        drawPill(text, at: NSPoint(x: bounds.midX - (size.width + 20) / 2, y: bounds.maxY - 72))
    }

    private func pillText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: ivory,
        ])
    }

    private func drawPill(_ text: String, at origin: NSPoint) {
        let attributed = pillText(text)
        let size = attributed.size()
        let rect = NSRect(x: origin.x, y: origin.y, width: size.width + 20, height: size.height + 10)
        chrome.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        attributed.draw(at: NSPoint(x: rect.minX + 10, y: rect.minY + 5))
    }
}

/// Mode chips at the bottom of the HUD: 区域 / 窗口 / 全屏 (F2).
@MainActor
struct CaptureModeBar: View {
    @ObservedObject var model: CaptureHUDModel
    let onSelect: (CaptureMode) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CaptureMode.allCases) { mode in
                let active = model.mode == mode
                Button {
                    onSelect(mode)
                } label: {
                    Label(mode.chipTitle, systemImage: mode.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(active ? Palette.charcoal : Palette.ivory)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(active ? Palette.bloomRose : Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(FrostedChrome(cornerRadius: 22))
    }
}
