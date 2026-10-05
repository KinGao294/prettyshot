import CoreGraphics
import Foundation

/// Output cap for one scrolling capture.
///
/// Measured by allocating RGBA buffers (the stitcher's storage) and timing a viewport-sized row
/// compare. The compare stayed flat as the output grew — matching looks at one viewport, not the
/// whole image — while memory scaled linearly:
/// - 24,000,000 pixels ≈ 91.6 MiB for one buffer, about 183 MiB if a second full-size buffer is
///   alive while compositing. Touching that buffer took ~50 ms.
/// - 48,000,000 pixels doubled it (~183 / 366 MiB, ~100 ms just to touch) and was rejected.
/// - A hard height of 16,384 still stops a narrow strip from becoming an extreme image
///   (800×16384 ≈ 50 MiB). At a typical 1600 px-wide retina region the pixel budget binds first
///   (15000 px, under the height cap). 1600×16384 alone is already 100 MiB.
public enum ScrollOutputLimit {
    public static let maxHeight = 16_384
    public static let maxPixels = 24_000_000

    public static var notice: String {
        "已达到长度上限（高 \(maxHeight) px，或 \(maxPixels / 1_000_000) 百万像素），滚动捕获已自动停止。"
    }

    /// How many more rows of `width` fit under both caps.
    public static func remainingRows(totalHeight: Int, width: Int, maxHeight: Int = maxHeight, maxPixels: Int = maxPixels) -> Int {
        let heightRoom = maxHeight - totalHeight
        guard heightRoom > 0, width > 0 else { return 0 }
        let used = Int64(max(totalHeight, 0)) * Int64(width)
        let pixelRoom = Int64(maxPixels) - used
        guard pixelRoom > 0 else { return 0 }
        let fromPixels = Int(pixelRoom / Int64(width))
        return max(0, min(heightRoom, fromPixels))
    }
}

public enum ScrollIngest: Equatable {
    case seeded
    case unchanged
    case appended(Int)
    case prepended(Int)
    /// Overlap was not confident. The frame started (or is) its own segment; nothing was force-joined.
    case unmatched
    case reachedLimit
    case ignored
}

public enum SeamState: Equatable {
    /// Confident automatic overlap inside one segment.
    case ok
    /// Could not be aligned safely. The image must not be flattened until the user decides.
    case needsAlignment
    /// User set an overlap, in rows trimmed from the top of the next segment.
    case aligned
    /// User explicitly stacked the segments with no overlap.
    case joinedAsIs
}

public struct SeamMark: Identifiable, Equatable {
    public var id: String
    public var state: SeamState
    /// Row in the full-resolution stack (top of the join).
    public var y: Int
    /// Index into `ScrollAssembly.seams` when this mark is a boundary between segments.
    public var boundaryIndex: Int?
    public var suggestedOverlap: Int?
    /// Extra line on the seam card. Blank frames use the designer's wording.
    public var note: String?

    public init(id: String, state: SeamState, y: Int, boundaryIndex: Int?, suggestedOverlap: Int?, note: String? = nil) {
        self.id = id
        self.state = state
        self.y = y
        self.boundaryIndex = boundaryIndex
        self.suggestedOverlap = suggestedOverlap
        self.note = note
    }
}

/// Header/footer pixels removed at one confident join, so dedupe can be turned back off.
public struct StickyRepeat: Equatable {
    /// Y in the deduped segment where the bars were taken out (between the old slice and the new one).
    public var seamY: Int
    public var header: RGBAImage
    public var footer: RGBAImage

    public init(seamY: Int, header: RGBAImage, footer: RGBAImage) {
        self.seamY = seamY
        self.header = header
        self.footer = footer
    }
}

public struct ScrollSegment: Equatable {
    public var image: RGBAImage
    /// Y positions, in the deduped `image`, where a confident join added new rows.
    public var confidentSeamYs: [Int]
    public var stickyRepeats: [StickyRepeat] = []

    public init(image: RGBAImage, confidentSeamYs: [Int], stickyRepeats: [StickyRepeat] = []) {
        self.image = image
        self.confidentSeamYs = confidentSeamYs
        self.stickyRepeats = stickyRepeats
    }
}

/// Paint for a 「待确认」 seam. Warn from the design, shared by the label and the long-image line.
public enum PendingSeamStyle {
    public static let warn: UInt32 = 0xE3B26B
    public static let text: UInt32 = 0x8A5A12
    public static let fillOpacity: Double = 0.18
    public static let labelBorderWidth: Int = 1
    /// Dashed stroke thickness of the seam line on the long image.
    public static let seamLineWidth: Int = 3

    public static var warnRGB: (UInt8, UInt8, UInt8) {
        (UInt8((warn >> 16) & 0xFF), UInt8((warn >> 8) & 0xFF), UInt8(warn & 0xFF))
    }
}

/// Rivals of the best shift. These are the thresholds the matcher already uses.
public enum AliasRival {
    /// Shifts this close are the same scroll, not a second candidate.
    public static let shiftGap = 2
    /// A rival may score this much worse than the best and still count.
    public static let scoreSlack = 4
    /// Integer half: `votes * voteFactor >= bestVotes`.
    public static let voteFactor = 2
}

/// Colors for a resolved confirmation seam.
public enum ResolvedSeamStyle {
    /// Mint for 「✓ 已确认」 and 「✓ 手动对齐」.
    public static let mint: UInt32 = 0x4F8F7E
    /// Mint in dark mode, same pair as iOS `stagedCheck`.
    public static let mintDark: UInt32 = 0x7EB8A8
    /// Neutral gray for 「直接拼」.
    public static let direct: UInt32 = 0x5C5751
    /// Tag fill for 「✓ 已确认」 and 「✓ 手动对齐」.
    public static let handledFillOpacity: Double = 0.22
    /// Tag fill for 「直接拼」.
    public static let directFillOpacity: Double = 0.12
    /// Solid tag border.
    public static let labelBorderWidth: Int = 1

    /// 「−28 px」 / 「+32 px」 with a real minus sign.
    public static func signedPixels(_ shift: Int) -> String {
        shift < 0 ? "−\(-shift) px" : "+\(shift) px"
    }
}

/// What the review window shows for one seam. The pending reverse seam uses the amber dashed label.
public struct SeamCard: Equatable {
    public enum Chrome: Equatable {
        /// Solid rose 「需要对齐」.
        case plain
        /// Amber dashed 「待确认」.
        case amberDashed
    }

    public var label: String
    public var chrome: Chrome
    public var title: String?
    public var reason: String?
    public var candidates: [String]
    /// Label ink. Unset until a resolved confirmation seam picks Mint or gray.
    public var labelColor: UInt32
    /// Label ink in dark mode. Same as `labelColor` unless the style has a dark variant.
    public var labelColorDark: UInt32
    /// Text drawn in the tag. Adds the signed shift to 「✓ 手动对齐」 when one was picked.
    public var tagText: String
    /// Tag fill opacity of `labelColor`. Zero when the tag has no fill rule.
    public var fillOpacity: Double
    /// Tag border width; solid for handled seams, dashed for 「待确认」.
    public var borderWidth: Int

    public init(
        label: String,
        chrome: Chrome,
        title: String? = nil,
        reason: String? = nil,
        candidates: [String] = [],
        labelColor: UInt32 = 0,
        labelColorDark: UInt32? = nil,
        tagText: String? = nil,
        fillOpacity: Double = 0,
        borderWidth: Int = 0
    ) {
        self.label = label
        self.chrome = chrome
        self.title = title
        self.reason = reason
        self.candidates = candidates
        self.labelColor = labelColor
        self.labelColorDark = labelColorDark ?? labelColor
        self.tagText = tagText ?? label
        self.fillOpacity = fillOpacity
        self.borderWidth = borderWidth
    }
}

public struct ScrollSeam: Equatable {
    public var kind: Kind
    /// Best-guess overlap (rows) when `kind` is `.needsAlignment`. Not applied until the user says so.
    public var suggestedOverlap: Int?
    /// Shown in the seam card when this boundary needs a reason, such as a blank frame.
    public var note: String?
    /// Set when several shifts share the best score and the join cannot pick one.
    public var pendingTitle: String?
    /// Display lines for those shifts, highest first. The selected line ends with 「 · 当前」.
    public var candidateLines: [String]
    /// Lone reverse candidate. The amber card reads this flag, not the note string.
    public var reversed: Bool
    /// Signed shifts behind `candidateLines`, same order (highest first). Empty unless this seam is a shift tie.
    public var candidateShifts: [Int]
    /// The shift the matcher picked, the one marked 「当前」. Nil when there was no guess.
    public var selectedShift: Int?
    /// Signed shift behind `suggestedOverlap` for a tie or a lone reverse.
    /// `suggestedOverlap` drops the sign; aligning on this shift keeps it.
    public var suggestedShift: Int? {
        guard reversed || !candidateShifts.isEmpty else { return nil }
        return selectedShift
    }
    /// Row of the upper segment where the last frame before this seam starts. Nil when unknown.
    public var upperFrameTop: Int?
    /// Rows from the top of the lower segment that go above the upper segment.
    /// Set by `align(seam:shift:)` when the shift reaches above the upper segment; only applied while aligned.
    public var prependRows: Int
    /// The shift chosen with `align(seam:shift:)`. Any other alignment clears it.
    public var alignedShift: Int?

    public enum Kind: Equatable {
        case needsAlignment
        case aligned(overlap: Int)
        case joinedAsIs
    }

    public init(
        kind: Kind,
        suggestedOverlap: Int? = nil,
        note: String? = nil,
        pendingTitle: String? = nil,
        candidateLines: [String] = [],
        reversed: Bool = false,
        candidateShifts: [Int] = [],
        selectedShift: Int? = nil,
        upperFrameTop: Int? = nil,
        prependRows: Int = 0,
        alignedShift: Int? = nil
    ) {
        self.kind = kind
        self.suggestedOverlap = suggestedOverlap
        self.note = note
        self.pendingTitle = pendingTitle
        self.candidateLines = candidateLines
        self.reversed = reversed
        self.candidateShifts = candidateShifts
        self.selectedShift = selectedShift
        self.upperFrameTop = upperFrameTop
        self.prependRows = prependRows
        self.alignedShift = alignedShift
    }

    /// Rows of the lower segment drawn above the upper segment. Zero unless aligned on a shift that reaches above it.
    public var appliedPrependRows: Int {
        if case .aligned = kind { return max(0, prependRows) }
        return 0
    }

    /// ML6b options while a tie or lone reverse still waits; empty once handled or for a plain seam.
    public var confirmationOptions: [String] {
        guard awaitsConfirmation, kind == .needsAlignment else { return [] }
        return StitchCopy.confirmationOptions
    }

    /// True when this boundary is a shift tie or a lone reverse, whatever the user has done since.
    var awaitsConfirmation: Bool {
        pendingTitle != nil || !candidateLines.isEmpty || reversed
    }

    /// Review copy for this boundary. `number` is the 1-based seam index.
    /// Amber 「待确认」 only while the seam still needs alignment.
    /// Confirming the auto-selected shift, picking another overlap, and stitching as-is each get their own label.
    public func card(number: Int) -> SeamCard {
        precondition(number >= 1)
        if awaitsConfirmation {
            switch kind {
            case .needsAlignment:
                if pendingTitle != nil || !candidateLines.isEmpty {
                    return SeamCard(
                        label: "待确认",
                        chrome: .amberDashed,
                        title: pendingTitle,
                        reason: note,
                        candidates: candidateLines,
                        labelColor: PendingSeamStyle.text
                    )
                }
                return SeamCard(
                    label: "待确认",
                    chrome: .amberDashed,
                    reason: note,
                    labelColor: PendingSeamStyle.text
                )
            case .aligned(let overlap):
                // A pick by shift compares shifts: +30 and −30 can share an overlap and still differ.
                let confirmed: Bool
                if let alignedShift, let selectedShift {
                    confirmed = alignedShift == selectedShift
                } else {
                    confirmed = suggestedOverlap.map { overlap == $0 } ?? false
                }
                let label = confirmed ? "✓ 已确认" : "✓ 手动对齐"
                var tag = label
                if !confirmed, let alignedShift {
                    tag += " · " + ResolvedSeamStyle.signedPixels(alignedShift)
                }
                return SeamCard(
                    label: label,
                    chrome: .plain,
                    labelColor: ResolvedSeamStyle.mint,
                    labelColorDark: ResolvedSeamStyle.mintDark,
                    tagText: tag,
                    fillOpacity: ResolvedSeamStyle.handledFillOpacity,
                    borderWidth: ResolvedSeamStyle.labelBorderWidth
                )
            case .joinedAsIs:
                return SeamCard(
                    label: "直接拼",
                    chrome: .plain,
                    labelColor: ResolvedSeamStyle.direct,
                    fillOpacity: ResolvedSeamStyle.directFillOpacity,
                    borderWidth: ResolvedSeamStyle.labelBorderWidth
                )
            }
        }
        let label: String
        switch kind {
        case .needsAlignment:
            label = "需要对齐"
        case .aligned:
            label = "已手动对齐"
        case .joinedAsIs:
            label = "已按原样拼接"
        }
        return SeamCard(label: label, chrome: .plain, reason: note)
    }

