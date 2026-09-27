import AppKit
import Combine

/// Text currently being typed on the canvas (not yet an annotation).
struct PendingText: Equatable {
    var point: CGPoint
    var text: String
    var color: RGBAColor
    var fontSize: CGFloat
    /// Set when re-editing an existing text annotation.
    var replacing: Annotation?
}

/// All state of one editor window. Geometry is in image pixels (y-down).
@MainActor
final class EditorDocument: ObservableObject {
    let original: CGImage
    /// Pixels per point of the capture.
    let scale: CGFloat
    let mode: CaptureMode
    /// History entry this editor was opened from, and the entry holding its exported result.
    let sourceHistoryID: UUID?
    var exportedHistoryID: UUID?

    @Published var annotations: [Annotation] = [] {
        didSet { rebuildRedactionsIfNeeded(oldValue: oldValue) }
    }
    @Published var cropRect: CGRect?
    @Published var background: BackgroundStyle {
        didSet { onBackgroundChange?(background) }
    }
    @Published var tool: EditorTool = .arrow {
        didSet {
            if oldValue != tool {
                commitPendingText()
                if tool != .select { selectedID = nil }
                if oldValue != .crop { toolBeforeCrop = oldValue }
            }
        }
    }
    @Published var color: RGBAColor = .bloomRose
    @Published var strokeLevel: StrokeLevel = .medium

    @Published private(set) var draft: Annotation?
    @Published private(set) var cropDraft: CGRect?
    @Published var selectedID: UUID?
    @Published var pendingText: PendingText?
    @Published private(set) var redactedBase: CGImage
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    var onBackgroundChange: ((BackgroundStyle) -> Void)?

    private struct Snapshot: Equatable {
        var annotations: [Annotation]
        var cropRect: CGRect?
    }

    private enum Interaction {
        case none
        case drawing
        case moving(original: Annotation, start: CGPoint, checkpointed: Bool)
        case cropping(start: CGPoint)
        case tap
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var interaction: Interaction = .none
    private var toolBeforeCrop: EditorTool = .arrow
    private static let undoLimit = 100

    init(image: CGImage, scale: CGFloat, mode: CaptureMode, background: BackgroundStyle, sourceHistoryID: UUID?) {
        self.original = image
        self.scale = max(scale, 1)
        self.mode = mode
        self.background = background
        self.sourceHistoryID = sourceHistoryID
        self.redactedBase = image
    }

    // MARK: - Derived

    var imageBounds: CGRect { CGRect(x: 0, y: 0, width: original.width, height: original.height) }
    var effectiveCrop: CGRect { cropRect ?? imageBounds }
    var vectorAnnotations: [Annotation] { annotations.filter { !$0.kind.isRedaction } }
    var redactions: [Annotation] { annotations.filter { $0.kind.isRedaction } }

