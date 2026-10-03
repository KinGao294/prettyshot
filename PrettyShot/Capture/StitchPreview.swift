import AppKit
import PrettyShotCore
import SwiftUI

/// Shown only when a scrolling capture has a seam that was not safe to join by itself.
/// The user aligns that seam, stacks it as-is, or exports the segments separately.
/// Closing the window discards the capture — it never saves a guessed stitch.
@MainActor
final class StitchPreviewController: NSObject, NSWindowDelegate {
    var onCommit: ((CGImage, ScrollAssembly) -> Void)?
    var onExportSegments: (([CGImage]) -> Void)?
    var onDiscard: (() -> Void)?

    private let model: StitchPreviewModel
    private var window: NSWindow?
    private var didFinish = false
    private var keyMonitor: Any?

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
            onExportRestored: { [weak self] in self?.exportRestoredWithinLimits() },
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard !didFinish else { return }
        didFinish = true
        onDiscard?()
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard window?.isKeyWindow == true, model.selectedBoundary != nil else { return event }
        let delta: Int
        switch event.keyCode {
        case 123, 125: delta = -1
        case 124, 126: delta = 1
        default: return event
        }
        model.nudgeOverlap(by: delta)
        return nil
    }

    private func commit() {
        guard let image = model.assembly.flattenedIfResolved()?.cgImage() else { return }
        didFinish = true
        onCommit?(image, model.assembly)
        window?.close()
    }

    private func exportSegments() {
        let images = model.assembly.exportChunks().compactMap { $0.cgImage() }
        guard !images.isEmpty else { return }
        didFinish = true
        onExportSegments?(images)
        window?.close()
    }

    private func exportRestoredWithinLimits() {
        let images = model.assembly.exportWithinLimits(dedupeStickyBars: false).compactMap { $0.cgImage() }
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
    @Published var loupe: NSImage?
    @Published var restoreLimitMessage: String?
    @Published var duplicateToast: String?
    /// False for the re-detect notice: that action clears the undo stack.
    @Published var duplicateToastCanUndo = false
    @Published var duplicateMarks: [DuplicateRegionMark] = []
    @Published var previewFullHeight = 0
    @Published var selectedDuplicateID: String?
    @Published var highlightPendingSticky = false
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
        let limit = max(0, assembly.displayedSegmentHeight(selectedBoundary + 1) - 1)
        return 0...Double(limit)
    }

    func refresh() {
        duplicateMarks = assembly.duplicateRegionMarks()
        previewFullHeight = assembly.previewStackHeight()
        guard let rendered = assembly.renderPreview() else {
            preview = nil
            marks = []
            loupe = nil
            return
        }
        marks = rendered.marks
        if let cg = rendered.image.cgImage() {
            preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        refreshLoupe()
    }

    static func duplicatePreviewScrollID(_ candidateID: String) -> String {
        ScrollAssembly.duplicatePreviewScrollID(candidateID)
    }

    func select(boundary: Int) {
        guard assembly.seams.indices.contains(boundary) else { return }
        selectedBoundary = boundary
        overlap = Double(assembly.seams[boundary].editorOverlap)
        refreshLoupe()
    }

    /// Dragging applies the overlap immediately so the overview and the 1:1 crop stay in sync.
    func updateOverlap(_ value: Double) {
        let clamped = min(max(value, overlapRange.lowerBound), overlapRange.upperBound)
        overlap = clamped
        guard let selectedBoundary else {
            refreshLoupe()
            return
        }
        assembly.align(seam: selectedBoundary, overlap: Int(clamped.rounded()))
        refreshOverLimitMessage()
        refresh()
    }

    func nudgeOverlap(by delta: Int) {
        updateOverlap(overlap + Double(delta))
    }

    func alignSelected() {
        updateOverlap(overlap)
    }

    func joinSelectedAsIs() {
        guard let selectedBoundary else { return }
        assembly.joinAsIs(seam: selectedBoundary)
        overlap = 0
        refreshOverLimitMessage()
        refresh()
    }

    /// 「还原自动」. Restores the suggested overlap, then re-runs duplicate detection.
    func restoreAutoAlignment() {
        guard let selectedBoundary else { return }
        let boundary = selectedBoundary
        let summary = assembly.restoreAutoAlignment(seam: boundary)
        overlap = Double(assembly.seams[boundary].editorOverlap)
        clearDuplicateChrome()
        if let text = StitchCopy.restoreAutoRedetected(
            seam: assembly.visibleSeamNumber(boundary: boundary),
            kept: summary.keptChoiceCount,
            pending: summary.pendingCount,
            clearedSeam: summary.clearedSeamNumber,
            clearedCount: summary.clearedChoiceCount
        ) {
            showRedetectToast(text)
        }
        refreshOverLimitMessage()
        refresh()
    }

    /// 「开始拼接」. Drops duplicate candidates and the undo stack.
    func beginStitch() {
        assembly.beginStitch()
        clearDuplicateChrome()
    }

    /// Manual alignment 「完成」. Applies the current overlap, then re-runs duplicate detection.
    func finishManualAlignment() {
        let boundary = selectedBoundary
        let applied = Int(overlap.rounded())
        if let boundary {
            assembly.align(seam: boundary, overlap: applied)
        }
        let summary = assembly.completeManualAlignment()
        clearDuplicateChrome()
        if let boundary, let text = StitchCopy.manualAlignmentRedetected(
            seam: assembly.visibleSeamNumber(boundary: boundary),
            overlap: assembly.seams[boundary].editorOverlap,
            kept: summary.keptChoiceCount,
            pending: summary.pendingCount,
            clearedSeam: summary.clearedSeamNumber,
            clearedCount: summary.clearedChoiceCount
        ) {
            showRedetectToast(text)
        }
        refreshOverLimitMessage()
        refresh()
    }

    /// Moves the primary button one step: seams, then the sticky bar, then duplicate segments.
    /// Returns true when the button is 「下一步 · 美化 →」 and the capture can be committed.
    func focusPreviewPrimary() -> Bool {
        switch assembly.previewPrimaryStep {
        case .seam:
            highlightPendingSticky = false
            selectedDuplicateID = nil
            focusFirstUnalignedSeam()
            return false
        case .sticky:
            selectedDuplicateID = nil
            highlightPendingSticky = true
            return false
        case .duplicate:
            highlightPendingSticky = false
            selectedDuplicateID = assembly.duplicateCandidates.first(where: \.isUnresolved)?.id
            return false
        case .beautify:
            return assembly.previewPrimaryStep == .beautify && canCommit
        }
    }

    private func clearDuplicateChrome() {
        duplicateToast = nil
        duplicateToastCanUndo = false
        selectedDuplicateID = nil
        highlightPendingSticky = false
    }

    /// Re-detect empties the undo stack, so the notice cannot be undone.
    /// Shown when a choice was kept or is still pending, including when every choice was kept.
    private func showRedetectToast(_ text: String) {
        duplicateToast = text
        duplicateToastCanUndo = false
    }

    func setDedupeStickyBars(_ enabled: Bool) {
        if enabled {
            assembly.dedupeStickyBars = true
            if assembly.pendingSticky != nil { assembly.pendingSticky?.keepOnce = true }
            restoreLimitMessage = nil
            refresh()
            return
        }
        switch assembly.restoreStickyBars() {
        case .restored, .alreadyRestored:
            restoreLimitMessage = nil
            refresh()
        case .exceedsLimit(_, let message):
            restoreLimitMessage = message
        case .nothingToRestore:
            assembly.dedupeStickyBars = false
            restoreLimitMessage = nil
            refresh()
        }
    }

    /// 「只保留一次」 or 「都保留」. The choice goes on the undo stack and a toast offers 「撤销」.
    func resolveDuplicateCandidate(_ id: String, choice: DuplicateSegmentChoice) {
        guard let index = assembly.duplicateCandidates.firstIndex(where: { $0.id == id }) else { return }
        let before = assembly.duplicateUndoCount
        assembly.resolveDuplicateCandidate(id, choice: choice)
        guard assembly.duplicateUndoCount > before else { return }
        duplicateToast = StitchCopy.duplicateChoiceToast(
            index: index + 1,
            choice: choice,
            remaining: assembly.pendingDuplicateConfirmCount
        )
        duplicateToastCanUndo = true
        selectedDuplicateID = id
        refresh()
    }

    /// Puts the last duplicate-segment choice back into 「待确认」.
    func undoDuplicateCandidateChoice() {
        assembly.undoLastDuplicateCandidateChoice()
        duplicateToast = nil
        duplicateToastCanUndo = false
        refresh()
    }

    /// Puts one candidate back to unresolved and shows the restore toast. Undo restores the previous choice.
    func restoreDuplicateCandidate(_ id: String) {
        guard let index = assembly.duplicateCandidates.firstIndex(where: { $0.id == id }) else { return }
        guard assembly.duplicateCandidates[index].choice != nil else { return }
        let displayIndex = index + 1
        assembly.restoreDuplicateCandidate(id)
        let remaining = assembly.pendingDuplicateConfirmCount
        duplicateToast = StitchCopy.duplicateRestoredToast(index: displayIndex, remaining: remaining)
        duplicateToastCanUndo = true
        selectedDuplicateID = id
        refresh()
    }

    /// 「撤销」 on a choice or restore toast. One undo puts the previous choice back and restores removed rows.
    func undoDuplicateToast() {
        guard duplicateToastCanUndo else { return }
        assembly.undoLastDuplicateCandidateChoice()
        duplicateToast = nil
        duplicateToastCanUndo = false
        refresh()
    }

    func confirmPendingSticky(keepOnce: Bool) {
        if keepOnce {
            assembly.confirmStickyBars(keepOnce: true)
            restoreLimitMessage = nil
            refresh()
            return
        }
        setDedupeStickyBars(false)
        if restoreLimitMessage == nil {
            assembly.confirmStickyBars(keepOnce: false)
            refresh()
        }
    }

    func keepDedupe() {
        restoreLimitMessage = nil
        if assembly.pendingSticky?.isUnresolved == true {
            assembly.confirmStickyBars(keepOnce: true)
        } else {
            assembly.dedupeStickyBars = true
        }
        refresh()
    }

    /// The restored height changes once a seam is aligned or stacked. Keep line 1 in step with it.
    private func refreshOverLimitMessage() {
        guard restoreLimitMessage != nil else { return }
        restoreLimitMessage = assembly.overLimitLine()
    }

    /// Selects the first seam that still needs alignment, for the over-limit primary action.
    func focusFirstUnalignedSeam() {
        guard let index = assembly.seams.firstIndex(where: { !$0.isResolved }) else { return }
        select(boundary: index)
    }

    private func refreshLoupe() {
        guard let selectedBoundary,
              let image = assembly.seamLoupe(boundary: selectedBoundary, overlap: Int(overlap.rounded())),
              let cg = image.cgImage() else {
            loupe = nil
            return
        }
        loupe = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

@MainActor
struct StitchPreviewView: View {
    @ObservedObject var model: StitchPreviewModel
    var onAlign: () -> Void
    var onJoin: () -> Void
    var onExport: () -> Void
    var onExportRestored: () -> Void
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
            if let pending = model.assembly.pendingSticky, pending.isUnresolved {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pending.prompt)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.charcoal)
                    HStack(spacing: 8) {
                        Button(StitchCopy.keepOnceChoice) { model.confirmPendingSticky(keepOnce: true) }
                            .buttonStyle(BloomPrimaryButtonStyle())
                        Button(StitchCopy.keepAllChoice) { model.confirmPendingSticky(keepOnce: false) }
                            .buttonStyle(LightButtonStyle())
                    }
                }
                .padding(model.highlightPendingSticky ? 8 : 0)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(model.highlightPendingSticky ? duplicateAmber.opacity(0.12) : Color.clear)
                )
            }
            HStack(spacing: 12) {
                Toggle(StitchCopy.keepOnceToggle, isOn: Binding(
                    get: { model.assembly.dedupeStickyBars },
                    set: { model.setDedupeStickyBars($0) }
                ))
                .toggleStyle(.switch)
                .font(.system(size: 12))
                Button(StitchCopy.restoreSticky) { model.setDedupeStickyBars(false) }
                    .buttonStyle(LightButtonStyle())
                    .disabled(!model.assembly.dedupeStickyBars || !model.assembly.hasStickyRepeats)
                    .help(StitchCopy.restoreHelp)
            }
            if let restoreLimitMessage = model.restoreLimitMessage {
                let prompt = model.assembly.restoreExportPrompt
                Text(restoreLimitMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.bloomDeep)
                Text(StitchCopy.overLimitNote)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                HStack(alignment: .top, spacing: 8) {
                    if prompt.primaryExports {
                        Button(prompt.primaryTitle, action: onExportRestored)
                            .buttonStyle(BloomPrimaryButtonStyle())
                    } else {
                        Button(prompt.primaryTitle) { model.focusFirstUnalignedSeam() }
                            .buttonStyle(BloomPrimaryButtonStyle())
                    }
                    if !prompt.segmentExportEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            Button(StitchCopy.exportSegments) {}
                                .buttonStyle(LightButtonStyle())
                                .disabled(true)
                                .opacity(0.45)
                            if let caption = prompt.segmentExportCaption {
                                Text(caption)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Button(StitchCopy.keepDedupe) { model.keepDedupe() }
                        .buttonStyle(LightButtonStyle())
                }
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
        VStack(spacing: 0) {
            if let loupe = model.loupe {
                VStack(alignment: .leading, spacing: 4) {
                    Text("接缝 1:1 · 偏移 \(Int(model.overlap.rounded())) px")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                    Image(nsImage: loupe)
                        .interpolation(.none)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            GeometryReader { geo in
                let width = max(geo.size.width - 32, 1)
                let fullH = max(model.previewFullHeight, 1)
                let aspect = (model.preview?.size.height ?? 1) / max(model.preview?.size.width ?? 1, 1)
                let imageH = max(width * aspect, 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        if let preview = model.preview {
                            ZStack(alignment: .topLeading) {
                                Image(nsImage: preview)
                                    .resizable()
                                    .interpolation(.medium)
                                    .frame(width: width, height: imageH)
                                ForEach(model.duplicateMarks) { mark in
                                    let scale = imageH / CGFloat(fullH)
                                    let y = CGFloat(mark.y) * scale
                                    let h = max(CGFloat(mark.height) * scale, 22)
                                    VStack(spacing: 0) {
                                        Color.clear.frame(height: max(y, 0))
                                        duplicateMarker(mark, width: width, height: h)
                                            .id(StitchPreviewModel.duplicatePreviewScrollID(mark.id))
                                        Spacer(minLength: 0)
                                    }
                                    .frame(width: width, height: imageH, alignment: .top)
                                }
                            }
                            .frame(width: width, height: imageH, alignment: .topLeading)
                            .padding(16)
                        } else {
                            Text("没有可预览的画面")
                                .foregroundStyle(Palette.muted)
                                .padding(24)
                        }
                    }
                    .onChange(of: model.selectedDuplicateID, initial: false) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(StitchPreviewModel.duplicatePreviewScrollID(id), anchor: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var seamList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.marks) { mark in
                        seamRow(mark)
                    }
                    ForEach(Array(model.assembly.duplicateCandidates.enumerated()), id: \.element.id) { offset, candidate in
                        duplicateRow(candidate, displayIndex: offset + 1)
                            .id(candidate.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.selectedDuplicateID, initial: false) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .background(Palette.drawer)
    }

    private func duplicateRow(_ candidate: DuplicateSegmentCandidate, displayIndex: Int) -> some View {
        let selected = candidate.id == model.selectedDuplicateID
        return VStack(alignment: .leading, spacing: 8) {
            if let handled = candidate.handledLine {
                Text(handled)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.softMint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Palette.softMint.opacity(0.15)))
                if candidate.rowCount > 0 {
                    Text(candidate.locationLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                Button(StitchCopy.restoreDuplicate) {
                    model.restoreDuplicateCandidate(candidate.id)
                }
                .buttonStyle(LightButtonStyle())
            } else {
                Text(candidate.pendingTitle(displayIndex: displayIndex))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(duplicateAmber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(duplicateAmber, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    )
                if candidate.seamMoved {
                    Text(StitchCopy.duplicateSeamMovedNote(seam: candidate.movedSeamNumber ?? candidate.seamNumber))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.charcoal)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if candidate.rowCount > 0 {
                    Text(candidate.locationLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                Text(StitchCopy.duplicateDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.charcoal)
                HStack(spacing: 8) {
                    Button(StitchCopy.keepDuplicateOnce) {
                        model.resolveDuplicateCandidate(candidate.id, choice: .keepOnce)
                    }
                    .buttonStyle(BloomPrimaryButtonStyle())
                    Button(StitchCopy.keepDuplicateBoth) {
                        model.resolveDuplicateCandidate(candidate.id, choice: .keepBoth)
                    }
                    .buttonStyle(LightButtonStyle())
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected && candidate.isUnresolved ? duplicateAmber.opacity(0.12) : Color.white.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    candidate.isUnresolved ? (selected ? duplicateAmber : Palette.borderLight) : Palette.softMint.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1, dash: candidate.isUnresolved ? [CGFloat(4), 3] : [])
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedDuplicateID = candidate.id
        }
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
                Text("重叠 \(Int(model.overlap.rounded())) px（盖住下一段顶部）· 方向键 ±1 px")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.charcoal)
                Slider(
                    value: Binding(
                        get: { model.overlap },
                        set: { model.updateOverlap($0) }
                    ),
                    in: model.overlapRange
                )
                HStack {
                    Button("按此对齐", action: onAlign)
                        .buttonStyle(LightButtonStyle())
                    Button("按原样拼接", action: onJoin)
                        .buttonStyle(LightButtonStyle())
                    Button("完成") { model.finishManualAlignment() }
                        .buttonStyle(LightButtonStyle())
                    Button("还原自动") { model.restoreAutoAlignment() }
                        .buttonStyle(LightButtonStyle())
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
        VStack(alignment: .leading, spacing: 8) {
            if let toast = model.duplicateToast {
                HStack(spacing: 8) {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.charcoal)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if model.duplicateToastCanUndo {
                        Button(StitchCopy.undoDuplicate) { model.undoDuplicateToast() }
                            .buttonStyle(LightButtonStyle())
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.ivory)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.borderLight, lineWidth: 1)
                )
            }
            if let bar = model.assembly.reviewBottomBar {
                Text(bar)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.bloomDeep)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(StitchCopy.exportSegments, action: onExport)
                    .buttonStyle(LightButtonStyle())
                    .help("按当前分段分别保存。已手动处理的相邻段会合并，未处理的接缝保持分开。")
                Spacer()
                Button(model.assembly.previewPrimaryTitle) {
                    if model.focusPreviewPrimary() {
                        onCommit()
                    }
                }
                .buttonStyle(BloomPrimaryButtonStyle())
                .disabled(model.assembly.previewPrimaryStep == .beautify && !model.canCommit)
                .help(model.canCommit ? "合成一张长图" : (model.assembly.reviewBottomBar ?? ""))
            }
        }
        .padding(14)
    }

    private func duplicateMarker(_ mark: DuplicateRegionMark, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(duplicateAmber.opacity(0.08))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(duplicateAmber, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            Text(mark.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(duplicateAmber)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.92)))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(duplicateAmber, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                )
                .padding(6)
        }
        .frame(width: width, height: height)
    }

    private var duplicateAmber: Color { Color(red: 0.77, green: 0.54, blue: 0.16) }

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