    public var state: SeamState {
        switch kind {
        case .needsAlignment: return .needsAlignment
        case .aligned: return .aligned
        case .joinedAsIs: return .joinedAsIs
        }
    }

    public var isResolved: Bool {
        if case .needsAlignment = kind { return false }
        return true
    }

    /// Overlap the editor should show. Unresolved seams report the suggestion, still unapplied.
    public var editorOverlap: Int {
        switch kind {
        case .needsAlignment: return max(0, suggestedOverlap ?? 0)
        case .aligned(let overlap): return max(0, overlap)
        case .joinedAsIs: return 0
        }
    }
}

/// Memoizes presented segments. A class so slider updates can reuse buffers without copying the assembly.
final class PresentationCache {
    struct RepeatKey: Hashable {
        var seamY: Int
        var headerHeight: Int
        var footerHeight: Int
    }

    struct Key: Hashable {
        var dedupe: Bool
        var index: Int
        var width: Int
        var height: Int
        var pixelCount: Int
        var seamYs: [Int]
        var repeats: [RepeatKey]
    }

    var values: [Key: (image: RGBAImage, confidentSeamYs: [Int])] = [:]
    var hits = 0
}

/// One undecided sticky-bar run. Consecutive uncertain frames share this instead of each opening a seam.
public struct PendingStickyConfirmation: Equatable {
    public var headerRows: Int
    public var footerRows: Int
    public var seamCount: Int
    /// Nil until the user picks one treatment for every seam in the run.
    public var keepOnce: Bool?

    public init(headerRows: Int, footerRows: Int, seamCount: Int, keepOnce: Bool?) {
        self.headerRows = headerRows
        self.footerRows = footerRows
        self.seamCount = seamCount
        self.keepOnce = keepOnce
    }

    public var isUnresolved: Bool { keepOnce == nil }

    /// 「待确认 · 顶部这条可能是固定栏（涉及 N 处接缝）」 when the uncertain band is a header.
    public var prompt: String {
        StitchCopy.uncertainPrompt(headerRows: headerRows, footerRows: footerRows, seamCount: seamCount)
    }
}

/// 「保留一次」 or 「都保留」. Either choice resolves a duplicate-segment candidate.
public enum DuplicateSegmentChoice: Equatable {
    /// 「保留一次」
    case keepOnce
    /// 「都保留」
    case keepBoth
}

/// One recorded duplicate-segment choice, so undo can put that candidate back.
struct DuplicateChoiceRecord: Equatable {
    var id: String
    var previous: DuplicateSegmentChoice?
    /// The seam-moved flag before this choice, so undo can put the 「需要重选」 note back.
    var previousSeamMoved: Bool = false
    var previousMovedSeam: Int? = nil
}

/// What 「完成」 or 「还原自动」 did to the choices already on the assembly.
public struct DuplicateRedetectSummary: Equatable {
    public var keptChoiceCount: Int
    public var pendingCount: Int
    /// Visible number of the boundary whose choices were cleared. Nil when nothing was cleared.
    public var clearedSeamNumber: Int?
    public var clearedChoiceCount: Int

    public init(keptChoiceCount: Int, pendingCount: Int, clearedSeamNumber: Int?, clearedChoiceCount: Int) {
        self.keptChoiceCount = keptChoiceCount
        self.pendingCount = pendingCount
        self.clearedSeamNumber = clearedSeamNumber
        self.clearedChoiceCount = clearedChoiceCount
    }
}

/// A stretch that may repeat an earlier segment. It stays in 「待确认」 until the user chooses.
public struct DuplicateSegmentCandidate: Equatable, Identifiable {
    public var id: String
    /// Nil until the user chooses 「只保留一次」 or 「都保留」.
    public var choice: DuplicateSegmentChoice?
    /// 1-based confident seam this repeat sits under. 0 when the candidate was built without one.
    public var seamNumber: Int
    public var rowCount: Int
    /// Segment that owns `startRow` in that segment's stored image.
    public var segmentIndex: Int
    /// First duplicated row. 「只保留一次」 removes `rowCount` rows starting here.
    public var startRow: Int
    /// Overlap of the seam above this segment when the candidate was recorded.
    /// Segment 0 has no seam above it, so this stays 0. A later 「完成」 keeps the choice
    /// only while that same seam still has this overlap.
    public var offset: Int
    /// True after re-detect cleared a choice because this segment's boundary moved.
    public var seamMoved: Bool
    /// Visible number of the boundary that moved. Nil unless `seamMoved` is true.
    public var movedSeamNumber: Int?

    public init(
        id: String,
        choice: DuplicateSegmentChoice? = nil,
        seamNumber: Int = 0,
        rowCount: Int = 0,
        segmentIndex: Int = 0,
        startRow: Int = 0,
        offset: Int = 0,
        seamMoved: Bool = false,
        movedSeamNumber: Int? = nil
    ) {
        self.id = id
        self.choice = choice
        self.seamNumber = seamNumber
        self.rowCount = rowCount
        self.segmentIndex = segmentIndex
        self.startRow = startRow
        self.offset = offset
        self.seamMoved = seamMoved
        self.movedSeamNumber = movedSeamNumber
    }

    public var isUnresolved: Bool { choice == nil }

    public func pendingTitle(displayIndex: Int) -> String {
        StitchCopy.duplicatePendingTitle(displayIndex)
    }

    public var locationLine: String {
        // A cleared card names the seam above it, the one align crops, so the label matches the toast.
        let namedSeam = (seamMoved && choice == nil ? movedSeamNumber : nil) ?? seamNumber
        return StitchCopy.duplicateLocation(seam: namedSeam, rows: rowCount, seamMoved: seamMoved && choice == nil)
    }

    public var handledLine: String? {
        guard let choice else { return nil }
        return StitchCopy.duplicateHandled(choice)
    }
}

/// Amber box on the long image for one still-pending duplicate. Resolved choices are not marked.
public struct DuplicateRegionMark: Equatable, Identifiable {
    public var id: String
    /// 1-based index in `duplicateCandidates`, same number as the sidebar card.
    public var displayIndex: Int
    /// Top of the repeated rows in the stacked preview, full-image pixels.
    public var y: Int
    public var height: Int
    public var label: String
}

public enum StickyRestoreOutcome: Equatable {
    case restored(height: Int)
    case alreadyRestored
    case nothingToRestore
    /// The full restored image would pass the single-image cap. Nothing was clipped.
    case exceedsLimit(height: Int, message: String)
}

/// Segments split only where alignment was not confident. Confident joins are already baked in.
public struct ScrollAssembly: Equatable {
    public var segments: [ScrollSegment] = []
    /// `seams[i]` sits between `segments[i]` and `segments[i + 1]`.
    public var seams: [ScrollSeam] = []
    /// When true, sticky header/footer pixels are kept once. Turning this off splices them back in.
    public var dedupeStickyBars = true
    /// Set when a sticky band was plausible but not safe to decide automatically.
    public var pendingSticky: PendingStickyConfirmation? = nil
    /// Repeated stretches waiting for 「保留一次」 or 「都保留」. Not seams, and not the sticky bar.
    public var duplicateCandidates: [DuplicateSegmentCandidate] = []
    /// Newest resolution last. Undo writes that candidate's previous choice back.
    var duplicateChoiceUndo: [DuplicateChoiceRecord] = []
    /// Reused `presented` images so dragging a seam does not copy the whole stack again.
    var presentationCache = PresentationCache()

    public init(
        segments: [ScrollSegment] = [],
        seams: [ScrollSeam] = [],
        dedupeStickyBars: Bool = true,
        pendingSticky: PendingStickyConfirmation? = nil,
        duplicateCandidates: [DuplicateSegmentCandidate] = []
    ) {
        self.segments = segments
        self.seams = seams
        self.dedupeStickyBars = dedupeStickyBars
        self.pendingSticky = pendingSticky
        self.duplicateCandidates = duplicateCandidates
    }

    public static func == (lhs: ScrollAssembly, rhs: ScrollAssembly) -> Bool {
        lhs.segments == rhs.segments
            && lhs.seams == rhs.seams
            && lhs.dedupeStickyBars == rhs.dedupeStickyBars
            && lhs.pendingSticky == rhs.pendingSticky
            && lhs.duplicateCandidates == rhs.duplicateCandidates
            && lhs.duplicateChoiceUndo == rhs.duplicateChoiceUndo
    }

    public var needsReview: Bool {
        if pendingSticky?.isUnresolved == true { return true }
        if duplicateCandidates.contains(where: \.isUnresolved) { return true }
        return seams.contains { !$0.isResolved }
    }

    /// The stitch preview opens while a seam, a duplicate-segment candidate, or a sticky-bar choice still needs a decision.
    /// A confident sticky-bar dedupe stays on and does not open it or block Done.
    public var opensStitchReview: Bool { needsReview }

    public var presentedCacheHits: Int { presentationCache.hits }

    public var hasStickyRepeats: Bool {
        segments.contains { segment in
            segment.stickyRepeats.contains { $0.header.height > 0 || $0.footer.height > 0 }
        }
    }

    public var confidentSeamCount: Int { segments.reduce(0) { $0 + $1.confidentSeamYs.count } }

    /// Seams the user has not aligned or joined as-is.
    public var unalignedSeamCount: Int { seams.filter { !$0.isResolved }.count }

    /// Duplicate-segment candidates with no 「保留一次」 or 「都保留」 yet.
    /// Unaligned seams and the uncertain sticky bar are not included.
    public var pendingDuplicateConfirmCount: Int {
        duplicateCandidates.reduce(0) { count, candidate in
            candidate.isUnresolved ? count + 1 : count
        }
    }

    /// Records 「保留一次」 or 「都保留」 and drops that candidate out of 「待确认」.
    public mutating func resolveDuplicateCandidate(_ id: String, choice: DuplicateSegmentChoice) {
        guard let index = duplicateCandidates.firstIndex(where: { $0.id == id }) else { return }
        let previous = duplicateCandidates[index].choice
        guard previous != choice else { return }
        duplicateChoiceUndo.append(DuplicateChoiceRecord(
            id: id,
            previous: previous,
            previousSeamMoved: duplicateCandidates[index].seamMoved,
            previousMovedSeam: duplicateCandidates[index].movedSeamNumber
        ))
        duplicateCandidates[index].choice = choice
        duplicateCandidates[index].seamMoved = false
        duplicateCandidates[index].movedSeamNumber = nil
    }

    /// Puts the most recent duplicate-segment choice back. An undone resolution counts as 「待确认」 again.
    public mutating func undoLastDuplicateCandidateChoice() {
        guard let last = duplicateChoiceUndo.popLast() else { return }
        guard let index = duplicateCandidates.firstIndex(where: { $0.id == last.id }) else { return }
        duplicateCandidates[index].choice = last.previous
        duplicateCandidates[index].seamMoved = last.previousSeamMoved
        duplicateCandidates[index].movedSeamNumber = last.previousMovedSeam
    }

    /// Puts one candidate back to unresolved (`choice == nil`) and records that restore on the undo stack.
    /// A missing id, or a candidate that is already unresolved, is left unchanged.
    /// Restoring the same candidate again does not push a second undo entry.
    public mutating func restoreDuplicateCandidate(_ id: String) {
        guard let index = duplicateCandidates.firstIndex(where: { $0.id == id }) else { return }
        guard let previous = duplicateCandidates[index].choice else { return }
        duplicateChoiceUndo.append(DuplicateChoiceRecord(
            id: id,
            previous: previous,
            previousSeamMoved: duplicateCandidates[index].seamMoved,
            previousMovedSeam: duplicateCandidates[index].movedSeamNumber
        ))
        duplicateCandidates[index].choice = nil
        duplicateCandidates[index].seamMoved = false
        duplicateCandidates[index].movedSeamNumber = nil
    }

    public var duplicateUndoCount: Int { duplicateChoiceUndo.count }

    /// Which preview step the primary button is on. Each step counts only its own kind.
    public enum PreviewPrimaryStep: Equatable {
        case seam
        case sticky
        case duplicate
        case beautify
    }