    var nextCounterNumber: Int {
        (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
    }

    var selectedAnnotation: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    /// What the canvas draws. While cropping we show the whole image without beautify.
    func renderInput(forCropEditing: Bool) -> RenderInput {
        var hidden: Set<UUID> = []
        if let replacing = pendingText?.replacing { hidden.insert(replacing.id) }
        return RenderInput(
            base: redactedBase,
            crop: forCropEditing ? imageBounds : effectiveCrop,
            annotations: vectorAnnotations.filter { !hidden.contains($0.id) },
            background: forCropEditing ? BackgroundStyle(presetKey: nil, padding: 0, radius: 0, shadow: 0) : background,
            scale: scale
        )
    }

    func exportImage() -> CGImage? {
        commitPendingText()
        return Renderer.render(renderInput(forCropEditing: false))
    }

    // MARK: - Undo

    private var snapshot: Snapshot { Snapshot(annotations: annotations, cropRect: cropRect) }

    func checkpoint() {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        updateUndoFlags()
    }

    func undo() {
        commitPendingText()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    private func restore(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        cropRect = snapshot.cropRect
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Editing

    func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
    }

    func deleteSelected() {
        guard let selectedID else { return }
        checkpoint()
        annotations.removeAll { $0.id == selectedID }
        self.selectedID = nil
    }

    func resetCrop() {
        guard cropRect != nil else { return }
        checkpoint()
        cropRect = nil
    }

    func clearAll() {
        guard !annotations.isEmpty || cropRect != nil else { return }
        checkpoint()
        annotations.removeAll()
        cropRect = nil
        selectedID = nil
    }

    /// Applies the colour/size pickers to the selected annotation too (quick restyle).
    func applyStyleToSelection() {
        guard let selectedID, let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        var updated = annotations[index]
        updated.color = color
        updated.lineWidth = strokeLevel.lineWidth * scale
        updated.fontSize = strokeLevel.fontSize * scale
        guard updated != annotations[index] else { return }
        checkpoint()
        annotations[index] = updated
    }

    func commitPendingText() {
        guard let pending = pendingText else { return }
        pendingText = nil
        let trimmed = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = annotations
        if let replacing = pending.replacing {
            next.removeAll { $0.id == replacing.id }
        }
        if !trimmed.isEmpty {
            var annotation = pending.replacing ?? makeAnnotation(.text, at: pending.point)
            annotation.start = pending.point
            annotation.end = pending.point
            annotation.text = pending.text
            annotation.color = pending.color
            annotation.fontSize = pending.fontSize
            next.append(annotation)
        }
        guard next != annotations else { return }
        checkpoint()
        annotations = next
    }

    func cancelPendingText() {
        pendingText = nil
    }

    private func makeAnnotation(_ kind: Annotation.Kind, at point: CGPoint) -> Annotation {
        Annotation(
            kind: kind,
            start: point,
            end: point,
            color: color,
            lineWidth: strokeLevel.lineWidth * scale,
            fontSize: strokeLevel.fontSize * scale,
            number: kind == .counter ? nextCounterNumber : 0
        )
    }

    func topmostAnnotation(at point: CGPoint) -> Annotation? {
        let tolerance = 6 * scale
        return annotations.reversed().first { $0.hitTest(point, tolerance: tolerance) }
    }

    // MARK: - Pointer interaction (image pixel coordinates)

    func pointerDown(at point: CGPoint) {
        if pendingText != nil {
            commitPendingText()
            interaction = .none
            return
        }
        switch tool {
        case .select:
            if let hit = topmostAnnotation(at: point) {
                selectedID = hit.id
                interaction = .moving(original: hit, start: point, checkpointed: false)
            } else {
                selectedID = nil
                interaction = .none
            }
        case .arrow, .rectangle, .ellipse, .pixelate, .blur:
            if let kind = tool.annotationKind {
                draft = makeAnnotation(kind, at: point)
                interaction = .drawing
            }
        case .crop:
            let clamped = clamp(point)
            cropDraft = CGRect(origin: clamped, size: .zero)
            interaction = .cropping(start: clamped)
        case .text, .counter:
            interaction = .tap
        }
    }

    func pointerDragged(to point: CGPoint) {
        switch interaction {
        case .drawing:
            draft?.end = point
        case .moving(let original, let start, let checkpointed):
            guard point != start || checkpointed,
                  let index = annotations.firstIndex(where: { $0.id == original.id }) else { return }
            if !checkpointed {
                checkpoint()
                interaction = .moving(original: original, start: start, checkpointed: true)
            }
            annotations[index] = original.offset(by: CGSize(width: point.x - start.x, height: point.y - start.y))
        case .cropping(let start):
            let p = clamp(point)
            cropDraft = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                               width: abs(p.x - start.x), height: abs(p.y - start.y))
        case .tap, .none:
            break
        }
    }

    func pointerUp(at point: CGPoint) {
        defer { interaction = .none }
        switch interaction {
        case .drawing:
            if var finished = draft {
                finished.end = point
                if finished.isMeaningful { add(finished) }
            }
            draft = nil
        case .cropping:
            if let rect = cropDraft?.integral, rect.width >= 8, rect.height >= 8 {
                checkpoint()
                cropRect = rect
                tool = toolBeforeCrop
            }
            cropDraft = nil
        case .tap:
            if tool == .text {
                if let existing = topmostAnnotation(at: point), existing.kind == .text {
                    pendingText = PendingText(point: existing.start, text: existing.text,
                                              color: existing.color, fontSize: existing.fontSize, replacing: existing)
                } else {
                    pendingText = PendingText(point: point, text: "", color: color,
                                              fontSize: strokeLevel.fontSize * scale, replacing: nil)
                }
            } else if tool == .counter {
                add(makeAnnotation(.counter, at: point))
            }
        case .moving, .none:
            break
        }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), imageBounds.width), y: min(max(p.y, 0), imageBounds.height))
    }

    // MARK: - Redactions

    private func rebuildRedactionsIfNeeded(oldValue: [Annotation]) {
        let old = oldValue.filter { $0.kind.isRedaction }
        let new = redactions
        guard old != new else { return }
        redactedBase = Redactor.apply(new, to: original, scale: scale)
    }
}
