import AppKit
import SwiftUI

/// Shown only when a scrolling capture has a seam that was not safe to join by itself.
/// The user aligns that seam, stacks it as-is, or exports the segments separately.
/// Closing the window discards the capture — it never saves a guessed stitch.
@MainActor
final class StitchPreviewController: NSObject, NSWindowDelegate {
    var onCommit: ((CGImage) -> Void)?
    var onExportSegments: (([CGImage]) -> Void)?
    var onDiscard: (() -> Void)?

    private let model: StitchPreviewModel
    private var window: NSWindow?
    private var didFinish = false

    init(review: ScrollingReview) {
        model = StitchPreviewModel(assembly: review.assembly, notice: review.notice)
        super.init()
        model.refresh()
    }

    func present() {
        let view = StitchPreviewView(
            model: model,
            onAlign: { [weak self] in self?.model.alignSelected() },
            onJoin: { [weak self] in self?.model.joinSelectedAsIs() },
            onExport: { [weak self] in self?.exportSegments() },
            onCommit: { [weak self] in self?.commit() }
        )
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "滚动捕获 · 拼接"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 640))
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        onDiscard?()
    }

    private func commit() {
        guard let image = model.assembly.flattenedIfResolved()?.cgImage() else { return }
        didFinish = true
        onCommit?(image)
        window?.close()
    }

    private func exportSegments() {
        let images = model.assembly.exportChunks().compactMap { $0.cgImage() }
        guard !images.isEmpty else { return }
        didFinish = true
        onExportSegments?(images)
        window?.close()
    }
}

@MainActor
final class StitchPreviewModel: ObservableObject {
    @Published var assembly: ScrollAssembly
    @Published var preview: NSImage?
    @Published var marks: [SeamMark] = []
    @Published var selectedBoundary: Int?
    @Published var overlap: Double = 0
    let notice: String?

    init(assembly: ScrollAssembly, notice: String?) {
        self.assembly = assembly
        self.notice = notice
        self.selectedBoundary = assembly.seams.firstIndex { !$0.isResolved }
    }

    var canCommit: Bool { !assembly.needsReview }

    var selectedSeam: ScrollSeam? {
        guard let selectedBoundary, assembly.seams.indices.contains(selectedBoundary) else { return nil }
        return assembly.seams[selectedBoundary]
    }

    var overlapRange: ClosedRange<Double> {
        guard let selectedBoundary, assembly.segments.indices.contains(selectedBoundary + 1) else { return 0...0 }
        let limit = max(0, assembly.segments[selectedBoundary + 1].image.height - 1)
        return 0...Double(limit)
    }

    func refresh() {
        guard let rendered = assembly.renderPreview() else {
            preview = nil
            marks = []
            return
        }
        marks = rendered.marks
        if let cg = rendered.image.cgImage() {
            preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    func select(boundary: Int) {
        guard assembly.seams.indices.contains(boundary) else { return }
        selectedBoundary = boundary
        overlap = Double(assembly.seams[boundary].editorOverlap)
    }

    func alignSelected() {
        guard let selectedBoundary else { return }
        assembly.align(seam: selectedBoundary, overlap: Int(overlap.rounded()))
        refresh()
    }

    func joinSelectedAsIs() {
        guard let selectedBoundary else { return }
        assembly.joinAsIs(seam: selectedBoundary)
        overlap = 0
        refresh()
    }
}

@MainActor
struct StitchPreviewView: View {
    @ObservedObject var model: StitchPreviewModel
    var onAlign: () -> Void
    var onJoin: () -> Void
    var onExport: () -> Void
    var onCommit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                preview
                Divider()
                seamList
                    .frame(width: 340)
            }
            Divider()
            footer
        }
        .background(Palette.canvas)
        .onAppear {
            if let index = model.selectedBoundary {
                model.select(boundary: index)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("拼接预览")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.charcoal)
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.bloomDeep)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var summary: String {
        let ok = model.marks.filter { $0.state == .ok || $0.state == .aligned || $0.state == .joinedAsIs }.count
        let pending = model.marks.filter { $0.state == .needsAlignment }.count
        if pending == 0 {
            return "\(ok) 处接缝已处理，可以完成。"
        }
        return "\(ok) 处接缝已对齐 · \(pending) 处需要对齐。未处理的接缝不会自动拼上。"
    }

    private var preview: some View {
        ScrollView {
            if let preview = model.preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .padding(16)
            } else {
                Text("没有可预览的画面")
                    .foregroundStyle(Palette.muted)
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var seamList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.marks) { mark in
                    seamRow(mark)
                }
            }
            .padding(12)
        }
        .background(Palette.drawer)
    }

    private func seamRow(_ mark: SeamMark) -> some View {
        let selected = mark.boundaryIndex != nil && mark.boundaryIndex == model.selectedBoundary
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(label(for: mark.state))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint(for: mark.state))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint(for: mark.state).opacity(0.15)))
                Text("距顶部 \(mark.y) px")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                Spacer()
            }
            if let index = mark.boundaryIndex, selected, model.assembly.seams.indices.contains(index) {
                if !model.assembly.seams[index].isResolved {
                    Text("重叠 \(Int(model.overlap.rounded())) px（盖住下一段顶部）")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.charcoal)
                    Slider(value: $model.overlap, in: model.overlapRange)
                    HStack {
                        Button("按此对齐", action: onAlign)
                            .buttonStyle(LightButtonStyle())
                        Button("按原样拼接", action: onJoin)
                            .buttonStyle(LightButtonStyle())
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.white : Color.white.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Palette.bloomRose : Palette.borderLight, lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let index = mark.boundaryIndex {
                model.select(boundary: index)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("分段导出", action: onExport)
                .buttonStyle(LightButtonStyle())
                .help("按当前分段分别保存。已手动处理的相邻段会合并，未处理的接缝保持分开。")
            Spacer()
            Button("完成", action: onCommit)
                .buttonStyle(BloomPrimaryButtonStyle())
                .disabled(!model.canCommit)
                .help(model.canCommit ? "合成一张长图" : "还有接缝没处理")
        }
        .padding(14)
    }

    private func label(for state: SeamState) -> String {
        switch state {
        case .ok: return "已对齐"
        case .needsAlignment: return "需要对齐"
        case .aligned: return "已手动对齐"
        case .joinedAsIs: return "已按原样拼接"
        }
    }

    private func tint(for state: SeamState) -> Color {
        switch state {
        case .ok, .aligned, .joinedAsIs: return Palette.softMint
        case .needsAlignment: return Palette.bloomDeep
        }
    }
}
