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
        guard window?.isKeyWindow == true,
              let boundary = model.selectedBoundary,
              model.showsManualControls(boundary: boundary) else { return event }
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

/// Light or dark, apart from SwiftUI so tests and the screenshot helper can pick one.
enum StitchAppearance: Equatable {
    case light
    case dark

    init(_ scheme: ColorScheme) {
        self = scheme == .dark ? .dark : .light
    }
}

/// One seam tag's paint as sRGB hex and opacity. The view turns it into `Color(hex:)`.
struct SeamTagInk: Equatable {
    var text: UInt32
    var border: UInt32
    var fill: UInt32
    var fillOpacity: Double
    var borderWidth: Int
    var dashed: Bool
}

/// The tag on one confirmation seam: 「待确认」「✓ 已确认」「✓ 手动对齐 · −28 px」「直接拼」.
struct SeamTag: Equatable {
    var text: String
    var light: SeamTagInk
    var dark: SeamTagInk

    func ink(_ appearance: StitchAppearance) -> SeamTagInk {
        appearance == .dark ? dark : light
    }
}

/// ML6b options on a 「待确认」 seam, in the order Core lists them.
enum SeamConfirmationOption: Equatable, CaseIterable {
    case confirmCurrentShift
    case manualAlign
    case joinAsIs
    case splitExport

    init?(title: String) {
        guard let option = Self.allCases.first(where: { $0.title == title }) else { return nil }
        self = option
    }

    var title: String {
        switch self {
        case .confirmCurrentShift: return StitchCopy.confirmCurrentShift
        case .manualAlign: return StitchCopy.manualAlignOption
        case .joinAsIs: return StitchCopy.joinAsIsOption
        case .splitExport: return StitchCopy.splitExportOption
        }
    }

    /// Second line under the option (design frame 19).
    var caption: String {
        switch self {
        case .confirmCurrentShift: return "看过上图没有重复 / 缺行"
        case .manualAlign: return "1:1 放大 + 半透明叠放，拖动 / 方向键微调"
        case .joinAsIs: return "不找重叠，上下直接接起来"
        case .splitExport: return "每段单独保存"
        }
    }
}

/// ML6c 「− 底栏 F · 顶栏 H」 or ML6d 「固定栏已接回」, left of the long image at one confident join.
struct StickyBandMark: Identifiable, Equatable {
    var id: String
    /// Row in the full-resolution stack, the same space as `SeamMark.y`.
    var y: Int
    var label: String
    /// True after 「还原固定栏」 put the bars back.
    var reattached: Bool
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
    /// Set by 「手动对齐」 on a 「待确认」 seam: that seam shows the slider instead of the four options.
    @Published var manualAlignmentBoundary: Int?
    let notice: String?

    init(assembly: ScrollAssembly, notice: String?) {
        self.assembly = assembly
        self.notice = notice
        self.selectedBoundary = assembly.seams.firstIndex { !$0.isResolved }
    }

    var canCommit: Bool { !assembly.needsReview }

    /// Core's title for the current step: 「处理下一处 · N」, 「先确认 N 处重复段」 or 「下一步 · 美化 →」.
    var primaryTitle: String { assembly.previewPrimaryTitle }

    /// Only 「下一步 · 美化 →」 can be blocked; the other steps move the selection.
    var primaryEnabled: Bool { assembly.previewPrimaryStep != .beautify || canCommit }

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

    /// 「按此对齐」. At the suggested overlap, a tie or lone reverse aligns on its signed shift.
    func alignSelected() {
        if let selectedBoundary,
           assembly.seams[selectedBoundary].suggestedShift != nil,
           Int(overlap.rounded()) == assembly.seams[selectedBoundary].suggestedOverlap {
            alignToSuggestion()
            return
        }
        updateOverlap(overlap)
    }

    /// Aligns the selected seam on its suggestion, keeping the shift's sign.
    func alignToSuggestion() {
        guard let selectedBoundary else { return }
        manualAlignmentBoundary = nil
        assembly.alignToSuggestion(seam: selectedBoundary)
        overlap = Double(assembly.seams[selectedBoundary].editorOverlap)
        refreshOverLimitMessage()
        refresh()
    }