    public var previewPrimaryStep: PreviewPrimaryStep {
        if unalignedSeamCount > 0 { return .seam }
        if pendingSticky?.isUnresolved == true { return .sticky }
        if pendingDuplicateConfirmCount > 0 { return .duplicate }
        return .beautify
    }

    /// Seam step: 「处理下一处 · N」 with N = 待对齐 (position-uncertain seams included).
    /// Sticky step: 「处理下一处 · 1」. Duplicate step: 「先确认 N 处重复段」.
    /// Ready: 「下一步 · 美化 →」.
    public var previewPrimaryTitle: String {
        switch previewPrimaryStep {
        case .seam:
            return StitchCopy.handleNext(unalignedSeamCount)
        case .sticky:
            return StitchCopy.handleNext(1)
        case .duplicate:
            return StitchCopy.confirmDuplicates(pendingDuplicateConfirmCount)
        case .beautify:
            return StitchCopy.nextBeautify
        }
    }

    /// 「开始拼接」. Drops this pass's candidates and the undo stack.
    /// The next ingest identifies uncertain duplicates again.
    public mutating func beginStitch() {
        clearDuplicateReview()
    }

    /// Manual alignment 「完成」. The seam overlap stays. Duplicate detection runs again.
    /// A candidate keeps its choice when the seam, the boundary overlap, and the row range are unchanged.
    /// Choices on a boundary that moved go back to 待确认. The undo stack still clears.
    @discardableResult
    public mutating func completeManualAlignment() -> DuplicateRedetectSummary {
        redetectDuplicateCandidates()
    }

    /// 「还原自动」 after the seam overlap has been put back. Re-runs duplicate detection the same way as 「完成」.
    @discardableResult
    public mutating func restoreAutomaticAlignment() -> DuplicateRedetectSummary {
        redetectDuplicateCandidates()
    }

    /// Overlap of the seam above this segment. `align(seam:)` crops the top of the next segment,
    /// so a candidate moves only when that upper seam moves. Segment 0 has no seam above it.
    private func displacement(forSegment index: Int) -> Int {
        let above = index - 1
        guard above >= 0, seams.indices.contains(above) else { return 0 }
        return seams[above].editorOverlap
    }

    /// Scans confident seams again. Same seam, overlap, and row range keep the previous choice.
    private mutating func redetectDuplicateCandidates() -> DuplicateRedetectSummary {
        let previous = duplicateCandidates
        var found: [DuplicateSegmentCandidate] = []
        var number = 0
        var clearedBySeam: [Int: Int] = [:]
        let options = ScrollStitcher.Options()
        for (segmentIndex, segment) in segments.enumerated() {
            let rows = RowSamples.make(segment.image, options: options)
            for seamY in segment.confidentSeamYs {
                number += 1
                guard let rowCount = RowSamples.seamAdjacentDuplicate(rows, seamY: seamY) else { continue }
                let offset = displacement(forSegment: segmentIndex)
                var candidate = DuplicateSegmentCandidate(
                    id: "dup-\(segmentIndex)-\(number)-\(seamY)",
                    seamNumber: number,
                    rowCount: rowCount,
                    segmentIndex: segmentIndex,
                    startRow: seamY,
                    offset: offset
                )
                if let old = previous.first(where: {
                    $0.segmentIndex == segmentIndex
                        && $0.seamNumber == number
                        && $0.startRow == seamY
                        && $0.rowCount == rowCount
                }) {
                    if old.offset == offset {
                        candidate.choice = old.choice
                        if old.choice == nil, old.seamMoved {
                            candidate.seamMoved = true
                            candidate.movedSeamNumber = old.movedSeamNumber
                        }
                    } else if old.choice != nil {
                        let boundary = segmentIndex - 1
                        let moved = boundary >= 0 && seams.indices.contains(boundary)
                            ? visibleSeamNumber(boundary: boundary)
                            : nil
                        candidate.seamMoved = true
                        candidate.movedSeamNumber = moved
                        if let moved {
                            clearedBySeam[moved, default: 0] += 1
                        }
                    }
                }
                found.append(candidate)
            }
            if segmentIndex < seams.count {
                number += 1
            }
        }
        duplicateCandidates = found
        duplicateChoiceUndo = []
        presentationCache = PresentationCache()
        let cleared = clearedBySeam.max { $0.value < $1.value }
        let clearedCount = cleared?.value ?? 0
        return DuplicateRedetectSummary(
            keptChoiceCount: found.filter { $0.choice != nil }.count,
            pendingCount: found.filter(\.isUnresolved).count,
            clearedSeamNumber: clearedCount > 0 ? cleared?.key : nil,
            clearedChoiceCount: clearedCount
        )
    }

    private mutating func clearDuplicateReview() {
        duplicateCandidates = []
        duplicateChoiceUndo = []
    }

    /// Unaligned seams, unresolved duplicate-segment candidates, and one uncertain sticky band.
    /// The three counts stay separate. Sticky confirmation is not part of 「待确认」.
    public var reviewRemainder: StitchCopy.Remainder {
        StitchCopy.Remainder(
            unaligned: unalignedSeamCount,
            pendingConfirm: pendingDuplicateConfirmCount,
            stickyPending: pendingSticky?.isUnresolved == true
        )
    }

    public var unresolvedItemCount: Int { reviewRemainder.count }

    public var reviewBottomBar: String? { StitchCopy.bottomBar(reviewRemainder) }

    /// Seam number in the same order the preview lists marks (confident seams, then the boundary).
    public func visibleSeamNumber(boundary: Int) -> Int {
        var number = 0
        for segmentIndex in segments.indices {
            number += segments[segmentIndex].confidentSeamYs.count
            if segmentIndex < seams.count {
                number += 1
                if segmentIndex == boundary { return number }
            }
        }
        return max(1, boundary + 1)
    }

    /// Pending duplicate regions only. `y` matches the stacked preview, after earlier 「只保留一次」 cuts.
    public func duplicateRegionMarks() -> [DuplicateRegionMark] {
        guard !segments.isEmpty else { return [] }
        var marks: [DuplicateRegionMark] = []
        var origin = 0
        func take(segmentIndex: Int, imageHeight: Int, start: Int) {
            for (offset, candidate) in duplicateCandidates.enumerated()
            where candidate.segmentIndex == segmentIndex && candidate.isUnresolved && candidate.rowCount > 0 {
                let local = logicalPresentedRow(candidate.startRow, segmentIndex: segmentIndex)
                let end = local + candidate.rowCount
                let visibleStart = max(local, start)
                let visibleEnd = min(end, imageHeight)
                guard visibleEnd > visibleStart else { continue }
                marks.append(DuplicateRegionMark(
                    id: candidate.id,
                    displayIndex: offset + 1,
                    y: origin + (visibleStart - start),
                    height: visibleEnd - visibleStart,
                    label: StitchCopy.duplicatePendingTitle(offset + 1)
                ))
            }
            origin += max(0, imageHeight - start)
        }
        // Rows a reverse shift put above segment `index`, taken from the top of the next segment.
        func lead(above index: Int) -> Int {
            guard seams.indices.contains(index), segments.indices.contains(index + 1) else { return 0 }
            return min(seams[index].appliedPrependRows, presented(at: index + 1).image.height)
        }
        let first = presented(at: 0).image
        origin += lead(above: 0)
        take(segmentIndex: 0, imageHeight: first.height, start: 0)
        for index in seams.indices where segments.indices.contains(index + 1) {
            let next = presented(at: index + 1).image
            let start: Int
            switch seams[index].kind {
            case .needsAlignment, .joinedAsIs:
                start = 0
            case .aligned(let overlap):
                start = min(max(0, overlap), next.height)
            }
            origin += lead(above: index + 1)
            if start < next.height {
                take(segmentIndex: index + 1, imageHeight: next.height, start: start)
            }
        }
        return marks.sorted { lhs, rhs in
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            return lhs.displayIndex < rhs.displayIndex
        }
    }

    public func previewStackHeight() -> Int {
        layoutPieces().fullHeight
    }

    /// Scroll target for a duplicate card. The preview uses the same id.
    public static func duplicatePreviewScrollID(_ candidateID: String) -> String {
        "dup-region-\(candidateID)"
    }

    public var restoreExportPrompt: RestoreOverLimitPrompt {
        .make(unalignedCount: unalignedSeamCount)
    }

    public func displayedSegmentHeight(_ index: Int) -> Int {
        guard segments.indices.contains(index) else { return 0 }
        return presented(at: index).image.height
    }

    /// Height of the stack if sticky bars are spliced back in. Does not allocate the pixel buffer.
    public func stackedHeight(deduping: Bool) -> Int {
        guard let first = segments.first else { return 0 }
        var total = presentedHeight(first, dedupe: deduping, index: 0)
        for index in seams.indices where segments.indices.contains(index + 1) {
            let nextHeight = presentedHeight(segments[index + 1], dedupe: deduping, index: index + 1)
            let start: Int
            switch seams[index].kind {
            case .needsAlignment, .joinedAsIs:
                start = 0
            case .aligned(let overlap):
                start = min(max(0, overlap), nextHeight)
            }
            total += max(0, nextHeight - start)
            total += min(seams[index].appliedPrependRows, nextHeight)
        }
        return total
    }

    /// Line 1 of the over-limit restore prompt, or nil when the restored stack fits.
    public func overLimitLine(
        maxHeight: Int = ScrollOutputLimit.maxHeight,
        maxPixels: Int = ScrollOutputLimit.maxPixels
    ) -> String? {
        let height = stackedHeight(deduping: false)
        let width = segments.first?.image.width ?? 0
        let pixels = Int64(max(width, 0)) * Int64(max(height, 0))
        guard height > maxHeight || pixels > Int64(maxPixels) else { return nil }
        return StitchCopy.overLimit(height: height, pixels: pixels, maxHeight: maxHeight, maxPixels: maxPixels)
    }

    /// ML6b 「确认当前位移」. Same as `alignToSuggestion(seam:)`; kept only because existing tests call this name.
    public mutating func confirmCurrentShift(seam index: Int) {
        alignToSuggestion(seam: index)
    }

    /// ML6c 「− 底栏 F · 顶栏 H」 while bars are kept once; ML6d 「固定栏已接回」 after restore.
    /// Nil when the capture has no sticky bars.
    public var stickyBandLabel: String? {
        let repeats = segments.flatMap(\.stickyRepeats).filter { $0.header.height > 0 || $0.footer.height > 0 }
        guard let first = repeats.first else { return nil }
        guard dedupeStickyBars else { return StitchCopy.stickyReattached }
        return StitchCopy.dedupedBand(footer: first.footer.height, header: first.header.height)
    }

    /// Turns dedupe off when the restored image fits in one capture. Over the cap, leaves dedupe on.
    public mutating func restoreStickyBars(
        maxHeight: Int = ScrollOutputLimit.maxHeight,
        maxPixels: Int = ScrollOutputLimit.maxPixels
    ) -> StickyRestoreOutcome {
        guard hasStickyRepeats else { return .nothingToRestore }
        guard dedupeStickyBars else { return .alreadyRestored }
        let height = stackedHeight(deduping: false)
        if let message = overLimitLine(maxHeight: maxHeight, maxPixels: maxPixels) {
            return .exceedsLimit(height: height, message: message)
        }
        dedupeStickyBars = false
        if pendingSticky != nil { pendingSticky?.keepOnce = false }
        return .restored(height: height)
    }

    /// One choice for every seam in the uncertain run.
    public mutating func confirmStickyBars(keepOnce: Bool) {
        dedupeStickyBars = keepOnce
        if pendingSticky != nil { pendingSticky?.keepOnce = keepOnce }
    }

    /// Restored (or deduped) pieces split so each image stays inside the single-capture caps.
    /// Rows are never dropped to satisfy the cap; a piece that would overflow starts the next image.
    /// 「只保留一次」 rows are already gone, including when a history restore exports with sticky bars spliced back.
    /// Refuses while any seam is still unaligned or a duplicate candidate is still 待确认, so nothing is stitched silently.
    public func exportWithinLimits(
        dedupeStickyBars dedupe: Bool,
        maxHeight: Int = ScrollOutputLimit.maxHeight,
        maxPixels: Int = ScrollOutputLimit.maxPixels
    ) -> [RGBAImage] {
        if seams.contains(where: { !$0.isResolved }) { return [] }
        if duplicateCandidates.contains(where: \.isUnresolved) { return [] }
        var slices: [RGBAImage] = []
        for index in segments.indices {
            var parts = [imageForExport(index: index, dedupe: dedupe)]
            if index > 0, seams.indices.contains(index - 1) {
                let drop: Int
                switch seams[index - 1].kind {
                case .needsAlignment, .joinedAsIs:
                    drop = 0
                case .aligned(let overlap):
                    drop = max(0, overlap)
                }
                parts = Self.droppingRows(drop, from: parts)
            }
            // Rows a reverse shift put above this segment come from the top of the next one.
            if seams.indices.contains(index), segments.indices.contains(index + 1), seams[index].appliedPrependRows > 0 {
                let lower = imageForExport(index: index + 1, dedupe: dedupe)
                let lifted = min(seams[index].appliedPrependRows, lower.height)
                if lifted > 0 {
                    slices.append(lower.crop(rows: 0..<lifted))
                }
            }
            slices.append(contentsOf: parts)
        }
        return Self.pack(slices, maxHeight: maxHeight, maxPixels: maxPixels)
    }

