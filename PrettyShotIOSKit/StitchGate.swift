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
            DuplicateCardState(
                id: candidate.id,
                displayIndex: offset + 1,
                isPending: candidate.isUnresolved,
                question: IOSCopy.duplicateQuestion,
                detail: IOSCopy.duplicateDetail,
                handledLabel: nil
            )
        }
    }

    func duplicateCard(_ id: String) -> DuplicateCardState? {
        duplicateCards.first { $0.id == id }
    }

    mutating func align(seam index: Int, overlap: Int) {
        assembly.align(seam: index, overlap: overlap)
    }

    mutating func joinAsIs(seam index: Int) {
        assembly.joinAsIs(seam: index)
    }

    /// Puts the overlap back on the automatic suggestion.
    /// Re-running duplicate detection is left to the stitching PRs; this only calls Core's current API.
    mutating func restoreAuto(seam index: Int) {
        assembly.restoreAutoAlignment(seam: index)
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
        assembly.resolveDuplicateCandidate(id, choice: choice)
    }

    mutating func restoreDuplicate(_ id: String) {
        assembly.restoreDuplicateCandidate(id)
    }

    mutating func undoDuplicate() {
        assembly.undoLastDuplicateCandidateChoice()
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
