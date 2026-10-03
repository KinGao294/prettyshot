import AppKit
import CoreMedia
import ScreenCaptureKit
import SwiftUI

/// Manual scrolling only. Auto-scroll is off on purpose (it may need Accessibility permission and
/// is still waiting on a product decision). `driveScroll()` returns immediately while this is false.
enum ScrollingCaptureFeature {
    static let autoScrollEnabled = false
}

struct ScrollingCaptureOutput {
    var assembly: ScrollAssembly
    var reachedLimit: Bool
}

/// Live scrolling capture for one selected rectangle.
///
/// Esc while the region is still being dragged cancels, same as the other modes. Once the region
/// is locked, Esc and the Stop button both finish. The Cancel button (or pressing the scrolling
/// shortcut again) discards it. The page underneath keeps keyboard focus, so Esc arrives through
/// the global hotkey rather than this panel.
@MainActor
final class ScrollingCaptureController {
    var onComplete: ((ScrollingCaptureOutput) -> Void)?
    var onCancel: (() -> Void)?
    var onFail: ((CaptureError) -> Void)?

    private let model = ScrollingCaptureModel()
    private var stitcher = ScrollStitcher()
    private var hitLimit = false
    private var pump: RegionFramePump?
    private var panel: NSPanel?
    private var borderWindow: NSWindow?
    private var closed = false
    private var sawFrame = false
    private let service: ScreenCaptureService

    init(service: ScreenCaptureService) {
        self.service = service
    }

    func start(screen: NSScreen, globalRect: CGRect, sourceRect: CGRect, pixelWidth: Int, pixelHeight: Int) {
        driveScroll()
        presentChrome(on: screen, around: globalRect)
        let pump = RegionFramePump()
        self.pump = pump
        pump.onFrame = { [weak self] frame in
            Task { @MainActor in self?.ingest(frame) }
        }
        pump.onInterrupted = { [weak self] error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if self.stitcher.hasFrame {
                    self.finish()
                } else {
                    self.fail(.failed(error.localizedDescription))
                }
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (filter, config) = try await self.service.regionStreamSetup(
                    for: screen,
                    sourceRect: sourceRect,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight
                )
                guard !self.closed else { return }
                try await pump.start(filter: filter, configuration: config)
            } catch {
                guard !self.closed else { return }
                self.fail(ScreenCaptureService.map(error))
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !self.closed, !self.sawFrame else { return }
            self.fail(.failed("没有收到画面，请确认屏幕录制权限后重试"))
        }
    }

    /// Esc / Stop. Hands back the segments. Confident runs are already stitched; uncertain seams are not.
    func finish() {
        guard !closed else { return }
        closed = true
        tearDown()
        var stitcher = self.stitcher
        let assembly = stitcher.takeAssembly()
        guard !assembly.segments.isEmpty else {
            onFail?(.failed("还没有捕获到画面"))
            return
        }
        onComplete?(ScrollingCaptureOutput(assembly: assembly, reachedLimit: hitLimit))
    }

    /// No-op while `ScrollingCaptureFeature.autoScrollEnabled` is false.
    private func driveScroll() {
        guard ScrollingCaptureFeature.autoScrollEnabled else { return }
    }

    /// Discard. Does not call back; `CaptureSession.cancel()` owns the cancelled outcome.
    func stop() {
        guard !closed else { return }
        closed = true
        tearDown()
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        tearDown()
        onCancel?()
    }

    // MARK: - Frames

    private func ingest(_ frame: RGBAImage) {
        guard !closed else { return }
        sawFrame = true
        let outcome = stitcher.ingest(frame)
        refreshCounters()
        switch outcome {
        case .seeded:
            model.status = "滚动此区域内的页面"
        case .appended, .prepended:
            model.status = "已拼接 \(stitcher.pixelHeight) px"
        case .unchanged, .ignored:
            break
        case .unmatched:
            model.status = "已另起一段"
        case .reachedLimit:
            hitLimit = true
            model.status = "已达到长度上限"
            model.warning = ScrollOutputLimit.notice
            finish()
        }
    }

    private func refreshCounters() {
        model.frameCount = stitcher.acceptedFrames
        model.segmentCount = stitcher.segmentCount
        model.stitchedPixels = stitcher.pixelHeight
        if stitcher.unmatchedBreaks > 0 {
            model.warning = "有 \(stitcher.unmatchedBreaks) 处对不齐。画面可能在变（动画、加载或滚得太快），已另起一段，不会自动硬接。"
        }
    }