    /// The segment the user sees for this dedupe flag, with 「只保留一次」 rows already skipped.
    private func imageForExport(index: Int, dedupe: Bool) -> RGBAImage {
        if dedupe == dedupeStickyBars {
            return presented(at: index).image
        }
        guard segments.indices.contains(index) else {
            return RGBAImage(width: 0, height: 0, pixels: [])
        }
        let built = Self.makePresented(segments[index], dedupe: dedupe)
        return applyingKeepOnce(built, segmentIndex: index, dedupe: dedupe).image
    }

    public mutating func align(seam index: Int, overlap: Int) {
        guard seams.indices.contains(index), segments.indices.contains(index + 1) else { return }
        let limit = max(0, presented(at: index + 1).image.height - 1)
        seams[index].kind = .aligned(overlap: min(max(0, overlap), limit))
        seams[index].prependRows = 0
        seams[index].alignedShift = nil
    }

    /// Aligns a seam on a signed shift: the lower segment's first frame starts `shift` rows below
    /// the last frame of the upper segment (above it when negative).
    /// A positive shift is the usual overlap, `frame height − shift`.
    /// A negative shift that reaches above the upper segment puts those rows on top of it,
    /// the same way an upward join inside one segment does, and drops the rest of the repeat.
    public mutating func align(seam index: Int, shift: Int) {
        guard seams.indices.contains(index), segments.indices.contains(index + 1) else { return }
        let upperHeight = presented(at: index).image.height
        let lowerHeight = presented(at: index + 1).image.height
        let storedTop = seams[index].upperFrameTop.map { logicalPresentedRow($0, segmentIndex: index) }
        let upperTop = min(max(0, storedTop ?? (upperHeight - lowerHeight)), upperHeight)
        let lowerTop = upperTop + shift
        if lowerTop >= 0 {
            let limit = max(0, lowerHeight - 1)
            seams[index].kind = .aligned(overlap: min(max(0, upperHeight - lowerTop), limit))
            seams[index].prependRows = 0
        } else {
            let lifted = min(-lowerTop, lowerHeight)
            seams[index].kind = .aligned(overlap: min(lifted + upperHeight, lowerHeight))
            seams[index].prependRows = lifted
        }
        seams[index].alignedShift = shift
    }

    /// 「按此对齐」 / ML6b 「确认当前位移」: the one way to align on the suggestion (PRD v0.3.43).
    /// A tie or lone reverse aligns on its signed shift (the one marked 「当前」);
    /// any other seam uses the suggested overlap.
    public mutating func alignToSuggestion(seam index: Int) {
        guard seams.indices.contains(index) else { return }
        if let shift = seams[index].suggestedShift {
            align(seam: index, shift: shift)
        } else {
            align(seam: index, overlap: seams[index].suggestedOverlap ?? 0)
        }
    }

    /// A confirmation seam goes back to amber 「待确认」.
    /// Any other seam returns to the suggested overlap and stays aligned.
    /// This is 「还原自动」: duplicate detection runs again. Choices stay when this overlap
    /// matches the one stored on the candidate.
    @discardableResult
    public mutating func restoreAutoAlignment(seam index: Int) -> DuplicateRedetectSummary {
        guard seams.indices.contains(index) else {
            return DuplicateRedetectSummary(
                keptChoiceCount: duplicateCandidates.filter { $0.choice != nil }.count,
                pendingCount: pendingDuplicateConfirmCount,
                clearedSeamNumber: nil,
                clearedChoiceCount: 0
            )
        }
        if seams[index].awaitsConfirmation {
            seams[index].kind = .needsAlignment
            seams[index].prependRows = 0
            seams[index].alignedShift = nil
            return restoreAutomaticAlignment()
        }
        align(seam: index, overlap: seams[index].suggestedOverlap ?? 0)
        return restoreAutomaticAlignment()
    }

    public mutating func joinAsIs(seam index: Int) {
        guard seams.indices.contains(index) else { return }
        seams[index].kind = .joinedAsIs
        seams[index].prependRows = 0
        seams[index].alignedShift = nil
    }

    /// 1:1 crop around a boundary. The rows the overlap hides are drawn at partial alpha
    /// over the bottom of the upper segment so the offset is visible while dragging.
    public func seamLoupe(boundary: Int, overlap: Int, band: Int = 72) -> RGBAImage? {
        guard segments.indices.contains(boundary), segments.indices.contains(boundary + 1) else { return nil }
        let upper = presented(at: boundary).image
        let lower = presented(at: boundary + 1).image
        guard upper.width > 0, upper.width == lower.width, upper.height > 0, lower.height > 0 else { return nil }
        let cropW = min(upper.width, 420)
        let x0 = max(0, (upper.width - cropW) / 2)
        let overlap = min(max(0, overlap), max(0, lower.height - 1))
        let topBand = min(max(1, band), upper.height)
        let botBand = min(band / 2, max(0, lower.height - overlap))
        let ghost = min(overlap, topBand)
        let height = topBand + botBand
        guard height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: cropW * height * 4)

        func blend(from image: RGBAImage, srcY: Int, dstY: Int, alpha: Int?) {
            guard srcY >= 0, srcY < image.height, dstY >= 0, dstY < height else { return }
            image.withRow(srcY) { src in
                let dst = dstY * cropW * 4
                let srcBase = x0 * 4
                guard srcBase + cropW * 4 <= src.count, dst + cropW * 4 <= pixels.count else { return }
                for x in 0..<cropW {
                    let s = srcBase + x * 4
                    let d = dst + x * 4
                    if let alpha {
                        for channel in 0..<3 {
                            let base = Int(pixels[d + channel])
                            let over = Int(src[s + channel])
                            pixels[d + channel] = UInt8((base * (255 - alpha) + over * alpha) / 255)
                        }
                    } else {
                        pixels[d] = src[s]
                        pixels[d + 1] = src[s + 1]
                        pixels[d + 2] = src[s + 2]
                    }
                    pixels[d + 3] = 255
                }
            }
        }

