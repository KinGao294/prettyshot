import AppKit
import SwiftUI

/// Keeps every floating pin alive and offers menu-level controls (so click-through pins can be rescued).
@MainActor
final class PinManager: ObservableObject {
    @Published private(set) var pins: [PinWindowController] = []

    var clickThroughCount: Int { pins.filter { $0.model.clickThrough }.count }

    func pin(image: CGImage, scale: CGFloat) {
        let controller = PinWindowController(image: image, scale: scale)
        controller.onClose = { [weak self] closed in
            self?.pins.removeAll { $0 === closed }
        }
        pins.append(controller)
        controller.present(cascadeIndex: pins.count - 1)
    }

    func closeAll() {
        pins.forEach { $0.close() }
        pins.removeAll()
    }

    func disableClickThroughEverywhere() {
        pins.forEach { $0.model.clickThrough = false }
        objectWillChange.send()
    }
}

@MainActor
final class PinModel: ObservableObject {
    static let opacityRange: ClosedRange<Double> = 0.3...1
    static let sizeRange: ClosedRange<Double> = 0.25...2

    @Published var opacity: Double = 1 { didSet { onChange?() } }
    /// 1 = image at 100 % of its point size (capped to the screen on first show).
    @Published var size: Double = 1 { didSet { onChange?() } }
    @Published var clickThrough = false { didSet { onChange?() } }

    var onChange: (() -> Void)?
}

@MainActor
final class PinWindowController: NSObject, NSWindowDelegate {
    let model = PinModel()
    var onClose: ((PinWindowController) -> Void)?

    private let panel: PinPanel
    private let baseSize: NSSize

    init(image: CGImage, scale: CGFloat) {
        let nsImage = ImageCodec.nsImage(image, scale: scale)
        let visible = NSScreen.underMouse.visibleFrame
        // Base size = the capture's point size, fitted into 60 % of the screen.
        let fit = min(1, visible.width * 0.6 / nsImage.size.width, visible.height * 0.6 / nsImage.size.height)
        baseSize = NSSize(width: max(nsImage.size.width * fit, 80), height: max(nsImage.size.height * fit, 60))

        panel = PinPanel(
            contentRect: NSRect(origin: .zero, size: baseSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: PinView(image: nsImage, model: model) { [weak self] in
            self?.close()
        })

        model.onChange = { [weak self] in self?.apply() }
    }

    func present(cascadeIndex: Int) {
        let visible = NSScreen.underMouse.visibleFrame
        let offset = CGFloat(cascadeIndex % 8) * 24
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - baseSize.width / 2 + offset,
            y: visible.midY - baseSize.height / 2 - offset
        ))
        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    private func apply() {
        panel.alphaValue = CGFloat(model.opacity)
        panel.ignoresMouseEvents = model.clickThrough

        let newSize = NSSize(width: (baseSize.width * model.size).rounded(), height: (baseSize.height * model.size).rounded())
        let frame = panel.frame
        if abs(frame.width - newSize.width) > 0.5 || abs(frame.height - newSize.height) > 0.5 {
            // Keep the top-left corner anchored while resizing.
            panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - newSize.height, width: newSize.width, height: newSize.height),
                           display: true)
        }
    }
}

final class PinPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// F6 · Pin Window — framed shot; controls (opacity / size / click-through / close) appear on hover.
@MainActor
struct PinView: View {
    let image: NSImage
    @ObservedObject var model: PinModel
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .top) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                        .strokeBorder(hovering ? Palette.bloomRose.opacity(0.8) : Color.white.opacity(0.25), lineWidth: 1)
                )

            WindowDragArea()

            if hovering {
                controls
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Palette.softMint).frame(width: 7, height: 7)
                Text("PrettyShot Pin")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                Button {
                    model.clickThrough = true
                } label: {
                    Image(systemName: "cursorarrow.rays")
                }
                .buttonStyle(.plain)
                .help("点击穿透：之后可从菜单栏「恢复 Pin 可点击」")
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("关闭 Pin（Esc / ⌘W）")
            }
            control(title: "透明度", value: $model.opacity, range: PinModel.opacityRange)
            control(title: "尺寸", value: $model.size, range: PinModel.sizeRange)
        }
        .foregroundStyle(Palette.ivory)
        .padding(10)
        .frame(maxWidth: 260)
        .background(FrostedChrome(cornerRadius: 10))
    }

    private func control(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .frame(width: 40, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
                .tint(Palette.bloomRose)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// Transparent AppKit view that moves its window on drag (SwiftUI views don't reliably do this).
@MainActor
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeKey()
            window?.performDrag(with: event)
        }
    }
}