    private func fail(_ error: CaptureError) {
        guard !closed else { return }
        closed = true
        tearDown()
        onFail?(error)
    }

    private func tearDown() {
        pump?.stop()
        pump = nil
        panel?.orderOut(nil)
        panel = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
    }

    // MARK: - Chrome

    private func presentChrome(on screen: NSScreen, around globalRect: CGRect) {
        let border = RegionBorderWindow(frame: globalRect.insetBy(dx: -3, dy: -3))
        border.orderFrontRegardless()
        borderWindow = border

        let host = NSHostingView(rootView: ScrollingCapturePanel(model: model, onDone: { [weak self] in
            self?.finish()
        }, onCancel: { [weak self] in
            self?.cancel()
        }))
        let size = NSSize(width: 320, height: 196)
        host.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host
        panel.setFrameOrigin(panelOrigin(size: size, around: globalRect, on: screen))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Prefer below the region so the control doesn't cover the page being scrolled.
    private func panelOrigin(size: NSSize, around rect: CGRect, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 16)
        if origin.y < visible.minY + 8 {
            origin.y = min(rect.maxY + 16, visible.maxY - size.height - 8)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return origin
    }
}

@MainActor
final class ScrollingCaptureModel: ObservableObject {
    @Published var status = "准备捕获…"
    @Published var frameCount = 0
    @Published var segmentCount = 0
    @Published var stitchedPixels = 0
    @Published var warning: String?
}

@MainActor
private struct ScrollingCapturePanel: View {
    @ObservedObject var model: ScrollingCaptureModel
    var onDone: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("滚动捕获")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ivory)
            Text("帧 \(model.frameCount) · 段 \(model.segmentCount) · \(model.stitchedPixels) px")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ivory)
                .monospacedDigit()
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(Palette.ivoryMuted)
            Text(model.warning ?? " ")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.warning == nil ? Color.clear : Palette.bloomRose)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            Text("Esc 或「停止」结束并拼接 ·「取消」丢弃")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ivoryMuted)
            HStack(spacing: 8) {
                Button("取消", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                Button("停止", action: onDone)
                    .buttonStyle(BloomPrimaryButtonStyle())
                    .help("停止捕获并进入拼接（完成）")
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(FrostedChrome())
    }
}

/// Stroke around the region. Mouse events pass through so the page underneath still scrolls.
/// PrettyShot's own windows are excluded from the capture, so the stroke is not stitched in.
private final class RegionBorderWindow: NSWindow {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = RegionBorderView(frame: NSRect(origin: .zero, size: frame.size))
    }
}

private final class RegionBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setStrokeColor(NSColor(hex: 0xE8A0A8).cgColor)
        context.setLineWidth(2)
        context.stroke(bounds.insetBy(dx: 2, dy: 2))
    }
}

/// ScreenCaptureKit output. Frames are coalesced onto the main queue; the stitcher never sees a backlog.
private final class RegionFramePump: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((RGBAImage) -> Void)?
    var onInterrupted: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "app.prettyshot.scroll-capture")
    private var stream: SCStream?
    private let lock = NSLock()
    private var latest: RGBAImage?
    private var delivering = false
    private var stopped = false

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if lock.withLock({ stopped }) { return }
        try await stream.startCapture()
        // stop() may have run while startCapture was in flight, before `stream` was published.
        // Publish and observe `stopped` under the same lock, and stop an unpublished stream here.
        let shouldStop = lock.withLock { () -> Bool in
            if stopped { return true }
            self.stream = stream
            return false
        }
        if shouldStop {
            try? await stream.stopCapture()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        latest = nil
        lock.unlock()
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = RGBAImage.fromPixelBuffer(buffer) else { return }
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        latest = image
        let busy = delivering
        delivering = true
        lock.unlock()
        if !busy {
            DispatchQueue.main.async { [weak self] in self?.drain() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let alreadyStopped = stopped
        lock.unlock()
        guard !alreadyStopped else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onInterrupted?(error)
        }
    }

    private func drain() {
        while true {
            lock.lock()
            if stopped {
                delivering = false
                latest = nil
                lock.unlock()
                return
            }
            let frame = latest
            latest = nil
            if frame == nil {
                delivering = false
                lock.unlock()
                return
            }
            lock.unlock()
            if let frame {
                onFrame?(frame)
            }
        }
    }
}