        for row in 0..<topBand {
            blend(from: upper, srcY: upper.height - topBand + row, dstY: row, alpha: nil)
        }
        if ghost > 0 {
            let ghostStart = overlap - ghost
            for row in 0..<ghost {
                blend(from: lower, srcY: ghostStart + row, dstY: topBand - ghost + row, alpha: 115)
            }
        }
        for row in 0..<botBand {
            blend(from: lower, srcY: overlap + row, dstY: topBand + row, alpha: nil)
        }
        return RGBAImage(width: cropW, height: height, pixels: pixels)
    }

    /// Nil while any seam still needs a decision — a wrong stitch is never returned implicitly.
    public func flattenedIfResolved() -> RGBAImage? {
        guard !needsReview else { return nil }
        let chunks = exportChunks()
        guard chunks.count == 1 else { return nil }
        return chunks[0]
    }

    /// Resolved neighbors are merged. An unresolved boundary starts a new chunk.
    public func exportChunks() -> [RGBAImage] {
        guard !segments.isEmpty else { return [] }
        var chunks: [RGBAImage] = []
        var current: [RGBAImage] = [presented(at: 0).image]
        // Where segment `index` begins inside `current`. Rows a reverse shift lifts go in front of it.
        var segmentStart = 0
        for index in seams.indices where segments.indices.contains(index + 1) {
            let next = presented(at: index + 1).image
            let lifted = min(seams[index].appliedPrependRows, next.height)
            if lifted > 0 {
                current.insert(next.crop(rows: 0..<lifted), at: min(segmentStart, current.count))
            }
            switch seams[index].kind {
            case .needsAlignment:
                if let joined = RGBAImage.verticalJoin(current) { chunks.append(joined) }
                current = [next]
                segmentStart = 0
            case .joinedAsIs:
                segmentStart = current.count
                current.append(next)
            case .aligned(let overlap):
                segmentStart = current.count
                let start = min(max(0, overlap), next.height)
                let trimmed = next.crop(rows: start..<next.height)
                if trimmed.height > 0 { current.append(trimmed) }
            }
        }
        if let joined = RGBAImage.verticalJoin(current) { chunks.append(joined) }
        return chunks
    }

    /// Downscaled stack for the review window, plus one mark per seam (OK and unresolved).
    /// Resolved overlaps are applied; unresolved segments are stacked in full so nothing is hidden by a guess.
    public func renderPreview(maxLongSide: Int = 1200) -> (image: RGBAImage, marks: [SeamMark])? {
        let layout = layoutPieces()
        guard let width = layout.pieces.first?.image.width, width > 0 else { return nil }
        let fullHeight = layout.fullHeight
        guard fullHeight > 0 else { return nil }
        let factor = min(1, CGFloat(maxLongSide) / CGFloat(max(width, fullHeight)))
        let outW = max(1, Int((CGFloat(width) * factor).rounded()))
        let outH = max(1, Int((CGFloat(fullHeight) * factor).rounded()))
        var pixels = [UInt8](repeating: 255, count: outW * outH * 4)

        // `blockStarts[i]` is where piece i begins (its lead first); `origins[i]` is where its own rows begin.
        var blockStarts: [Int] = []
        var origins: [Int] = []
        var cursor = 0
        for piece in layout.pieces {
            blockStarts.append(cursor)
            origins.append(cursor + piece.leadHeight)
            cursor += piece.height
        }

        for row in 0..<outH {
            let sourceY = min(fullHeight - 1, Int((CGFloat(row) / factor).rounded(.down)))
            guard let pieceIndex = blockStarts.indices.last(where: {
                blockStarts[$0] <= sourceY && layout.pieces[$0].height > 0
            }) else { continue }
            let piece = layout.pieces[pieceIndex]
            let source: RGBAImage
            let local: Int
            if let lead = piece.lead, sourceY < origins[pieceIndex] {
                source = lead
                local = sourceY - blockStarts[pieceIndex]
            } else {
                source = piece.image
                local = piece.start + (sourceY - origins[pieceIndex])
            }
            guard local >= 0, local < source.height else { continue }
            source.withRow(local) { src in
                let dst = row * outW * 4
                guard src.count >= 4 else { return }
                for x in 0..<outW {
                    let sourceX = min(source.width - 1, Int((CGFloat(x) / factor).rounded(.down)))
                    let s = sourceX * 4
                    let d = dst + x * 4
                    guard s + 3 < src.count, d + 3 < pixels.count else { continue }
                    pixels[d] = src[s]
                    pixels[d + 1] = src[s + 1]
                    pixels[d + 2] = src[s + 2]
                    pixels[d + 3] = 255
                }
            }
        }

        var marks: [SeamMark] = []
        for (segmentIndex, _) in segments.enumerated() where segmentIndex < layout.pieces.count {
            let piece = layout.pieces[segmentIndex]
            let origin = origins[segmentIndex]
            let confidentYs = presented(at: segmentIndex).confidentSeamYs
            for (offset, seamY) in confidentYs.enumerated() where seamY >= piece.start {
                let y = origin + (seamY - piece.start)
                marks.append(SeamMark(id: "seg\(segmentIndex)-ok\(offset)", state: .ok, y: y, boundaryIndex: nil, suggestedOverlap: nil))
                paintLine(at: y, fullHeight: fullHeight, factor: factor, outW: outW, outH: outH, color: (126, 184, 168), into: &pixels)
            }
            if segmentIndex < seams.count {
                let seam = seams[segmentIndex]
                let y = origins[segmentIndex] + max(0, piece.image.height - piece.start)
                let card = seam.card(number: segmentIndex + 1)
                // The card decides the reason line. A handled tie or reverse seam has none,
                // so the row must not fall back to the old 「都说得通」 or reverse sentence.
                marks.append(SeamMark(
                    id: "boundary-\(segmentIndex)",
                    state: seam.state,
                    y: y,
                    boundaryIndex: segmentIndex,
                    suggestedOverlap: seam.suggestedOverlap,
                    note: card.reason
                ))
                if card.chrome == .amberDashed {
                    paintLine(
                        at: y,
                        fullHeight: fullHeight,
                        factor: factor,
                        outW: outW,
                        outH: outH,
                        color: PendingSeamStyle.warnRGB,
                        thickness: PendingSeamStyle.seamLineWidth,
                        dashed: true,
                        into: &pixels
                    )
                } else {
                    let color: (UInt8, UInt8, UInt8) = seam.isResolved ? (126, 184, 168) : (232, 160, 168)
                    paintLine(at: y, fullHeight: fullHeight, factor: factor, outW: outW, outH: outH, color: color, into: &pixels)
                }
            }
        }
        return (RGBAImage(width: outW, height: outH, pixels: pixels), marks)
    }

    private struct Piece {
        var image: RGBAImage
        var start: Int
        var lead: RGBAImage? = nil

        var leadHeight: Int { lead?.height ?? 0 }
        /// Rows this piece takes in the stack, lead included.
        var height: Int { leadHeight + max(0, image.height - start) }
    }

    /// Dedupe-off view of a segment: repeated sticky bars spliced back at each confident seam.
    /// The cache holds that uncropped image once. 「只保留一次」 is a view over it, applied on every call.
    private func presented(at index: Int) -> (image: RGBAImage, confidentSeamYs: [Int]) {
        guard segments.indices.contains(index) else {
            return (RGBAImage(width: 0, height: 0, pixels: []), [])
        }
        let segment = segments[index]
        let key = PresentationCache.Key(
            dedupe: dedupeStickyBars,
            index: index,
            width: segment.image.width,
            height: segment.image.height,
            pixelCount: segment.image.byteCount,
            seamYs: segment.confidentSeamYs,
            repeats: segment.stickyRepeats.map {
                PresentationCache.RepeatKey(seamY: $0.seamY, headerHeight: $0.header.height, footerHeight: $0.footer.height)
            }
        )
        let base: (image: RGBAImage, confidentSeamYs: [Int])
        if let cached = presentationCache.values[key] {
            presentationCache.hits += 1
            base = cached
        } else {
            base = Self.makePresented(segment, dedupe: dedupeStickyBars)
            presentationCache.values[key] = base
        }
        return applyingKeepOnce(base, cuts: keepOnceCuts(segmentIndex: index, dedupe: dedupeStickyBars))
    }

    private static func makePresented(_ segment: ScrollSegment, dedupe: Bool) -> (image: RGBAImage, confidentSeamYs: [Int]) {
        let repeats = segment.stickyRepeats.filter { $0.header.height > 0 || $0.footer.height > 0 }
        guard !dedupe, !repeats.isEmpty else {
            return (segment.image, segment.confidentSeamYs)
        }
        guard let image = RGBAImage.verticalJoin(contentSlices(segment, dedupe: false)) else {
            return (segment.image, segment.confidentSeamYs)
        }
        let ordered = repeats.sorted { $0.seamY < $1.seamY }
        let ys = segment.confidentSeamYs.map { y in
            let extra = ordered.reduce(0) { partial, rep in
                y >= rep.seamY ? partial + rep.header.height + rep.footer.height : partial
            }
            return y + extra
        }
        return (image, ys)
    }

    private func presentedHeight(_ segment: ScrollSegment, dedupe: Bool, index: Int) -> Int {
        let base: Int
        if dedupe {
            base = segment.image.height
        } else {
            let extra = segment.stickyRepeats.reduce(0) { $0 + $1.header.height + $1.footer.height }
            base = segment.image.height + extra
        }
        return max(0, base - keepOnceRowCount(segment: index))
    }

    private func keepOnceRowCount(segment index: Int) -> Int {
        duplicateCandidates.reduce(0) { sum, candidate in
            guard candidate.segmentIndex == index, candidate.choice == .keepOnce else { return sum }
            return sum + max(0, candidate.rowCount)
        }
    }

    private func logicalPresentedRow(_ row: Int, segmentIndex: Int) -> Int {
        // Keep-once cuts are stored in expanded coordinates when the sticky bars are spliced back in.
        var y = row
        if !dedupeStickyBars, segments.indices.contains(segmentIndex) {
            y = Self.expandedY(row, repeats: segments[segmentIndex].stickyRepeats)
        }
        var removed = 0
        for cut in keepOnceCuts(segmentIndex: segmentIndex, dedupe: dedupeStickyBars) {
            let end = cut.start + cut.rows
            if end <= y {
                removed += cut.rows
            } else if cut.start < y {
                removed += y - cut.start
            }
        }
        return max(0, y - removed)
    }

    private func keepOnceCuts(segmentIndex: Int, dedupe: Bool) -> [(start: Int, rows: Int)] {
        guard segments.indices.contains(segmentIndex) else { return [] }
        let repeats = segments[segmentIndex].stickyRepeats
        return duplicateCandidates.compactMap { candidate in
            guard candidate.segmentIndex == segmentIndex, candidate.choice == .keepOnce, candidate.rowCount > 0 else { return nil }
            let start = dedupe
                ? candidate.startRow
                : Self.expandedY(candidate.startRow, repeats: repeats)
            return (start, candidate.rowCount)
        }.sorted { $0.start < $1.start }
    }

    private func applyingKeepOnce(
        _ presented: (image: RGBAImage, confidentSeamYs: [Int]),
        segmentIndex: Int,
        dedupe: Bool
    ) -> (image: RGBAImage, confidentSeamYs: [Int]) {
        applyingKeepOnce(presented, cuts: keepOnceCuts(segmentIndex: segmentIndex, dedupe: dedupe))
    }

    /// 「只保留一次」 hides the repeated rows. The tiles underneath are not copied.
    /// Pending and 「都保留」 leave them in the image.
    private func applyingKeepOnce(
        _ presented: (image: RGBAImage, confidentSeamYs: [Int]),
        cuts: [(start: Int, rows: Int)]
    ) -> (image: RGBAImage, confidentSeamYs: [Int]) {
        let ranges = cuts.compactMap { cut -> Range<Int>? in
            let start = min(max(0, cut.start), presented.image.height)
            let end = min(presented.image.height, start + cut.rows)
            guard end > start else { return nil }
            return start..<end
        }
        guard !ranges.isEmpty else { return presented }
        let image = presented.image.omitting(rows: ranges)
        let seamYs = presented.confidentSeamYs.compactMap { y -> Int? in
            var removedBefore = 0
            for range in ranges {
                if y >= range.upperBound {
                    removedBefore += range.count
                } else if y > range.lowerBound {
                    return nil
                }
            }
            return y - removedBefore
        }
        return (image, seamYs)
    }

    private static func expandedY(_ y: Int, repeats: [StickyRepeat]) -> Int {
        let extra = repeats.reduce(0) { partial, rep in
            y >= rep.seamY ? partial + rep.header.height + rep.footer.height : partial
        }
        return y + extra
    }

    private static func contentSlices(_ segment: ScrollSegment, dedupe: Bool) -> [RGBAImage] {
        let repeats = segment.stickyRepeats.filter { $0.header.height > 0 || $0.footer.height > 0 }
        guard !dedupe, !repeats.isEmpty else { return [segment.image] }
        var slices: [RGBAImage] = []
        var cursor = 0
        let image = segment.image
        for rep in repeats.sorted(by: { $0.seamY < $1.seamY }) {
            let y = min(max(cursor, rep.seamY), image.height)
            if y > cursor { slices.append(image.crop(rows: cursor..<y)) }
            if rep.footer.height > 0 { slices.append(rep.footer) }
            if rep.header.height > 0 { slices.append(rep.header) }
            cursor = y
        }
        if cursor < image.height { slices.append(image.crop(rows: cursor..<image.height)) }
        return slices.filter { $0.height > 0 }
    }

    private static func droppingRows(_ count: Int, from slices: [RGBAImage]) -> [RGBAImage] {
        var remaining = max(0, count)
        var output: [RGBAImage] = []
        for slice in slices {
            if remaining <= 0 {
                output.append(slice)
                continue
            }
            if slice.height <= remaining {
                remaining -= slice.height
                continue
            }
            output.append(slice.crop(rows: remaining..<slice.height))
            remaining = 0
        }
        return output
    }

    private static func pack(_ slices: [RGBAImage], maxHeight: Int, maxPixels: Int) -> [RGBAImage] {
        let width = slices.first?.width ?? 0
        var chunks: [RGBAImage] = []
        var current: [RGBAImage] = []
        var height = 0

        func flush() {
            if let joined = RGBAImage.verticalJoin(current) { chunks.append(joined) }
            current = []
            height = 0
        }

        for slice in slices where slice.height > 0 {
            var rest = slice
            while rest.height > 0 {
                let room = ScrollOutputLimit.remainingRows(
                    totalHeight: height,
                    width: width,
                    maxHeight: maxHeight,
                    maxPixels: maxPixels
                )
                if room <= 0 {
                    if height == 0 { break }
                    flush()
                    continue
                }
                if rest.height <= room {
                    current.append(rest)
                    height += rest.height
                    break
                }
                current.append(rest.crop(rows: 0..<room))
                height += room
                rest = rest.crop(rows: room..<rest.height)
                flush()
            }
        }
        flush()
        return chunks
    }

    /// One piece per segment, in order, so `pieces[i]` is segment `i`. A segment hidden by its overlap
    /// stays as an empty piece. `lead` holds rows a reverse shift put above that segment.
    private func layoutPieces() -> (pieces: [Piece], fullHeight: Int) {
        guard !segments.isEmpty else { return ([], 0) }
        var pieces = [Piece(image: presented(at: 0).image, start: 0)]
        for index in seams.indices where segments.indices.contains(index + 1) {
            let next = presented(at: index + 1).image
            let start: Int
            switch seams[index].kind {
            case .needsAlignment, .joinedAsIs:
                start = 0
            case .aligned(let overlap):
                start = min(max(0, overlap), next.height)
            }
            let lifted = min(seams[index].appliedPrependRows, next.height)
            if lifted > 0 {
                pieces[index].lead = next.crop(rows: 0..<lifted)
            }
            pieces.append(Piece(image: next, start: start))
        }
        let fullHeight = pieces.reduce(0) { $0 + $1.height }
        return (pieces, fullHeight)
    }

    private func paintLine(
        at fullY: Int,
        fullHeight: Int,
        factor: CGFloat,
        outW: Int,
        outH: Int,
        color: (UInt8, UInt8, UInt8),
        thickness: Int = 1,
        dashed: Bool = false,
        into pixels: inout [UInt8]
    ) {
        guard fullHeight > 0 else { return }
        let row = min(outH - 1, max(0, Int((CGFloat(fullY) * factor).rounded(.down))))
        let span = max(1, thickness)
        let first = row - span / 2
        for offset in 0..<span {
            let target = first + offset
            guard target >= 0, target < outH else { continue }
            for x in 0..<outW {
                // 3 px on, 2 px off. The old seam used 4 px on / 4 px off.
                if dashed, x % 5 >= 3 { continue }
                let d = (target * outW + x) * 4
                pixels[d] = color.0
                pixels[d + 1] = color.1
                pixels[d + 2] = color.2
                pixels[d + 3] = 255
            }
        }
    }
}

/// Stitches viewport frames into one tall image, splitting where the overlap is not confident.
///
/// Consecutive frames are aligned by a vertical shift (positive = user scrolled down, new pixels
/// at the bottom). Rows that stay put at the top or bottom of the viewport while the middle moves
/// are a sticky header / footer: they are kept once inside a confident run, not repeated on every
/// slice. That dedupe is on by default and does not ask for confirmation. A sticky band whose edge
/// is soft, or that was extended across gaps, is locked and kept as one pending choice for the
/// whole run, instead of splitting a new seam on every frame. Identical frames add nothing. A frame that cannot be aligned is NOT
/// force-joined; it starts a new segment and the seam is marked as needing alignment.
public struct ScrollStitcher {
    public struct Options: Equatable {
        public var sampleCount = 24
        /// Rows whose sampled channels span less than this are blank and cannot anchor a match.
        public var distinctSpan = 18
        /// Mean per-channel distance (0...255) that still counts as "the same row".
        public var matchDistance = 12
        /// A frame whose distinctive rows mostly stay under this distance did not scroll.
        public var unchangedDistance = 6
        /// Mean distance accepted when checking a candidate shift across the overlap.
        public var alignDistance = 18
        public var minOverlapRows = 8
        /// Sticky bands cannot claim more than this fraction of the viewport.
        public var maxBandFraction = 0.45
        public var maxHeight = ScrollOutputLimit.maxHeight
        public var maxPixels = ScrollOutputLimit.maxPixels

        public init() {}
    }

