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

    public init(id: String, state: SeamState, y: Int, boundaryIndex: Int?, suggestedOverlap: Int?) {
        self.id = id
        self.state = state
        self.y = y
        self.boundaryIndex = boundaryIndex
        self.suggestedOverlap = suggestedOverlap
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

public struct ScrollSeam: Equatable {
    public var kind: Kind
    /// Best-guess overlap (rows) when `kind` is `.needsAlignment`. Not applied until the user says so.
    public var suggestedOverlap: Int?

    public enum Kind: Equatable {
        case needsAlignment
        case aligned(overlap: Int)
        case joinedAsIs
    }

    public init(kind: Kind, suggestedOverlap: Int? = nil) {
        self.kind = kind
        self.suggestedOverlap = suggestedOverlap
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
    /// Reused `presented` images so dragging a seam does not copy the whole stack again.
    var presentationCache = PresentationCache()

    public init(
        segments: [ScrollSegment] = [],
        seams: [ScrollSeam] = [],
        dedupeStickyBars: Bool = true,
        pendingSticky: PendingStickyConfirmation? = nil
    ) {
        self.segments = segments
        self.seams = seams
        self.dedupeStickyBars = dedupeStickyBars
        self.pendingSticky = pendingSticky
    }

    public static func == (lhs: ScrollAssembly, rhs: ScrollAssembly) -> Bool {
        lhs.segments == rhs.segments
            && lhs.seams == rhs.seams
            && lhs.dedupeStickyBars == rhs.dedupeStickyBars
            && lhs.pendingSticky == rhs.pendingSticky
    }

    public var needsReview: Bool {
        if pendingSticky?.isUnresolved == true { return true }
        return seams.contains { !$0.isResolved }
    }

    /// The stitch preview opens only while a seam or a sticky-bar choice still needs a decision.
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

    /// Unaligned seams, other confirmations, and one uncertain sticky band.
    public var reviewRemainder: StitchCopy.Remainder {
        StitchCopy.Remainder(
            unaligned: unalignedSeamCount,
            pendingConfirm: 0,
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
                    suggestedOverlap: seam.suggestedOverlap
                ))
                let color: (UInt8, UInt8, UInt8) = seam.isResolved ? (126, 184, 168) : (232, 160, 168)
                paintLine(at: y, fullHeight: fullHeight, factor: factor, outW: outW, outH: outH, color: color, into: &pixels)
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
        into pixels: inout [UInt8]
    ) {
        guard fullHeight > 0 else { return }
        let row = min(outH - 1, max(0, Int((CGFloat(fullY) * factor).rounded(.down))))
        for x in 0..<outW {
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

    public init(options: Options = Options()) {
        self.options = options
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

        let found = RowSamples.bestShift(prevRows, nextRows, header: headerH, footer: footerH, options: options)
        if let match = found, match.confident {
            let outcome = apply(next: frame, shift: match.shift, headerH: headerH, footerH: footerH)
            switch outcome {
            case .appended, .prepended, .reachedLimit:
                if lockedHeader == nil {
                    lockedHeader = headerH
                    lockedFooter = footerH
                }
                if pendingSticky != nil, headerH > 0 || footerH > 0 {
                    pendingSticky?.seamCount += 1
                }
                previous = frame
            case .unchanged:
                break
            case .unmatched:
                return breakUnmatched(frame, suggested: max(0, frame.height - abs(match.shift)))
            case .seeded, .ignored:
                break
            }
            return outcome
        }
        let suggested = found.map { max(0, frame.height - abs($0.shift)) }
        return breakUnmatched(frame, suggested: suggested)
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
        let repeatHeader = canvasHeader > 0
            ? canvas.crop(rows: 0..<canvasHeader)
            : RGBAImage(width: next.width, height: 0, pixels: [])
        let repeatFooter = canvasFooter > 0
            ? canvas.crop(rows: (canvas.height - canvasFooter)..<canvas.height)
            : RGBAImage(width: next.width, height: 0, pixels: [])

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
                    canvas = canvas.crop(rows: 0..<(canvas.height - canvasFooter))
                }
                canvas.insertRows(newFooter, at: canvas.height)
                canvasFooter = newFooter.height
            }
        }
        canvasIsSeed = false
        if repeatHeader.height > 0 || repeatFooter.height > 0 {
            stickyRepeats.append(StickyRepeat(seamY: joinY, header: repeatHeader, footer: repeatFooter))
        }
        if clipped { return .reachedLimit }
        return prepend ? .prepended(fitted.height) : .appended(fitted.height)
    }

    private mutating func breakUnmatched(_ frame: RGBAImage, suggested: Int?) -> ScrollIngest {
        let room = ScrollOutputLimit.remainingRows(
            totalHeight: pixelHeight,
            width: frame.width,
            maxHeight: options.maxHeight,
            maxPixels: options.maxPixels
        )
        // Don't start another full viewport that would blow the cap, and don't clip it into a fake join.
        if pixelHeight > 0, room < frame.height { return .reachedLimit }
        sealOpenSegment()
        seams.append(ScrollSeam(kind: .needsAlignment, suggestedOverlap: suggested))
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

    private mutating func sealOpenSegment() {
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
    }

    static func bestShift(_ prev: [RowSample], _ next: [RowSample], header: Int, footer: Int, options: ScrollStitcher.Options) -> ShiftChoice? {
        let height = min(prev.count, next.count)
        let contentEnd = height - footer
        guard header >= 0, footer >= 0, contentEnd - header > options.minOverlapRows else { return nil }

        var scored: [Int: Int] = [:]

        func consider(_ shift: Int) {
            guard shift != 0 else { return }
            guard let score = verify(prev, next, header: header, footer: footer, shift: shift, options: options) else { return }
            guard score <= options.alignDistance else { return }
            if let existing = scored[shift] {
                scored[shift] = min(existing, score)
            } else {
                scored[shift] = score
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

        let ranked = scored.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let left = abs(lhs.key)
            let right = abs(rhs.key)
            if left != right { return left < right }
            return lhs.key > rhs.key
        }
        guard let best = ranked.first else { return nil }
        // A tied or near-tied second shift — including several perfect scores of 0 — is not safe.
        // Dictionary order is not a tie-break; repeated list rows must stay unconfirmed.
        let ambiguous = ranked.dropFirst().contains { $0.value <= best.value + 4 }
        return ShiftChoice(shift: best.key, confident: !ambiguous)
    }

    // MARK: - Private

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
        let step = max(1, (end - start) / 24)
        var sum = 0
        var n = 0
        var y = start
        while y < end {
            let nextY = shift > 0 ? y : y + magnitude
            let prevY = shift > 0 ? y + magnitude : y
            guard nextY < height, prevY < height else { break }
            if prev[prevY].distinctive || next[nextY].distinctive {
                sum += distance(prev[prevY], next[nextY])
                n += 1
            }
            y += step
        }
        guard n >= 4 else { return nil }
        return sum / n
    }

    /// Best-matching row of `needle` inside `rows[from..<to]`, if it is close enough to be the same content.
    private static func closest(
        to needle: RowSample,
        in rows: [RowSample],
        from: Int,
        to: Int,
        options: ScrollStitcher.Options
    ) -> Int? {
        guard from < to, needle.distinctive else { return nil }
        var bestY: Int?
        var best = Int.max
        for y in from..<to {
            let score = distance(needle, rows[y])
            if score < best {
                best = score
                bestY = y
            }
        }
        guard let bestY, best <= options.matchDistance else { return nil }
        return bestY
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
        if pool.count <= 5 { return pool }
        return (0..<5).map { pool[$0 * (pool.count - 1) / 4] }
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
