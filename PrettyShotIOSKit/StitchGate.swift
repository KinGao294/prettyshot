import CoreGraphics
import Foundation
import PrettyShotCore

/// Alignment and sticky-bar gate in front of 「下一步 · 美化」.
/// Reads `ScrollAssembly`; it does not reimplement stitching.
/// Duplicate-segment cards render whatever candidates Core already stored.
/// Finding those candidates stays in the open stitching PRs.
struct StitchGate: Equatable {
    enum Step: Equatable {
        case seams(Int)
        case sticky
        case duplicates(Int)
        case ready
    }

    var step: Step
    var canAdvance: Bool
    var primaryTitle: String
    var bottomBar: String?
    var overLimitPrompt: RestoreOverLimitPrompt
    var overLimitLine: String?
    var unresolvedDuplicateIDs: [String]
    var stickyPrompt: String?
    /// The shared bottom bar. `primaryTitle` and `bottomBar` above are read from it.
    var bar: StitchBottomBar

    static func evaluate(
        _ assembly: ScrollAssembly,
        maxHeight: Int = ScrollOutputLimit.maxHeight,
        maxPixels: Int = ScrollOutputLimit.maxPixels
    ) -> StitchGate {
        let bar = StitchBottomBar.evaluate(assembly)
        let unresolvedDuplicates = assembly.duplicateCandidates.filter(\.isUnresolved).map(\.id)
        return StitchGate(
            step: bar.step,
            canAdvance: bar.canAdvance,
            primaryTitle: bar.primaryTitle,
            bottomBar: bar.line,
            overLimitPrompt: assembly.restoreExportPrompt,
            overLimitLine: assembly.overLimitLine(maxHeight: maxHeight, maxPixels: maxPixels),
            unresolvedDuplicateIDs: unresolvedDuplicates,
            stickyPrompt: assembly.pendingSticky?.isUnresolved == true ? assembly.pendingSticky?.prompt : nil,
            bar: bar
        )
    }
}

struct StitchSession: Equatable {
    var assembly: ScrollAssembly
    var maxHeight: Int
    var maxPixels: Int
    /// Toast after a duplicate-segment choice, restore, or undo.
    var toast: StitchToast?

    init(
        assembly: ScrollAssembly,
        maxHeight: Int = ScrollOutputLimit.maxHeight,
        maxPixels: Int = ScrollOutputLimit.maxPixels
    ) {
        self.assembly = assembly
        self.maxHeight = maxHeight
        self.maxPixels = maxPixels
    }

    var gate: StitchGate {
        StitchGate.evaluate(assembly, maxHeight: maxHeight, maxPixels: maxPixels)
    }

    var bottomBar: StitchBottomBar { gate.bar }

    var duplicateCards: [DuplicateCardState] {
        assembly.duplicateCandidates.enumerated().map { offset, candidate in
            let detail: String
            if let pair = shotPair(for: candidate) {
                detail = IOSCopy.duplicateSeamDetail(first: pair.0, second: pair.1)
            } else {
                detail = IOSCopy.duplicateDetail
            }
            return DuplicateCardState(
                id: candidate.id,
                displayIndex: offset + 1,
                isPending: candidate.isUnresolved,
                question: IOSCopy.duplicateQuestion,
                detail: detail,
                handledLabel: candidate.choice.map(IOSCopy.duplicateHandled)
            )
        }
    }

    func duplicateCard(_ id: String) -> DuplicateCardState? {
        duplicateCards.first { $0.id == id }
    }