    public private(set) var options: Options
    public private(set) var acceptedFrames = 0
    public private(set) var unmatchedBreaks = 0
    private var segments: [ScrollSegment] = []
    private var seams: [ScrollSeam] = []
    /// Header + content + latest footer, stored as row tiles. New strips are inserted; the rows
    /// already accepted stay in their tiles instead of being copied into a second full image.
    private var canvas = RGBAImage(width: 0, height: 0, pixels: [])
    private var canvasHeader = 0
    private var canvasFooter = 0
    /// True until the first successful join, so a sticky split only re-labels the seed rows.
    private var canvasIsSeed = false
    /// Canvas row where the last incorporated frame starts. A seam records it so a reverse
    /// tie candidate can be placed against that frame instead of the bottom of the segment.
    private var previousTop = 0
    private var open = false
    private var confidentYs: [Int] = []
    private var previous: RGBAImage?
    private var lockedHeader: Int?
    private var lockedFooter: Int?
    private var pendingSticky: PendingStickyConfirmation?
    private var stickyRepeats: [StickyRepeat] = []
    /// Last confident vertical shift. Breaks a later alias (period-like cards) in the same direction.
    /// Cleared when a segment closes, when the assembly is finalized, and in `beginStitch()`.
    private var lastShift: Int?
    /// One shared copy of the sticky bars for the open run. Each seam records these images
    /// instead of cropping a fresh header and footer on every frame.
    private var pinnedHeader: RGBAImage?
    private var pinnedFooter: RGBAImage?
    /// Uncertain repeated runs found on confident joins. A new stitch pass starts empty.
    private var duplicateCandidates: [DuplicateSegmentCandidate] = []

    public init(options: Options = Options()) {
        self.options = options
    }

    /// 「开始拼接」. Drops the shift remembered for repeating-card aliases so the next
    /// pass cannot inherit a direction from the previous one, and clears candidates found
    /// so far so the next frames are identified again.
    public mutating func beginStitch() {
        lastShift = nil
        duplicateCandidates = []
    }

    public var hasFrame: Bool { open || !segments.isEmpty }

    public var segmentCount: Int { segments.count + (open ? 1 : 0) }

    public var pixelHeight: Int { sealedHeight + openHeight }

    private var sealedHeight: Int { segments.reduce(0) { $0 + $1.image.height } }

    private var openHeight: Int { open ? canvas.height : 0 }

    public mutating func ingest(_ frame: RGBAImage) -> ScrollIngest {
        guard frame.width >= 8, frame.height > options.minOverlapRows,
              frame.byteCount >= frame.width * frame.height * 4, frame.pixelsOk else { return .ignored }
        acceptedFrames += 1
        guard let prev = previous else {
            previous = frame
            canvas = frame
            canvasHeader = 0
            canvasFooter = 0
            canvasIsSeed = true
            previousTop = 0
            open = true
            return .seeded
        }
        guard prev.width == frame.width, prev.height == frame.height else {
            acceptedFrames -= 1
            return .ignored
        }

        let prevRows = RowSamples.make(prev, options: options)
        let nextRows = RowSamples.make(frame, options: options)
        if RowSamples.isUnchanged(prevRows, nextRows, options: options) {
            // Keep the last incorporated frame. Replacing it would drop the 1–2 px this frame revealed.
            return .unchanged
        }

        let headerH: Int
        let footerH: Int
        if let lockedHeader, let lockedFooter {
            headerH = lockedHeader
            footerH = lockedFooter
        } else {
            let detectedHeader = RowSamples.stickyPrefix(prevRows, nextRows, options: options)
            let detectedFooter = RowSamples.stickySuffix(prevRows, nextRows, options: options)
            let headerUncertain = detectedHeader.rows > 0 && !detectedHeader.confident
            let footerUncertain = detectedFooter.rows > 0 && !detectedFooter.confident
            if headerUncertain || footerUncertain {
                // Lock the band and keep stitching. Later frames share this one confirmation
                // instead of opening a new seam every viewport.
                lockedHeader = detectedHeader.rows
                lockedFooter = detectedFooter.rows
                if pendingSticky == nil {
                    pendingSticky = PendingStickyConfirmation(
                        headerRows: detectedHeader.rows,
                        footerRows: detectedFooter.rows,
                        seamCount: 0,
                        keepOnce: nil
                    )
                }
                headerH = detectedHeader.rows
                footerH = detectedFooter.rows
            } else {
                let contentSpan = frame.height - detectedHeader.rows - detectedFooter.rows
                let bandsOK = (detectedHeader.rows > 0 || detectedFooter.rows > 0)
                    && contentSpan >= options.minOverlapRows * 2
                    && detectedHeader.rows + detectedFooter.rows <= Int(Double(frame.height) * options.maxBandFraction)
                headerH = bandsOK ? detectedHeader.rows : 0
                footerH = bandsOK ? detectedFooter.rows : 0
            }
        }

        // A fixed bar taller than the sticky cap, or a blank margin, must not hide the rows that moved.
        let match = RowSamples.matchEdges(
            prevRows,
            nextRows,
            fallbackHeader: headerH,
            fallbackFooter: footerH,
            options: options
        )
        let found = RowSamples.bestShift(
            prevRows,
            nextRows,
            header: match.header,
            footer: match.footer,
            lastShift: lastShift,
            options: options
        )
        if let matchFound = found, matchFound.confident {
            let duplicate = RowSamples.uncertainDuplicate(
                prev: prevRows,
                next: nextRows,
                shift: matchFound.shift,
                header: match.header,
                footer: match.footer
            )
            let outcome = apply(
                next: frame,
                shift: matchFound.shift,
                headerH: match.header,
                footerH: match.footer,
                duplicate: duplicate
            )
            switch outcome {
            case .appended, .prepended, .reachedLimit:
                if lockedHeader == nil {
                    lockedHeader = headerH
                    lockedFooter = footerH
                }
                if pendingSticky != nil, headerH > 0 || footerH > 0 {
                    pendingSticky?.seamCount += 1
                }
                lastShift = matchFound.shift
                previous = frame
            case .unchanged:
                break
            case .unmatched:
                return breakUnmatched(frame, suggested: max(0, frame.height - abs(matchFound.shift)))
            case .seeded, .ignored:
                break
            }
            return outcome
        }
        // Hover, caret, or a one-frame flash: most of the picture is still the last frame.
        if found == nil, RowSamples.isFlicker(prevRows, nextRows, options: options) {
            return .ignored
        }
        let suggested = found.map { max(0, frame.height - abs($0.shift)) }
        let reverseNote = found?.reversed == true ? StitchCopy.reverseSeam : nil
        return breakUnmatched(
            frame,
            suggested: suggested,
            note: reverseNote,
            tieShifts: found?.tieShifts,
            selectedShift: found?.shift,
            reversed: found?.reversed == true
        )
    }

    /// Seals the open segment and returns every piece. Call once, when capture ends.
    public mutating func takeAssembly() -> ScrollAssembly {
        sealOpenSegment()
        return ScrollAssembly(
            segments: segments,
            seams: seams,
            pendingSticky: pendingSticky,
            duplicateCandidates: duplicateCandidates
        )
    }

    public func cgImage() -> CGImage? {
        var copy = self
        return copy.takeAssembly().flattenedIfResolved()?.cgImage()
    }

    // MARK: - Apply

    private mutating func apply(
        next: RGBAImage,
        shift: Int,
        headerH: Int,
        footerH: Int,
        duplicate: RowSamples.UncertainDuplicate? = nil
    ) -> ScrollIngest {
        let strip: RGBAImage
        let prepend: Bool
        if shift > 0 {
            let end = next.height - footerH
            let start = end - shift
            guard start >= headerH else { return .unmatched }
            strip = next.crop(rows: start..<end)
            prepend = false
        } else {
            let count = -shift
            let start = headerH
            let end = start + count
            guard end <= next.height - footerH else { return .unmatched }
            strip = next.crop(rows: start..<end)
            prepend = true
        }
        guard strip.height > 0 else { return .unchanged }

        let room = ScrollOutputLimit.remainingRows(
            totalHeight: pixelHeight,
            width: next.width,
            maxHeight: options.maxHeight,
            maxPixels: options.maxPixels
        )
        if room <= 0 { return .reachedLimit }

        // Split only once the new strip is known to fit, so a rejected frame cannot slice the seed.
        splitSeedIfNeeded(headerH: headerH, footerH: footerH)
        if canvasHeader > 0, pinnedHeader == nil {
            pinnedHeader = canvas.crop(rows: 0..<canvasHeader)
        }
        if canvasFooter > 0, pinnedFooter == nil {
            pinnedFooter = canvas.crop(rows: (canvas.height - canvasFooter)..<canvas.height)
        }
        let emptyBar = RGBAImage(width: next.width, height: 0, pixels: [])
        let repeatHeader = canvasHeader > 0 ? (pinnedHeader ?? emptyBar) : emptyBar
        let repeatFooter = canvasFooter > 0 ? (pinnedFooter ?? emptyBar) : emptyBar

        let fitted: RGBAImage
        let clipped: Bool
        if strip.height <= room {
            fitted = strip
            clipped = false
        } else if prepend {
            fitted = strip.crop(rows: (strip.height - room)..<strip.height)
            clipped = true
        } else {
            fitted = strip.crop(rows: 0..<room)
            clipped = true
        }
        let seamY = canvasHeader + (canvas.height - canvasHeader - canvasFooter)
        let joinY: Int
        if prepend {
            let added = fitted.height
            confidentYs = confidentYs.map { $0 + added }
            stickyRepeats = stickyRepeats.map {
                StickyRepeat(seamY: $0.seamY + added, header: $0.header, footer: $0.footer)
            }
            for index in duplicateCandidates.indices where duplicateCandidates[index].segmentIndex == segments.count {
                duplicateCandidates[index].startRow += added
            }
            joinY = canvasHeader + added
            confidentYs.append(joinY)
            canvas.insertRows(fitted, at: canvasHeader)
        } else {
            joinY = seamY
            confidentYs.append(seamY)
            canvas.insertRows(fitted, at: canvas.height - canvasFooter)
        }
        if footerH > 0 {
            let newFooter = next.crop(rows: (next.height - footerH)..<next.height)
            if canvasFooter == newFooter.height, canvasFooter > 0 {
                canvas.overwriteRows((canvas.height - canvasFooter)..<canvas.height, with: newFooter)
            } else {
                if canvasFooter > 0 {
                    canvas.removeLastRows(canvasFooter)
                }
                canvas.insertRows(newFooter, at: canvas.height)
                canvasFooter = newFooter.height
                pinnedFooter = newFooter
            }
        }
        canvasIsSeed = false
        // An upward join lines the frame up with the top of the canvas, a downward one with the bottom.
        previousTop = prepend ? 0 : max(0, canvas.height - next.height)
        if repeatHeader.height > 0 || repeatFooter.height > 0 {
            stickyRepeats.append(StickyRepeat(seamY: joinY, header: repeatHeader, footer: repeatFooter))
        }
        if !clipped, let duplicate {
            recordUncertainDuplicate(duplicate, joinY: joinY)
        }
        if clipped { return .reachedLimit }
        return prepend ? .prepended(fitted.height) : .appended(fitted.height)
    }

    /// Records one short repeated run under the seam just written. Only uncertain runs reach here.
    private mutating func recordUncertainDuplicate(_ duplicate: RowSamples.UncertainDuplicate, joinY: Int) {
        // Live detection and re-detection both store the seam itself: the repeated rows just below it.
        // An upward join used to store the copy above the seam, so the first 「完成」 never matched.
        let startRow = joinY
        // Same order the preview lists marks: confident seams, then each unaligned boundary before them.
        let sealedSeams = segments.reduce(0) { $0 + $1.confidentSeamYs.count }
        let seamNumber = sealedSeams + seams.count + confidentYs.count
        let segmentIndex = segments.count
        let id = "dup-\(segmentIndex)-\(seamNumber)-\(startRow)"
        guard !duplicateCandidates.contains(where: { $0.id == id }) else { return }
        duplicateCandidates.append(DuplicateSegmentCandidate(
            id: id,
            seamNumber: seamNumber,
            rowCount: duplicate.rowCount,
            segmentIndex: segmentIndex,
            startRow: startRow,
            offset: seams.last?.editorOverlap ?? 0
        ))
    }