    /// Clicking a candidate row: select the seam and align on that row's signed shift.
    func pickCandidate(seam index: Int, index candidate: Int) {
        guard assembly.seams.indices.contains(index),
              assembly.seams[index].candidateShifts.indices.contains(candidate) else { return }
        select(boundary: index)
        assembly.align(seam: index, shift: assembly.seams[index].candidateShifts[candidate])
        overlap = Double(assembly.seams[index].editorOverlap)
        refreshOverLimitMessage()
        refresh()
    }

    /// ML6b options for this seam. Empty once it is handled, and for a seam that is not a tie or lone reverse.
    func confirmationOptions(boundary: Int) -> [SeamConfirmationOption] {
        guard assembly.seams.indices.contains(boundary) else { return [] }
        return assembly.seams[boundary].confirmationOptions.compactMap(SeamConfirmationOption.init(title:))
    }

    /// 「确认当前位移」: the same Core path as 「按此对齐」 on the suggestion.
    func confirmCurrentShift(boundary: Int) {
        guard assembly.seams.indices.contains(boundary) else { return }
        select(boundary: boundary)
        alignToSuggestion()
    }

    /// 「手动对齐」: selects the seam and opens the slider. The seam stays 「待确认」 until it is aligned.
    func beginManualAlignment(boundary: Int) {
        guard assembly.seams.indices.contains(boundary) else { return }
        select(boundary: boundary)
        manualAlignmentBoundary = boundary
    }

    /// The slider, 1:1 crop and arrow keys belong to a selected seam with no options left,
    /// or to a 「待确认」 seam after 「手动对齐」.
    func showsManualControls(boundary: Int) -> Bool {
        guard selectedBoundary == boundary, assembly.seams.indices.contains(boundary) else { return false }
        return confirmationOptions(boundary: boundary).isEmpty || manualAlignmentBoundary == boundary
    }

    /// Tag for a tie or lone reverse seam, nil for any other seam.
    /// 「待确认」 is the amber dashed chip; handled tags use the card's ink with a 1 px solid border.
    func seamTag(boundary: Int) -> SeamTag? {
        guard assembly.seams.indices.contains(boundary) else { return nil }
        let seam = assembly.seams[boundary]
        let card = seam.card(number: boundary + 1)
        if card.chrome == .amberDashed {
            // Dark keeps the design's #8A5A12 text; DESIGN.md gives no dark value for it.
            let ink = SeamTagInk(
                text: PendingSeamStyle.text,
                border: PendingSeamStyle.warn,
                fill: PendingSeamStyle.warn,
                fillOpacity: PendingSeamStyle.fillOpacity,
                borderWidth: PendingSeamStyle.labelBorderWidth,
                dashed: true
            )
            return SeamTag(text: card.label, light: ink, dark: ink)
        }
        guard card.labelColor != 0 else { return nil }
        let darkFill = seam.kind == .joinedAsIs ? ResolvedSeamStyle.directDarkFillOpacity : card.fillOpacity
        return SeamTag(
            text: card.tagText,
            light: SeamTagInk(
                text: card.labelColor,
                border: card.labelColor,
                fill: card.labelColor,
                fillOpacity: card.fillOpacity,
                borderWidth: card.borderWidth,
                dashed: false
            ),
            dark: SeamTagInk(
                text: card.labelColorDark,
                border: card.labelColorDark,
                fill: card.labelColorDark,
                fillOpacity: darkFill,
                borderWidth: card.borderWidth,
                dashed: false
            )
        )
    }

    /// The card's reason line. A handled tie or reverse seam has none.
    func seamReason(boundary: Int) -> String? {
        guard assembly.seams.indices.contains(boundary) else { return nil }
        return assembly.seams[boundary].card(number: boundary + 1).reason
    }

    /// One left-side label per confident join while the capture has sticky bars.
    var stickyBandMarks: [StickyBandMark] {
        guard let label = assembly.stickyBandLabel else { return [] }
        let reattached = !assembly.dedupeStickyBars
        return marks
            .filter { $0.boundaryIndex == nil && $0.state == .ok }
            .map { StickyBandMark(id: "sticky-\($0.id)", y: $0.y, label: label, reattached: reattached) }
    }

    /// ML6d notice while the bars are back on every seam.
    var stickyRestoredNotice: String? {
        guard assembly.hasStickyRepeats, !assembly.dedupeStickyBars else { return nil }
        return StitchCopy.stickyRestoredToast
    }