    /// Absolute shot numbers around the join a candidate sits under.
    /// Counted from the segments, so an unaligned seam earlier in the stack does not shift them.
    func shotPair(for candidate: DuplicateSegmentCandidate) -> (Int, Int)? {
        let segments = assembly.segments
        if segments.indices.contains(candidate.segmentIndex),
           let join = segments[candidate.segmentIndex].confidentSeamYs.firstIndex(of: candidate.startRow) {
            let shotsBefore = segments[..<candidate.segmentIndex].reduce(0) { $0 + $1.confidentSeamYs.count + 1 }
            let first = shotsBefore + join + 1
            return (first, first + 1)
        }
        guard candidate.seamNumber > 0 else { return nil }
        return (candidate.seamNumber, candidate.seamNumber + 1)
    }

    mutating func align(seam index: Int, overlap: Int) {
        assembly.align(seam: index, overlap: overlap)
        toast = nil
    }

    mutating func joinAsIs(seam index: Int) {
        assembly.joinAsIs(seam: index)
        toast = nil
    }

    /// Puts the overlap back on the automatic suggestion.
    /// Re-running duplicate detection is left to the stitching PRs; this only calls Core's current API.
    mutating func restoreAuto(seam index: Int) {
        assembly.restoreAutoAlignment(seam: index)
        // Re-detect clears the undo stack, so an old 「撤销」 must not stay on screen.
        toast = nil
    }

    mutating func confirmSticky(keepOnce: Bool) {
        assembly.confirmStickyBars(keepOnce: keepOnce)
    }

    mutating func setDedupe(_ on: Bool) -> StickyRestoreOutcome? {
        if on {
            assembly.dedupeStickyBars = true
            if assembly.pendingSticky?.isUnresolved == true {
                assembly.confirmStickyBars(keepOnce: true)
            }
            return nil
        }
        return assembly.restoreStickyBars(maxHeight: maxHeight, maxPixels: maxPixels)
    }

    mutating func resolveDuplicate(_ id: String, choice: DuplicateSegmentChoice) {
        let before = assembly.duplicateUndoCount
        assembly.resolveDuplicateCandidate(id, choice: choice)
        guard assembly.duplicateUndoCount > before, let index = displayIndex(of: id) else { return }
        toast = StitchToast(
            title: IOSCopy.duplicateChoiceToast(index: index, choice: choice),
            detail: IOSCopy.duplicateRemaining(assembly.pendingDuplicateConfirmCount),
            actionTitle: IOSCopy.undo
        )
    }

    mutating func restoreDuplicate(_ id: String) {
        let before = assembly.duplicateUndoCount
        assembly.restoreDuplicateCandidate(id)
        guard assembly.duplicateUndoCount > before, let index = displayIndex(of: id) else { return }
        toast = StitchToast(
            title: IOSCopy.duplicateRestoredToast(index: index),
            detail: IOSCopy.duplicateRemaining(assembly.pendingDuplicateConfirmCount),
            actionTitle: IOSCopy.undo
        )
    }

    mutating func undoDuplicate() {
        let before = assembly.duplicateUndoCount
        assembly.undoLastDuplicateCandidateChoice()
        guard assembly.duplicateUndoCount < before else { return }
        toast = StitchToast(
            title: IOSCopy.undone,
            detail: IOSCopy.duplicateRemaining(assembly.pendingDuplicateConfirmCount),
            actionTitle: nil
        )
    }

    private func displayIndex(of id: String) -> Int? {
        assembly.duplicateCandidates.firstIndex { $0.id == id }.map { $0 + 1 }
    }
}

struct PixelRedaction: Redactable, Equatable, Identifiable {
    var id = UUID()
    /// Full-image pixels, origin top-left, y down.
    var rect: CGRect
    var kind: RedactionKind = .pixelate

    var redactionKind: RedactionKind? { kind }
    var redactionRect: CGRect { rect }
    var isMeaningfulRedaction: Bool { rect.width >= 4 && rect.height >= 4 }
}

struct ArrowMark: Equatable, Identifiable {
    var id = UUID()
    /// Normalized to the full image, origin top-left.
    var start: CGPoint
    var end: CGPoint

    var isMeaningful: Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return (dx * dx + dy * dy).squareRoot() >= 0.02
    }
}