    private mutating func breakUnmatched(
        _ frame: RGBAImage,
        suggested: Int?,
        note: String? = nil,
        tieShifts: [Int]? = nil,
        selectedShift: Int? = nil,
        reversed: Bool = false
    ) -> ScrollIngest {
        let room = ScrollOutputLimit.remainingRows(
            totalHeight: pixelHeight,
            width: frame.width,
            maxHeight: options.maxHeight,
            maxPixels: options.maxPixels
        )
        // Don't start another full viewport that would blow the cap, and don't clip it into a fake join.
        if pixelHeight > 0, room < frame.height { return .reachedLimit }
        let upperFrameTop: Int? = open ? previousTop : nil
        sealOpenSegment()
        var seamNote = note ?? RowSamples.blankSeamNote(RowSamples.make(frame, options: options))
        var pendingTitle: String?
        var candidateLines: [String] = []
        var candidateShifts: [Int] = []
        if let tieShifts, tieShifts.count >= 2 {
            let number = seams.count + 1
            pendingTitle = "接缝 \(number) · 待确认：位移无法唯一确定"
            var reason = "找到 \(tieShifts.count) 个都说得通的位移，自动对齐没法确定是哪一个——为了不拼错，先停下来请你确认。"
            if Self.repeatsListRows(frame, height: 22) {
                reason = "这一段是重复的列表行（行高 22 px）。" + reason
            }
            seamNote = reason
            let selected = selectedShift ?? tieShifts[0]
            candidateShifts = tieShifts.sorted(by: >)
            candidateLines = candidateShifts.enumerated().map { index, shift in
                Self.shiftCandidateLine(index: index, shift: shift, selected: selected)
            }
        }
        seams.append(ScrollSeam(
            kind: .needsAlignment,
            suggestedOverlap: suggested,
            note: seamNote,
            pendingTitle: pendingTitle,
            candidateLines: candidateLines,
            reversed: reversed && pendingTitle == nil,
            candidateShifts: candidateShifts,
            selectedShift: selectedShift,
            upperFrameTop: upperFrameTop
        ))
        let savedHeader = lockedHeader
        let savedFooter = lockedFooter
        let savedPending = pendingSticky
        previous = frame
        canvas = frame
        canvasHeader = 0
        canvasFooter = 0
        canvasIsSeed = true
        previousTop = 0
        open = true
        confidentYs = []
        stickyRepeats = []
        pinnedHeader = nil
        pinnedFooter = nil
        // An uncertain sticky run stays one confirmation. Clearing the lock here made every
        // following frame look uncertain again and open another seam.
        if savedPending != nil {
            lockedHeader = savedHeader
            lockedFooter = savedFooter
            pendingSticky = savedPending
        }
        unmatchedBreaks += 1
        return .unmatched
    }

    /// 「位移 A · +30 px · 当前」. A negative shift uses U+2212, not a hyphen.
    private static func shiftCandidateLine(index: Int, shift: Int, selected: Int) -> String {
        let letter = index < 26 ? String(UnicodeScalar(65 + index)!) : "?"
        let sign = shift < 0 ? "−" : "+"
        var line = "位移 \(letter) · \(sign)\(abs(shift)) px"
        if shift == selected {
            line += " · 当前"
        }
        return line
    }

    /// True when most rows repeat the row `period` px below. Alias periods of 60 do not.
    private static func repeatsListRows(_ frame: RGBAImage, height period: Int) -> Bool {
        guard period > 0, frame.width > 0, frame.height >= period * 3 else { return false }
        let pixels = frame.pixels
        let rowBytes = frame.width * 4
        guard pixels.count >= frame.height * rowBytes else { return false }
        var matches = 0
        let compared = frame.height - period
        for y in 0..<compared {
            let top = y * rowBytes
            let below = (y + period) * rowBytes
            if pixels[top..<(top + rowBytes)] == pixels[below..<(below + rowBytes)] {
                matches += 1
            }
        }
        return matches * 2 >= compared
    }

    private mutating func sealOpenSegment() {
        // The next segment, and the next capture after finalize, start without a direction.
        lastShift = nil
        guard open, canvas.height > 0 else {
            stickyRepeats = []
            return
        }
        segments.append(ScrollSegment(image: canvas, confidentSeamYs: confidentYs, stickyRepeats: stickyRepeats))
        canvas = RGBAImage(width: 0, height: 0, pixels: [])
        canvasHeader = 0
        canvasFooter = 0
        canvasIsSeed = false
        open = false
        previous = nil
        lockedHeader = nil
        lockedFooter = nil
        confidentYs = []
        stickyRepeats = []
        pinnedHeader = nil
        pinnedFooter = nil
    }

    private mutating func splitSeedIfNeeded(headerH: Int, footerH: Int) {
        guard canvasIsSeed, canvasHeader == 0, canvasFooter == 0, headerH > 0 || footerH > 0 else { return }
        guard canvas.height > headerH + footerH else { return }
        canvasHeader = headerH
        canvasFooter = footerH
    }
}

private extension RGBAImage {
    /// False when the stored rows don't cover the declared rectangle.
    var pixelsOk: Bool { height == 0 || byteCount > 0 }
}

// MARK: - Row matching

private struct RowSample {
    var bytes: [UInt8]
    var distinctive: Bool
}

private enum RowSamples {
    private enum Bias { case top, bottom }

    static func make(_ image: RGBAImage, options: ScrollStitcher.Options) -> [RowSample] {
        let xs = sampleColumns(width: image.width, count: options.sampleCount)
        var rows: [RowSample] = []
        rows.reserveCapacity(image.height)
        for y in 0..<image.height {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(xs.count * 3)
            var minC = 255
            var maxC = 0
            image.withRow(y) { row in
                for x in xs {
                    let i = x * 4
                    guard i + 2 < row.count else { continue }
                    let r = row[i]
                    let g = row[i + 1]
                    let b = row[i + 2]
                    bytes.append(r)
                    bytes.append(g)
                    bytes.append(b)
                    minC = min(minC, Int(r), Int(g), Int(b))
                    maxC = max(maxC, Int(r), Int(g), Int(b))
                }
            }
            rows.append(RowSample(bytes: bytes, distinctive: maxC - minC >= options.distinctSpan))
        }
        return rows
    }

    static func isUnchanged(_ a: [RowSample], _ b: [RowSample], options: ScrollStitcher.Options) -> Bool {
        let count = min(a.count, b.count)
        var compared = 0
        var drift = 0
        for y in 0..<count where a[y].distinctive || b[y].distinctive {
            compared += 1
            if distance(a[y], b[y]) > options.unchangedDistance { drift += 1 }
        }
        if compared < 8 {
            return averageDistance(a, b) <= options.unchangedDistance
        }
        return drift * 5 < compared
    }

    struct StickyBand: Equatable {
        var rows: Int
        /// False when a band is plausible but its end is soft or was extended across gaps.
        var confident: Bool
    }

    /// Leading rows that stayed put while something below them moved. Blank rows do not start a band.
    static func stickyPrefix(_ a: [RowSample], _ b: [RowSample], options: ScrollStitcher.Options) -> StickyBand {
        stickyRun(a, b, options: options, fromTop: true)
    }

    static func stickySuffix(_ a: [RowSample], _ b: [RowSample], options: ScrollStitcher.Options) -> StickyBand {
        stickyRun(a, b, options: options, fromTop: false)
    }

    struct ShiftChoice {
        var shift: Int
        var confident: Bool
        /// True only when the single candidate reverses the last accepted direction.
        var reversed: Bool = false
        /// Equal-score shifts when the join cannot pick one. Nil for a lone reverse.
        var tieShifts: [Int]? = nil
    }

    /// Leading rows of the new strip that repeat the rows sitting directly across the seam.
    /// A match anywhere else in the previous frame — shared icons, an earlier list row — is not a candidate.
    struct UncertainDuplicate {
        var offsetInStrip: Int
        var rowCount: Int
    }

    static func uncertainDuplicate(prev: [RowSample], next: [RowSample], shift: Int, header: Int, footer: Int) -> UncertainDuplicate? {
        let height = min(prev.count, next.count)
        guard shift != 0, header >= 0, footer >= 0, header + footer < height else { return nil }
        let newStart: Int
        let newEnd: Int
        let prevStart: Int
        if shift > 0 {
            let contentEnd = height - footer
            newEnd = contentEnd
            newStart = contentEnd - shift
            // Trailing rows of the previous frame, directly above the seam.
            prevStart = contentEnd
        } else {
            newStart = header
            newEnd = header + (-shift)
            // Previous-frame rows directly below the seam (the side the new strip joins).
            prevStart = header
        }
        guard newStart >= 0, newEnd <= height, newEnd - newStart >= 2 else { return nil }
        let contentEnd = height - footer
        guard header < contentEnd else { return nil }

        let available = min(newEnd - newStart, contentEnd - header)
        guard let rowCount = matchingBlock(available: available, equals: { k in
            for i in 0..<k {
                let nextY = shift > 0 ? newStart + i : newEnd - k + i
                let prevY = shift > 0 ? prevStart - k + i : prevStart + i
                guard nextY >= 0, prevY >= header, nextY < height, prevY < contentEnd else { return false }
                if !sameDistinctiveRow(next[nextY], prev[prevY]) { return false }
            }
            return true
        }) else { return nil }
        let blockStart = shift > 0 ? newStart : newEnd - rowCount
        if repeatsInsideItself({ next[blockStart + $0] }, k: rowCount) { return nil }
        let offsetInStrip = shift > 0 ? 0 : (newEnd - newStart - rowCount)
        return UncertainDuplicate(offsetInStrip: offsetInStrip, rowCount: rowCount)
    }

    /// The rows just below `seamY` repeat the rows just above it, in the same order.
    /// Runs longer than 8 stay in the image.
    static func seamAdjacentDuplicate(_ rows: [RowSample], seamY: Int) -> Int? {
        guard seamY > 0, seamY < rows.count else { return nil }
        let available = min(seamY, rows.count - seamY)
        guard let rowCount = matchingBlock(available: available, equals: { k in
            for i in 0..<k {
                if !sameDistinctiveRow(rows[seamY - k + i], rows[seamY + i]) { return false }
            }
            return true
        }) else { return nil }
        if repeatsInsideItself({ rows[seamY + $0] }, k: rowCount) { return nil }
        return rowCount
    }

    /// Longest same-order block of 2...8 rows. Nine or more identical rows is not a short candidate.
    private static func matchingBlock(available: Int, equals: (Int) -> Bool) -> Int? {
        guard available >= 2 else { return nil }
        if available >= 9, equals(9) { return nil }
        for k in stride(from: min(available, 8), through: 2, by: -1) where equals(k) {
            return k
        }
        return nil
    }

    /// The longest match is one run the seam cut through, not a second copy.
    /// `block[k-1] == block[0]` means the content continues across the seam.
    /// A tiling period shorter than k (ABABABAB at k=8) is the same rejection.
    /// Callers do not try a shorter k after this returns true.
    private static func repeatsInsideItself(_ row: (Int) -> RowSample, k: Int) -> Bool {
        guard k >= 2 else { return false }
        if row(k - 1).bytes == row(0).bytes { return true }
        for p in 1..<k where k % p == 0 {
            var tiled = true
            for i in p..<k where row(i).bytes != row(i % p).bytes {
                tiled = false
                break
            }
            if tiled { return true }
        }
        return false
    }

    private static func sameDistinctiveRow(_ a: RowSample, _ b: RowSample) -> Bool {
        a.distinctive && b.distinctive && a.bytes == b.bytes
    }

    static func bestShift(
        _ prev: [RowSample],
        _ next: [RowSample],
        header: Int,
        footer: Int,
        lastShift: Int? = nil,
        options: ScrollStitcher.Options
    ) -> ShiftChoice? {
        let height = min(prev.count, next.count)
        let contentEnd = height - footer
        guard header >= 0, footer >= 0, contentEnd - header > options.minOverlapRows else { return nil }

        var scored: [Int: (score: Int, votes: Int)] = [:]

        func consider(_ shift: Int) {
            guard shift != 0 else { return }
            guard let score = verify(prev, next, header: header, footer: footer, shift: shift, options: options) else { return }
            guard score <= options.alignDistance else { return }
            if let existing = scored[shift] {
                scored[shift] = (min(existing.score, score), existing.votes + 1)
            } else {
                scored[shift] = (score, 1)
            }
        }

        for anchor in anchorRows(next, from: header, to: contentEnd, bias: .top) {
            if let y = closest(to: next[anchor], in: prev, from: anchor + 1, to: contentEnd, options: options) {
                consider(y - anchor)
            }
        }
        for anchor in anchorRows(next, from: header, to: contentEnd, bias: .bottom) {
            if let y = closest(to: next[anchor], in: prev, from: header, to: anchor, options: options) {
                consider(y - anchor)
            }
        }

        let ranked = clustered(scored)
        guard let best = ranked.first else { return nil }
        // Distant aliases with similar score *and* similar support are not safe — a repeating
        // list can match at several periods. Nearby 1–2 px candidates are the same scroll.
        let rivals = ranked.dropFirst().filter { rival in
            abs(rival.shift - best.shift) > AliasRival.shiftGap
                && rival.score <= best.score + AliasRival.scoreSlack
                && rival.votes * AliasRival.voteFactor >= best.votes
        }
        // One candidate used to be trusted even when it reversed the last shift.
        // Only that lone opposite candidate, with no rival inside the threshold, uses the reverse line.
        let loneReverse = rivals.isEmpty && (lastShift.map { prior in
            prior != 0 && best.shift.signum() != prior.signum()
        } ?? false)
        if rivals.isEmpty {
            if loneReverse {
                return ShiftChoice(shift: best.shift, confident: false, reversed: true)
            }
            return ShiftChoice(shift: best.shift, confident: true)
        }
        if let prior = lastShift,
           let preferred = resolveAlias(best: best, rivals: Array(rivals), prior: prior) {
            return ShiftChoice(shift: preferred, confident: true)
        }
        // resolveAlias did not pick one. Every rival inside the threshold is a tie,
        // whatever its direction and whether or not the scores are exactly equal.
        let tieShifts = [best.shift] + rivals.map(\.shift)
        return ShiftChoice(shift: best.shift, confident: false, reversed: false, tieShifts: tieShifts)
    }

