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

/// Paint for a 「待确认」 seam. These are the values on screen today.
public enum PendingSeamStyle {
    public static let warn: UInt32 = 0xE8A33D
    public static let text: UInt32 = 0xE8A33D
    public static let fillOpacity: Double = 0
    public static let labelBorderWidth: Int = 1
    /// The seam line is one preview row, dashed 4 px on / 4 px off.
    public static let seamLineWidth: Int = 1
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

    public init(
        label: String,
        chrome: Chrome,
        title: String? = nil,
        reason: String? = nil,
        candidates: [String] = []
    ) {
        self.label = label
        self.chrome = chrome
        self.title = title
        self.reason = reason
        self.candidates = candidates
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
        candidateLines: [String] = []
    ) {
        self.kind = kind
        self.suggestedOverlap = suggestedOverlap
        self.note = note
        self.pendingTitle = pendingTitle
        self.candidateLines = candidateLines
    }

    /// Review copy for this boundary. `number` is the 1-based seam index.
    /// A lone reverse candidate uses the amber dashed 「待确认」 label.
    /// An equal-score tie uses that same label, plus the tie title and the candidate lines.
    public func card(number: Int) -> SeamCard {
        precondition(number >= 1)
        if pendingTitle != nil || !candidateLines.isEmpty {
            return SeamCard(
                label: "待确认",
                chrome: .amberDashed,
                title: pendingTitle,
                reason: note,
                candidates: candidateLines
            )
        }
        if case .needsAlignment = kind, note == StitchCopy.reverseSeam {
            return SeamCard(label: "待确认", chrome: .amberDashed, reason: note)
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
}

/// A stretch that may repeat an earlier segment. It stays in 「待确认」 until the user chooses.
public struct DuplicateSegmentCandidate: Equatable, Identifiable {
    public var id: String
    /// Nil until the user chooses 「保留一次」 or 「都保留」.
    public var choice: DuplicateSegmentChoice?

    public init(id: String, choice: DuplicateSegmentChoice? = nil) {
        self.id = id
        self.choice = choice
    }

    public var isUnresolved: Bool { choice == nil }
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
        duplicateChoiceUndo.append(DuplicateChoiceRecord(id: id, previous: previous))
        duplicateCandidates[index].choice = choice
    }

    /// Puts the most recent duplicate-segment choice back. An undone resolution counts as 「待确认」 again.
    public mutating func undoLastDuplicateCandidateChoice() {
        guard let last = duplicateChoiceUndo.popLast() else { return }
        guard let index = duplicateCandidates.firstIndex(where: { $0.id == last.id }) else { return }
        duplicateCandidates[index].choice = last.previous
    }

    /// Puts one candidate back to unresolved (`choice == nil`) and records that restore on the undo stack.
    /// A missing id, or a candidate that is already unresolved, is left unchanged.
    public mutating func restoreDuplicateCandidate(_ id: String) {
        guard let index = duplicateCandidates.firstIndex(where: { $0.id == id }) else { return }
        guard let previous = duplicateCandidates[index].choice else { return }
        duplicateChoiceUndo.append(DuplicateChoiceRecord(id: id, previous: previous))
        duplicateCandidates[index].choice = nil
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
        var total = presentedHeight(first, dedupe: deduping)
        for index in seams.indices where segments.indices.contains(index + 1) {
            let nextHeight = presentedHeight(segments[index + 1], dedupe: deduping)
            let start: Int
            switch seams[index].kind {
            case .needsAlignment, .joinedAsIs:
                start = 0
            case .aligned(let overlap):
                start = min(max(0, overlap), nextHeight)
            }
            total += max(0, nextHeight - start)
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
    /// Rows are never dropped; a piece that would overflow starts the next image.
    /// Refuses while any seam is still unaligned, so a segment is never stitched across that seam
    /// and the seam is not force-cut into its own export either.
    public func exportWithinLimits(
        dedupeStickyBars dedupe: Bool,
        maxHeight: Int = ScrollOutputLimit.maxHeight,
        maxPixels: Int = ScrollOutputLimit.maxPixels
    ) -> [RGBAImage] {
        if seams.contains(where: { !$0.isResolved }) { return [] }
        var slices: [RGBAImage] = []
        for (index, segment) in segments.enumerated() {
            var parts = Self.contentSlices(segment, dedupe: dedupe)
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
            slices.append(contentsOf: parts)
        }
        return Self.pack(slices, maxHeight: maxHeight, maxPixels: maxPixels)
    }

    public mutating func align(seam index: Int, overlap: Int) {
        guard seams.indices.contains(index), segments.indices.contains(index + 1) else { return }
        let limit = max(0, presented(at: index + 1).image.height - 1)
        seams[index].kind = .aligned(overlap: min(max(0, overlap), limit))
    }

    /// Puts the overlap back on the automatic suggestion and marks the seam aligned.
    /// The capture itself never applies that suggestion until the user asks.
    public mutating func restoreAutoAlignment(seam index: Int) {
        guard seams.indices.contains(index) else { return }
        align(seam: index, overlap: seams[index].suggestedOverlap ?? 0)
    }

    public mutating func joinAsIs(seam index: Int) {
        guard seams.indices.contains(index) else { return }
        seams[index].kind = .joinedAsIs
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
        for index in seams.indices where segments.indices.contains(index + 1) {
            let next = presented(at: index + 1).image
            switch seams[index].kind {
            case .needsAlignment:
                if let joined = RGBAImage.verticalJoin(current) { chunks.append(joined) }
                current = [next]
            case .joinedAsIs:
                current.append(next)
            case .aligned(let overlap):
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

        var origins: [Int] = []
        var cursor = 0
        for piece in layout.pieces {
            origins.append(cursor)
            cursor += piece.image.height - piece.start
        }

        for row in 0..<outH {
            let sourceY = min(fullHeight - 1, Int((CGFloat(row) / factor).rounded(.down)))
            guard let pieceIndex = origins.lastIndex(where: { $0 <= sourceY }) else { continue }
            let piece = layout.pieces[pieceIndex]
            let local = piece.start + (sourceY - origins[pieceIndex])
            guard local >= 0, local < piece.image.height else { continue }
            piece.image.withRow(local) { src in
                let dst = row * outW * 4
                guard src.count >= 4 else { return }
                for x in 0..<outW {
                    let sourceX = min(piece.image.width - 1, Int((CGFloat(x) / factor).rounded(.down)))
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
                let y = origins[segmentIndex] + (piece.image.height - piece.start)
                marks.append(SeamMark(
                    id: "boundary-\(segmentIndex)",
                    state: seam.state,
                    y: y,
                    boundaryIndex: segmentIndex,
                    suggestedOverlap: seam.suggestedOverlap,
                    note: seam.note
                ))
                let card = seam.card(number: segmentIndex + 1)
                if card.chrome == .amberDashed {
                    paintLine(
                        at: y,
                        fullHeight: fullHeight,
                        factor: factor,
                        outW: outW,
                        outH: outH,
                        color: (232, 163, 61),
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
    }

    /// Dedupe-off view of a segment: repeated sticky bars spliced back at each confident seam.
    /// Results are cached by dedupe state and segment shape so a slider drag can reuse them.
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
        if let cached = presentationCache.values[key] {
            presentationCache.hits += 1
            return cached
        }
        let built = Self.makePresented(segment, dedupe: dedupeStickyBars)
        presentationCache.values[key] = built
        return built
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

    private func presentedHeight(_ segment: ScrollSegment, dedupe: Bool) -> Int {
        guard !dedupe else { return segment.image.height }
        let extra = segment.stickyRepeats.reduce(0) { $0 + $1.header.height + $1.footer.height }
        return segment.image.height + extra
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
            if start < next.height {
                pieces.append(Piece(image: next, start: start))
            }
        }
        let fullHeight = pieces.reduce(0) { $0 + ($1.image.height - $1.start) }
        return (pieces, fullHeight)
    }

    private func paintLine(
        at fullY: Int,
        fullHeight: Int,
        factor: CGFloat,
        outW: Int,
        outH: Int,
        color: (UInt8, UInt8, UInt8),
        dashed: Bool = false,
        into pixels: inout [UInt8]
    ) {
        guard fullHeight > 0 else { return }
        let row = min(outH - 1, max(0, Int((CGFloat(fullY) * factor).rounded(.down))))
        for x in 0..<outW {
            // 4 px on, 4 px off, in preview pixels.
            if dashed, x % 8 >= 4 { continue }
            let d = (row * outW + x) * 4
            pixels[d] = color.0
            pixels[d + 1] = color.1
            pixels[d + 2] = color.2
            pixels[d + 3] = 255
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

    public init(options: Options = Options()) {
        self.options = options
    }

    /// 「开始拼接」. Drops the shift remembered for repeating-card aliases so the next
    /// pass cannot inherit a direction from the previous one.
    public mutating func beginStitch() {
        lastShift = nil
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
            let outcome = apply(next: frame, shift: matchFound.shift, headerH: match.header, footerH: match.footer)
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
            selectedShift: found?.shift
        )
    }

    /// Seals the open segment and returns every piece. Call once, when capture ends.
    public mutating func takeAssembly() -> ScrollAssembly {
        sealOpenSegment()
        return ScrollAssembly(segments: segments, seams: seams, pendingSticky: pendingSticky)
    }

    public func cgImage() -> CGImage? {
        var copy = self
        return copy.takeAssembly().flattenedIfResolved()?.cgImage()
    }

    // MARK: - Apply

    private mutating func apply(next: RGBAImage, shift: Int, headerH: Int, footerH: Int) -> ScrollIngest {
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
        if repeatHeader.height > 0 || repeatFooter.height > 0 {
            stickyRepeats.append(StickyRepeat(seamY: joinY, header: repeatHeader, footer: repeatFooter))
        }
        if clipped { return .reachedLimit }
        return prepend ? .prepended(fitted.height) : .appended(fitted.height)
    }

    private mutating func breakUnmatched(
        _ frame: RGBAImage,
        suggested: Int?,
        note: String? = nil,
        tieShifts: [Int]? = nil,
        selectedShift: Int? = nil
    ) -> ScrollIngest {
        let room = ScrollOutputLimit.remainingRows(
            totalHeight: pixelHeight,
            width: frame.width,
            maxHeight: options.maxHeight,
            maxPixels: options.maxPixels
        )
        // Don't start another full viewport that would blow the cap, and don't clip it into a fake join.
        if pixelHeight > 0, room < frame.height { return .reachedLimit }
        sealOpenSegment()
        var seamNote = note ?? RowSamples.blankSeamNote(RowSamples.make(frame, options: options))
        var pendingTitle: String?
        var candidateLines: [String] = []
        if let tieShifts, tieShifts.count >= 2 {
            let number = seams.count + 1
            pendingTitle = "接缝 \(number) · 待确认：位移无法唯一确定"
            seamNote = "找到 \(tieShifts.count) 个得分相同的位移，自动对齐没法确定是哪一个——为了不拼错，先停下来请你确认。"
            let selected = selectedShift ?? tieShifts[0]
            candidateLines = tieShifts.sorted(by: >).enumerated().map { index, shift in
                Self.shiftCandidateLine(index: index, shift: shift, selected: selected)
            }
        }
        seams.append(ScrollSeam(
            kind: .needsAlignment,
            suggestedOverlap: suggested,
            note: seamNote,
            pendingTitle: pendingTitle,
            candidateLines: candidateLines
        ))
        let savedHeader = lockedHeader
        let savedFooter = lockedFooter
        let savedPending = pendingSticky
        previous = frame
        canvas = frame
        canvasHeader = 0
        canvasFooter = 0
        canvasIsSeed = true
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
            abs(rival.shift - best.shift) > 2
                && rival.score <= best.score + 4
                && rival.votes * 2 >= best.votes
        }
        // One candidate used to be trusted even when it reversed the last shift.
        // Only that lone opposite candidate uses the reverse-seam line.
        // Two or more equal scores, one of them the other way, are a shift tie.
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
        let equalScores = ranked.filter { cluster in
            cluster.score == best.score && abs(cluster.shift - best.shift) > 2
        }
        let tieShifts = [best.shift] + equalScores.map(\.shift)
        let oppositeTie = tieShifts.contains { $0.signum() != best.shift.signum() }
        if oppositeTie {
            return ShiftChoice(shift: best.shift, confident: false, reversed: false, tieShifts: tieShifts)
        }
        return ShiftChoice(shift: best.shift, confident: false, reversed: false)
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
            while next < keys.count, keys[next] - keys[next - 1] <= 2 {
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