    func joinSelectedAsIs() {
        guard let selectedBoundary else { return }
        manualAlignmentBoundary = nil
        assembly.joinAsIs(seam: selectedBoundary)
        overlap = 0
        refreshOverLimitMessage()
        refresh()
    }

    /// 「还原自动」. Restores the suggested overlap, then re-runs duplicate detection.
    func restoreAutoAlignment() {
        guard let selectedBoundary else { return }
        let boundary = selectedBoundary
        manualAlignmentBoundary = nil
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
        manualAlignmentBoundary = nil
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

/// Preview window surfaces in light and dark (DESIGN §11.9). Only this window reads them.
enum StitchSurface {
    case canvas
    case drawer
    case card
    case text
    case secondary
    case hairline

    func color(_ appearance: StitchAppearance) -> Color {
        switch (self, appearance) {
        case (.canvas, .light): return Palette.canvas
        case (.canvas, .dark): return Color(hex: 0x171615)
        case (.drawer, .light): return Palette.drawer
        case (.drawer, .dark): return Color(hex: 0x1E1D1C)
        case (.card, .light): return Color.white
        case (.card, .dark): return Color(hex: 0x262422)
        case (.text, .light): return Palette.charcoal
        case (.text, .dark): return Color(hex: 0xEDE8E1)
        case (.secondary, .light): return Palette.muted
        case (.secondary, .dark): return Color(hex: 0x9C958B)
        case (.hairline, .light): return Palette.borderLight
        case (.hairline, .dark): return Color.white.opacity(0.09)
        }
    }
}

@MainActor
struct StitchPreviewView: View {
    @ObservedObject var model: StitchPreviewModel
    @Environment(\.colorScheme) private var colorScheme
    var onAlign: () -> Void
    var onJoin: () -> Void
    var onExport: () -> Void
    var onExportRestored: () -> Void
    var onCommit: () -> Void

    /// The long image is a column, as in the design frames, with room on the left for band labels.
    private static let longImageMaxWidth: CGFloat = 320
    private static let bandGutter: CGFloat = 132

    private var appearance: StitchAppearance { StitchAppearance(colorScheme) }
    private func surface(_ surface: StitchSurface) -> Color { surface.color(appearance) }

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
        .background(surface(.canvas))
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
                .foregroundStyle(surface(.text))
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(surface(.secondary))
            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.bloomDeep)
            }
            if let pending = model.assembly.pendingSticky, pending.isUnresolved {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pending.prompt)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(surface(.text))
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
                .foregroundStyle(surface(.text))
                Button(StitchCopy.restoreSticky) { model.setDedupeStickyBars(false) }
                    .buttonStyle(LightButtonStyle())
                    .disabled(!model.assembly.dedupeStickyBars || !model.assembly.hasStickyRepeats)
                    .help(StitchCopy.restoreHelp)
            }
            if let restored = model.stickyRestoredNotice {
                HStack(spacing: 8) {
                    Text(restored)
                        .font(.system(size: 12))
                        .foregroundStyle(surface(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(StitchCopy.keepOnceToggle) { model.setDedupeStickyBars(true) }
                        .buttonStyle(LightButtonStyle())
                }
            }
            if let restoreLimitMessage = model.restoreLimitMessage {
                let prompt = model.assembly.restoreExportPrompt
                Text(restoreLimitMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.bloomDeep)
                Text(StitchCopy.overLimitNote)
                    .font(.system(size: 12))
                    .foregroundStyle(surface(.secondary))
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
                                    .foregroundStyle(surface(.secondary))
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
            if let loupe = model.loupe, let index = model.selectedBoundary, model.showsManualControls(boundary: index) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("接缝 1:1 · 偏移 \(Int(model.overlap.rounded())) px")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(surface(.secondary))
                    Image(nsImage: loupe)
                        .interpolation(.none)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            GeometryReader { geo in
                let bands = model.stickyBandMarks
                let gutter: CGFloat = bands.isEmpty ? 0 : Self.bandGutter
                let width = max(min(geo.size.width - 32 - gutter, Self.longImageMaxWidth), 1)
                let fullH = max(model.previewFullHeight, 1)
                let aspect = (model.preview?.size.height ?? 1) / max(model.preview?.size.width ?? 1, 1)
                let imageH = max(width * aspect, 1)
                let scale = imageH / CGFloat(fullH)
                ScrollViewReader { proxy in
                    ScrollView {
                        if let preview = model.preview {
                            longImage(preview, width: width, imageH: imageH, scale: scale, gutter: gutter, bands: bands)
                                .padding(16)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("没有可预览的画面")
                                .foregroundStyle(surface(.secondary))
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

    /// Band labels in the left gutter, then the long image with its duplicate-region overlays.
    private func longImage(
        _ preview: NSImage,
        width: CGFloat,
        imageH: CGFloat,
        scale: CGFloat,
        gutter: CGFloat,
        bands: [StickyBandMark]
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if !bands.isEmpty {
                ZStack(alignment: .topTrailing) {
                    ForEach(bands) { band in
                        VStack(spacing: 0) {
                            Color.clear.frame(height: max(CGFloat(band.y) * scale - 9, 0))
                            stickyBandLabel(band)
                                .padding(.trailing, 6)
                            Spacer(minLength: 0)
                        }
                        .frame(width: gutter, height: imageH, alignment: .topTrailing)
                    }
                }
                .frame(width: gutter, height: imageH, alignment: .topTrailing)
            }
            ZStack(alignment: .topLeading) {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: width, height: imageH)
                ForEach(model.duplicateMarks) { mark in
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
        }
    }

    /// ML6c rose dashed 「− 底栏 F · 顶栏 H」; ML6d amber dashed 「固定栏已接回」.
    private func stickyBandLabel(_ band: StickyBandMark) -> some View {
        let ink: Color
        let border: Color
        if band.reattached {
            ink = Color(hex: appearance == .dark ? PendingSeamStyle.warn : PendingSeamStyle.text)
            border = Color(hex: PendingSeamStyle.warn)
        } else {
            ink = Palette.bloomDeep
            border = Palette.bloomRose
        }
        return Text(band.label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(band.reattached ? Color(hex: PendingSeamStyle.warn).opacity(0.12) : surface(.card))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
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
        .background(surface(.drawer))
    }

    /// ML6b-r tag: 1 px border (dashed for 「待确认」), fill at the tag's opacity.
    private func seamTagChip(_ title: String, ink: SeamTagInk) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(hex: ink.text))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(hex: ink.fill).opacity(ink.fillOpacity)))
            .overlay(
                Capsule().strokeBorder(
                    Color(hex: ink.border),
                    style: StrokeStyle(lineWidth: CGFloat(ink.borderWidth), dash: ink.dashed ? [3, 2] : [])
                )
            )
    }

    private func seamCard(for mark: SeamMark) -> SeamCard? {
        guard let index = mark.boundaryIndex, model.assembly.seams.indices.contains(index) else { return nil }
        return model.assembly.seams[index].card(number: index + 1)
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
                        .foregroundStyle(surface(.secondary))
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
                        .foregroundStyle(surface(.text))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if candidate.rowCount > 0 {
                    Text(candidate.locationLine)
                        .font(.system(size: 11))
                        .foregroundStyle(surface(.secondary))
                }
                Text(StitchCopy.duplicateDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(surface(.text))
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
                .fill(selected && candidate.isUnresolved ? duplicateAmber.opacity(0.12) : surface(.card).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    candidate.isUnresolved ? (selected ? duplicateAmber : surface(.hairline)) : Palette.softMint.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1, dash: candidate.isUnresolved ? [CGFloat(4), 3] : [])
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedDuplicateID = candidate.id
        }
    }

    /// Reason under the seam title: the card's while a confirmation seam waits, otherwise the mark's note.
    private func reasonLine(for mark: SeamMark) -> String? {
        guard let index = mark.boundaryIndex else { return mark.note }
        return model.seamReason(boundary: index)
    }

    private func seamRow(_ mark: SeamMark) -> some View {
        let selected = mark.boundaryIndex != nil && mark.boundaryIndex == model.selectedBoundary
        let card = seamCard(for: mark)
        let tag = mark.boundaryIndex.flatMap { model.seamTag(boundary: $0) }
        let options = mark.boundaryIndex.map { model.confirmationOptions(boundary: $0) } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let tag {
                    seamTagChip(tag.text, ink: tag.ink(appearance))
                } else {
                    let ink = tint(for: mark.state)
                    Text(card?.tagText ?? label(for: mark.state))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(ink.opacity(0.15)))
                }
                Text("距顶部 \(mark.y) px")
                    .font(.system(size: 11))
                    .foregroundStyle(surface(.secondary))
                Spacer()
            }
            if let title = card?.title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(surface(.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = reasonLine(for: mark) {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(surface(.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let candidates = card?.candidates, !candidates.isEmpty {
                ForEach(Array(candidates.enumerated()), id: \.offset) { offset, line in
                    Button {
                        if let index = mark.boundaryIndex {
                            model.pickCandidate(seam: index, index: offset)
                        }
                    } label: {
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(surface(.text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("按这个位移对齐")
                }
            }
            if let index = mark.boundaryIndex, !options.isEmpty, !model.showsManualControls(boundary: index) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { offset, option in
                        Button {
                            perform(option, boundary: index)
                        } label: {
                            optionRow(option, number: offset)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let index = mark.boundaryIndex, model.showsManualControls(boundary: index) {
                Text("重叠 \(Int(model.overlap.rounded())) px（盖住下一段顶部）· 方向键 ±1 px")
                    .font(.system(size: 11))
                    .foregroundStyle(surface(.text))
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
                .fill(selected ? surface(.card) : surface(.card).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Palette.bloomRose : surface(.hairline), lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let index = mark.boundaryIndex {
                model.select(boundary: index)
            }
        }
    }

    /// One ML6b option: a numbered badge (✓ for 确认当前位移), the title, and a short caption.
    private func optionRow(_ option: SeamConfirmationOption, number: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number == 0 ? "✓" : "\(number)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.bloomDeep)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Palette.bloomRose.opacity(0.18))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(surface(.text))
                Text(option.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(surface(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(surface(.card))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(surface(.hairline), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func perform(_ option: SeamConfirmationOption, boundary: Int) {
        switch option {
        case .confirmCurrentShift:
            model.confirmCurrentShift(boundary: boundary)
        case .manualAlign:
            model.beginManualAlignment(boundary: boundary)
        case .joinAsIs:
            model.select(boundary: boundary)
            onJoin()
        case .splitExport:
            onExport()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let toast = model.duplicateToast {
                HStack(spacing: 8) {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(surface(.text))
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
                        .fill(appearance == .dark ? surface(.card) : Palette.ivory)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(surface(.hairline), lineWidth: 1)
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
                Button(model.primaryTitle) {
                    if model.focusPreviewPrimary() {
                        onCommit()
                    }
                }
                .buttonStyle(BloomPrimaryButtonStyle())
                .disabled(!model.primaryEnabled)
                .opacity(model.primaryEnabled ? 1 : 0.45)
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

#if DEBUG
/// Debug-only PNG of the real preview window, for the CI screenshot test.
/// Hosts the view in an offscreen window so AppKit controls draw for real, then caches it at 2x.
enum StitchPreviewSnapshot {
    @MainActor
    static func renderPNG(model: StitchPreviewModel, dark: Bool, size: CGSize) -> Data? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: root(model: model, dark: dark, size: size))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = appearance
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        // onAppear selects the seam and refreshes the loupe; give layout and that update a few turns.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }

        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) {
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            if !isBlank(rep) {
                return rep.representation(using: .png, properties: [:])
            }
            print("StitchPreviewSnapshot: cacheDisplay was blank; using ImageRenderer")
        }
        // ImageRenderer draws AppKit controls as placeholders, so it is only the fallback.
        let renderer = ImageRenderer(content: root(model: model, dark: dark, size: size))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    @MainActor
    private static func root(model: StitchPreviewModel, dark: Bool, size: CGSize) -> some View {
        StitchPreviewView(
            model: model,
            onAlign: {},
            onJoin: {},
            onExport: {},
            onExportRestored: {},
            onCommit: {}
        )
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: size.width, height: size.height)
    }

    /// True when every pixel matches the first one.
    private static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        guard let data = rep.bitmapData else { return true }
        let stride = rep.bitsPerPixel / 8
        let count = rep.bytesPerRow * rep.pixelsHigh
        guard stride > 0, count >= stride else { return true }
        var offset = stride
        while offset + stride <= count {
            for byte in 0..<stride where data[offset + byte] != data[byte] {
                return false
            }
            offset += stride
        }
        return true
    }
}
#endif