    /// Header and footer used to score a shift. A stationary edge that is too tall for the
    /// sticky cap still has to be left out of the search, or the moving strip never gets a vote.
    static func matchEdges(
        _ a: [RowSample],
        _ b: [RowSample],
        fallbackHeader: Int,
        fallbackFooter: Int,
        options: ScrollStitcher.Options
    ) -> (header: Int, footer: Int) {
        var header = stationaryRun(a, b, options: options, fromTop: true)
        var footer = stationaryRun(a, b, options: options, fromTop: false)
        let count = min(a.count, b.count)
        if header + footer >= count {
            header = 0
            footer = 0
        }
        let candidateHeader = max(fallbackHeader, header)
        let candidateFooter = max(fallbackFooter, footer)
        if count - candidateHeader - candidateFooter > options.minOverlapRows {
            return (candidateHeader, candidateFooter)
        }
        return (fallbackHeader, fallbackFooter)
    }

    /// A frame that is mostly blank cannot be placed. The seam card says so.
    static func blankSeamNote(_ rows: [RowSample]) -> String? {
        guard !rows.isEmpty else { return nil }
        let detailed = rows.reduce(0) { $0 + ($1.distinctive ? 1 : 0) }
        guard detailed * 4 <= rows.count else { return nil }
        return StitchCopy.blankSeam
    }

    static func isFlicker(_ a: [RowSample], _ b: [RowSample], options: ScrollStitcher.Options) -> Bool {
        let count = min(a.count, b.count)
        guard count > 0 else { return false }
        var header = stationaryRun(a, b, options: options, fromTop: true)
        var footer = stationaryRun(a, b, options: options, fromTop: false)
        if header + footer > count {
            header = count
            footer = 0
        }
        // A thin changed strip on a still frame is a flash. Fixed bars are the opposite:
        // the still edge is large and the part that moved is the page.
        let moving = count - header - footer
        if moving * 4 < count {
            header = 0
            footer = 0
        }
        var same = 0
        var eligible = 0
        for y in 0..<count {
            if y < header || (footer > 0 && y >= count - footer) { continue }
            // Blank and low-variance rows match at every scroll. They are not "unchanged content".
            guard a[y].distinctive || b[y].distinctive else { continue }
            eligible += 1
            if distance(a[y], b[y]) <= options.matchDistance { same += 1 }
        }
        guard eligible >= 4 else { return false }
        return same * 4 >= eligible * 3
    }

    // MARK: - Private

    /// Stationary distinctive edge, with no cap. Blank rows do not start it.
    private static func stationaryRun(
        _ a: [RowSample],
        _ b: [RowSample],
        options: ScrollStitcher.Options,
        fromTop: Bool
    ) -> Int {
        let count = min(a.count, b.count)
        var confirmed = 0
        var pendingGaps = 0
        var sawDetail = false
        for step in 0..<count {
            let y = fromTop ? step : (count - 1 - step)
            let same = distance(a[y], b[y]) <= options.matchDistance
            let detailed = a[y].distinctive || b[y].distinctive
            if same && detailed {
                pendingGaps = 0
                sawDetail = true
                confirmed = step + 1
            } else if same && sawDetail {
                pendingGaps = 0
                confirmed = step + 1
            } else {
                pendingGaps += 1
                if pendingGaps > 2 { break }
            }
        }
        return sawDetail ? confirmed : 0
    }

    private static func stickyRun(_ a: [RowSample], _ b: [RowSample], options: ScrollStitcher.Options, fromTop: Bool) -> StickyBand {
        let count = min(a.count, b.count)
        let limit = min(count, max(1, Int(Double(count) * options.maxBandFraction)))
        var confirmed = 0
        var pendingGaps = 0
        var absorbedGaps = 0
        var sawDetail = false
        for step in 0..<limit {
            let y = fromTop ? step : (count - 1 - step)
            let same = distance(a[y], b[y]) <= options.matchDistance
            let detailed = a[y].distinctive || b[y].distinctive
            if same && detailed {
                absorbedGaps += pendingGaps
                pendingGaps = 0
                sawDetail = true
                confirmed = step + 1
            } else if same && sawDetail {
                absorbedGaps += pendingGaps
                pendingGaps = 0
                confirmed = step + 1
            } else {
                pendingGaps += 1
                if pendingGaps > 2 { break }
            }
        }
        let absent = StickyBand(rows: 0, confident: true)
        guard sawDetail, confirmed > 0 else { return absent }
        // The band must actually end: a distinctive row just past it has to have moved.
        // A move that only barely clears the align distance, or a band stitched across gaps,
        // is a real candidate but not safe to strip without confirmation.
        let look = min(6, count - confirmed)
        var edgeDistance: Int?
        for step in 0..<look {
            let y = fromTop ? (confirmed + step) : (count - 1 - confirmed - step)
            guard y >= 0, y < count else { break }
            let delta = distance(a[y], b[y])
            if (a[y].distinctive || b[y].distinctive) && delta > options.alignDistance {
                edgeDistance = delta
                break
            }
        }
        guard let edgeDistance else { return absent }
        let clearBreak = options.alignDistance * 2
        let confident = absorbedGaps == 0 && edgeDistance >= clearBreak
        return StickyBand(rows: confirmed, confident: confident)
    }

    private static func verify(
        _ prev: [RowSample],
        _ next: [RowSample],
        header: Int,
        footer: Int,
        shift: Int,
        options: ScrollStitcher.Options
    ) -> Int? {
        let height = min(prev.count, next.count)
        let magnitude = abs(shift)
        let start = header
        let end = height - footer - magnitude
        guard end - start >= options.minOverlapRows else { return nil }
        let step = max(1, (end - start) / 48)
        var sum = 0
        var n = 0
        var y = start
        while y < end {
            let nextY = shift > 0 ? y : y + magnitude
            let prevY = shift > 0 ? y + magnitude : y
            guard nextY < height, prevY < height else { break }
            // Skipping every blank pair lets a 1 px miss score the same as the true shift.
            // A blank side still counts, including the edge where new content meets white.
            if prev[prevY].distinctive || next[nextY].distinctive {
                sum += distance(prev[prevY], next[nextY])
                n += 1
            }
            y += step
        }
        guard n >= 4 else { return nil }
        return sum / n
    }

    /// Best-matching row of `needle` inside `rows[from..<to]`, if that row is unique in the frame.
    /// Repeating chrome or a periodic list matches at several y values and cannot vote.
    private static func closest(
        to needle: RowSample,
        in rows: [RowSample],
        from: Int,
        to: Int,
        options: ScrollStitcher.Options
    ) -> Int? {
        guard from < to, needle.distinctive else { return nil }
        var hits: [Int] = []
        var bestY: Int?
        var best = Int.max
        for y in 0..<rows.count {
            let score = distance(needle, rows[y])
            if score <= options.matchDistance {
                hits.append(y)
            }
            if y >= from, y < to, score < best {
                best = score
                bestY = y
            }
        }
        guard let bestY, best <= options.matchDistance else { return nil }
        // Another equally good match far away — even outside the search window — means
        // this row is periodic. Near-colour neighbours (1–2 px) are not a second alignment.
        if hits.contains(where: { abs($0 - bestY) > 2 && distance(needle, rows[$0]) <= best + 2 }) {
            return nil
        }
        return bestY
    }

    private struct ShiftCluster {
        var shift: Int
        var score: Int
        var votes: Int
    }

    /// Merges shifts within 2 px (same scroll, 1 px of capture / rounding noise).
    private static func clustered(_ scored: [Int: (score: Int, votes: Int)]) -> [ShiftCluster] {
        let keys = scored.keys.sorted()
        var clusters: [ShiftCluster] = []
        var index = 0
        while index < keys.count {
            var group = [keys[index]]
            var next = index + 1
            while next < keys.count, keys[next] - keys[next - 1] <= AliasRival.shiftGap {
                group.append(keys[next])
                next += 1
            }
            var score = Int.max
            var votes = 0
            var bestShift = group[0]
            var bestVotes = -1
            for shift in group {
                guard let item = scored[shift] else { continue }
                votes += item.votes
                if item.score < score || (item.score == score && item.votes > bestVotes) {
                    score = item.score
                    bestShift = shift
                    bestVotes = item.votes
                }
            }
            clusters.append(ShiftCluster(shift: bestShift, score: score, votes: votes))
            index = next
        }
        return clusters.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.votes != rhs.votes { return lhs.votes > rhs.votes }
            if abs(lhs.shift) != abs(rhs.shift) { return abs(lhs.shift) < abs(rhs.shift) }
            return lhs.shift > rhs.shift
        }
    }

    private static func resolveAlias(best: ShiftCluster, rivals: [ShiftCluster], prior: Int) -> Int? {
        let candidates = [best] + rivals
        // Same-quality motion the other way means the page may have reversed.
        // Confirming the forward alias would stitch that reverse in the wrong direction.
        let reversed = candidates.contains { candidate in
            prior != 0
                && candidate.shift.signum() != prior.signum()
                && candidate.score <= best.score
                && candidate.votes >= best.votes
        }
        if reversed { return nil }
        guard let preferred = candidates.min(by: { abs($0.shift - prior) < abs($1.shift - prior) }) else {
            return nil
        }
        // A rival may stand in for best only when it is not a worse match.
        if preferred.shift != best.shift {
            guard preferred.score <= best.score, preferred.votes >= best.votes else { return nil }
        }
        let sameDirection = preferred.shift.signum() == prior.signum() || prior == 0
        let closeEnough = abs(preferred.shift - prior) <= max(4, abs(prior) / 4)
        return sameDirection && closeEnough ? preferred.shift : nil
    }

    private static func anchorRows(_ rows: [RowSample], from: Int, to: Int, bias: Bias) -> [Int] {
        guard from < to else { return [] }
        let indices = (from..<to).filter { rows[$0].distinctive }
        guard !indices.isEmpty else { return [] }
        let pool: [Int]
        switch bias {
        case .top:
            pool = Array(indices.prefix(max(indices.count / 2, 1)))
        case .bottom:
            pool = Array(indices.suffix(max(indices.count / 2, 1)))
        }
        if pool.count <= 8 { return pool }
        return (0..<8).map { pool[$0 * (pool.count - 1) / 7] }
    }

    private static func sampleColumns(width: Int, count: Int) -> [Int] {
        let margin = min(max(1, width / 25), width / 5)
        let right = min(max(1, width * 6 / 100), width / 5)
        let start = min(margin, width - 1)
        let end = max(start + 1, width - right)
        let span = end - start
        let samples = max(4, count)
        if span <= samples { return Array(start..<end) }
        return (0..<samples).map { start + ($0 * (span - 1)) / (samples - 1) }
    }

    private static func distance(_ a: RowSample, _ b: RowSample) -> Int {
        let n = min(a.bytes.count, b.bytes.count)
        guard n > 0 else { return 255 }
        var sum = 0
        for i in 0..<n {
            sum += abs(Int(a.bytes[i]) - Int(b.bytes[i]))
        }
        return sum / n
    }

    private static func averageDistance(_ a: [RowSample], _ b: [RowSample]) -> Int {
        let count = min(a.count, b.count)
        guard count > 0 else { return 255 }
        var sum = 0
        for y in 0..<count { sum += distance(a[y], b[y]) }
        return sum / count
    }
}
