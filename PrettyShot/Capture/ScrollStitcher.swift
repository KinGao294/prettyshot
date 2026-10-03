import CoreGraphics
import CoreVideo

/// One viewport-sized frame (or a strip of one), RGBA8, row 0 at the top.
struct RGBAImage: Equatable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func crop(rows: Range<Int>) -> RGBAImage {
        let lower = max(0, rows.lowerBound)
        let upper = min(height, rows.upperBound)
        guard width > 0, upper > lower else {
            return RGBAImage(width: width, height: 0, pixels: [])
        }
        let rowBytes = width * 4
        let start = lower * rowBytes
        let end = upper * rowBytes
        return RGBAImage(width: width, height: upper - lower, pixels: Array(pixels[start..<end]))
    }

    static func verticalJoin(_ parts: [RGBAImage]) -> RGBAImage? {
        let pieces = parts.filter { $0.height > 0 && $0.width > 0 }
        guard let width = pieces.first?.width, pieces.allSatisfy({ $0.width == width }) else { return nil }
        let height = pieces.reduce(0) { $0 + $1.height }
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for piece in pieces { pixels.append(contentsOf: piece.pixels) }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    /// Top-down RGBA → CGImage. The provider retains the pixel bytes.
    func cgImage() -> CGImage? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Draws `image` into a top-down RGBA buffer (row 0 is the top).
    static func fromCGImage(_ image: CGImage) -> RGBAImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = storage.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Bitmap row 0 is the bottom of the context. Draw upright, then flip below.
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let rowBytes = width * 4
        for y in 0..<(height / 2) {
            let top = y * rowBytes
            let bottom = (height - 1 - y) * rowBytes
            for offset in 0..<rowBytes {
                let index = top + offset
                let other = bottom + offset
                storage.swapAt(index, other)
            }
        }
        return RGBAImage(width: width, height: height, pixels: storage)
    }

    /// Copies a BGRA/RGBA `CVPixelBuffer` (row 0 = top, as ScreenCaptureKit delivers it).
    static func fromPixelBuffer(_ buffer: CVPixelBuffer) -> RGBAImage? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let bgra = format == kCVPixelFormatType_32BGRA
        let rgba = format == kCVPixelFormatType_32RGBA
        guard bgra || rgba else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let source = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = source.advanced(by: y * bytesPerRow)
            let destination = y * width * 4
            if rgba {
                for x in 0..<(width * 4) {
                    pixels[destination + x] = row[x]
                }
            } else {
                for x in 0..<width {
                    let s = x * 4
                    let d = destination + s
                    pixels[d] = row[s + 2]
                    pixels[d + 1] = row[s + 1]
                    pixels[d + 2] = row[s]
                    pixels[d + 3] = row[s + 3]
                }
            }
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }
}

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
enum ScrollOutputLimit {
    static let maxHeight = 16_384
    static let maxPixels = 24_000_000

    static var notice: String {
        "已达到长度上限（高 \(maxHeight) px，或 \(maxPixels / 1_000_000) 百万像素），滚动捕获已自动停止。"
    }

    /// How many more rows of `width` fit under both caps.
    static func remainingRows(totalHeight: Int, width: Int, maxHeight: Int = maxHeight, maxPixels: Int = maxPixels) -> Int {
        let heightRoom = maxHeight - totalHeight
        guard heightRoom > 0, width > 0 else { return 0 }
        let used = Int64(max(totalHeight, 0)) * Int64(width)
        let pixelRoom = Int64(maxPixels) - used
        guard pixelRoom > 0 else { return 0 }
        let fromPixels = Int(pixelRoom / Int64(width))
        return max(0, min(heightRoom, fromPixels))
    }
}

enum ScrollIngest: Equatable {
    case seeded
    case unchanged
    case appended(Int)
    case prepended(Int)
    /// Overlap was not confident. The frame started (or is) its own segment; nothing was force-joined.
    case unmatched
    case reachedLimit
    case ignored
}

enum SeamState: Equatable {
    /// Confident automatic overlap inside one segment.
    case ok
    /// Could not be aligned safely. The image must not be flattened until the user decides.
    case needsAlignment
    /// User set an overlap, in rows trimmed from the top of the next segment.
    case aligned
    /// User explicitly stacked the segments with no overlap.
    case joinedAsIs
}

struct SeamMark: Identifiable, Equatable {
    var id: String
    var state: SeamState
    /// Row in the full-resolution stack (top of the join).
    var y: Int
    /// Index into `ScrollAssembly.seams` when this mark is a boundary between segments.
    var boundaryIndex: Int?
    var suggestedOverlap: Int?
}

struct ScrollSegment: Equatable {
    var image: RGBAImage
    /// Y positions, in `image`, where a confident join added new rows.
    var confidentSeamYs: [Int]
}

struct ScrollSeam: Equatable {
    var kind: Kind
    /// Best-guess overlap (rows) when `kind` is `.needsAlignment`. Not applied until the user says so.
    var suggestedOverlap: Int?

    enum Kind: Equatable {
        case needsAlignment
        case aligned(overlap: Int)
        case joinedAsIs
    }

    var state: SeamState {
        switch kind {
        case .needsAlignment: return .needsAlignment
        case .aligned: return .aligned
        case .joinedAsIs: return .joinedAsIs
        }
    }

    var isResolved: Bool {
        if case .needsAlignment = kind { return false }
        return true
    }

    /// Overlap the editor should show. Unresolved seams report the suggestion, still unapplied.
    var editorOverlap: Int {
        switch kind {
        case .needsAlignment: return max(0, suggestedOverlap ?? 0)
        case .aligned(let overlap): return max(0, overlap)
        case .joinedAsIs: return 0
        }
    }
}

/// Segments split only where alignment was not confident. Confident joins are already baked in.
struct ScrollAssembly: Equatable {
    var segments: [ScrollSegment] = []
    /// `seams[i]` sits between `segments[i]` and `segments[i + 1]`.
    var seams: [ScrollSeam] = []

    var needsReview: Bool { seams.contains { !$0.isResolved } }

    var confidentSeamCount: Int { segments.reduce(0) { $0 + $1.confidentSeamYs.count } }

    mutating func align(seam index: Int, overlap: Int) {
        guard seams.indices.contains(index), segments.indices.contains(index + 1) else { return }
        let limit = max(0, segments[index + 1].image.height - 1)
        seams[index].kind = .aligned(overlap: min(max(0, overlap), limit))
    }

    mutating func joinAsIs(seam index: Int) {
        guard seams.indices.contains(index) else { return }
        seams[index].kind = .joinedAsIs
    }

    /// Nil while any seam still needs a decision — a wrong stitch is never returned implicitly.
    func flattenedIfResolved() -> RGBAImage? {
        guard !needsReview else { return nil }
        let chunks = exportChunks()
        guard chunks.count == 1 else { return nil }
        return chunks[0]
    }

    /// Resolved neighbors are merged. An unresolved boundary starts a new chunk.
    func exportChunks() -> [RGBAImage] {
        guard let first = segments.first else { return [] }
        var chunks: [RGBAImage] = []
        var current: [RGBAImage] = [first.image]
        for index in seams.indices where segments.indices.contains(index + 1) {
            let next = segments[index + 1].image
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
    func renderPreview(maxLongSide: Int = 1200) -> (image: RGBAImage, marks: [SeamMark])? {
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
            let src = local * piece.image.width * 4
            let dst = row * outW * 4
            guard src + 3 < piece.image.pixels.count else { continue }
            for x in 0..<outW {
                let sourceX = min(piece.image.width - 1, Int((CGFloat(x) / factor).rounded(.down)))
                let s = src + sourceX * 4
                let d = dst + x * 4
                guard s + 3 < piece.image.pixels.count, d + 3 < pixels.count else { continue }
                pixels[d] = piece.image.pixels[s]
                pixels[d + 1] = piece.image.pixels[s + 1]
                pixels[d + 2] = piece.image.pixels[s + 2]
                pixels[d + 3] = 255
            }
        }

        var marks: [SeamMark] = []
        for (segmentIndex, segment) in segments.enumerated() where segmentIndex < layout.pieces.count {
            let piece = layout.pieces[segmentIndex]
            let origin = origins[segmentIndex]
            for (offset, seamY) in segment.confidentSeamYs.enumerated() where seamY >= piece.start {
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

    private func layoutPieces() -> (pieces: [Piece], fullHeight: Int) {
        guard let first = segments.first else { return ([], 0) }
        var pieces = [Piece(image: first.image, start: 0)]
        for index in seams.indices where segments.indices.contains(index + 1) {
            let next = segments[index + 1].image
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
/// slice. Identical frames add nothing. A frame that cannot be aligned is NOT force-joined; it
/// starts a new segment and the seam is marked as needing alignment.
struct ScrollStitcher {
    struct Options: Equatable {
        var sampleCount = 24
        /// Rows whose sampled channels span less than this are blank and cannot anchor a match.
        var distinctSpan = 18
        /// Mean per-channel distance (0...255) that still counts as "the same row".
        var matchDistance = 12
        /// A frame whose distinctive rows mostly stay under this distance did not scroll.
        var unchangedDistance = 6
        /// Mean distance accepted when checking a candidate shift across the overlap.
        var alignDistance = 18
        var minOverlapRows = 8
        /// Sticky bands cannot claim more than this fraction of the viewport.
        var maxBandFraction = 0.45
        var maxHeight = ScrollOutputLimit.maxHeight
        var maxPixels = ScrollOutputLimit.maxPixels
    }

    private(set) var options: Options
    private(set) var acceptedFrames = 0
    private(set) var unmatchedBreaks = 0
    private var segments: [ScrollSegment] = []
    private var seams: [ScrollSeam] = []
    private var header: RGBAImage?
    private var footer: RGBAImage?
    private var parts: [RGBAImage] = []
    private var confidentYs: [Int] = []
    private var previous: RGBAImage?
    private var lockedHeader: Int?
    private var lockedFooter: Int?

    init(options: Options = Options()) {
        self.options = options
    }

    var hasFrame: Bool { previous != nil || !segments.isEmpty }

    var segmentCount: Int { segments.count + (previous == nil ? 0 : 1) }

    var pixelHeight: Int { sealedHeight + openHeight }

    private var sealedHeight: Int { segments.reduce(0) { $0 + $1.image.height } }

    private var openHeight: Int {
        (header?.height ?? 0) + parts.reduce(0) { $0 + $1.height } + (footer?.height ?? 0)
    }

    mutating func ingest(_ frame: RGBAImage) -> ScrollIngest {
        guard frame.width >= 8, frame.height > options.minOverlapRows,
              frame.pixels.count >= frame.width * frame.height * 4 else { return .ignored }
        acceptedFrames += 1
        guard let prev = previous else {
            previous = frame
            parts = [frame]
            return .seeded
        }
        guard prev.width == frame.width, prev.height == frame.height else {
            acceptedFrames -= 1
            return .ignored
        }

        let prevRows = RowSamples.make(prev, options: options)
        let nextRows = RowSamples.make(frame, options: options)
        if RowSamples.isUnchanged(prevRows, nextRows, options: options) {
            previous = frame
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
            let contentSpan = frame.height - detectedHeader - detectedFooter
            let bandsOK = (detectedHeader > 0 || detectedFooter > 0)
                && contentSpan >= options.minOverlapRows * 2
                && detectedHeader + detectedFooter <= Int(Double(frame.height) * options.maxBandFraction)
            headerH = bandsOK ? detectedHeader : 0
            footerH = bandsOK ? detectedFooter : 0
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
                previous = frame
            case .unchanged:
                previous = frame
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
    mutating func takeAssembly() -> ScrollAssembly {
        sealOpenSegment()
        return ScrollAssembly(segments: segments, seams: seams)
    }

    func cgImage() -> CGImage? {
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
        if footerH > 0 {
            footer = next.crop(rows: (next.height - footerH)..<next.height)
        }

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
        let seamY = (header?.height ?? 0) + parts.reduce(0) { $0 + $1.height }
        if prepend {
            let added = fitted.height
            confidentYs = confidentYs.map { $0 + added }
            confidentYs.append((header?.height ?? 0) + added)
            parts.insert(fitted, at: 0)
        } else {
            confidentYs.append(seamY)
            parts.append(fitted)
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
        previous = frame
        parts = [frame]
        header = nil
        footer = nil
        lockedHeader = nil
        lockedFooter = nil
        confidentYs = []
        unmatchedBreaks += 1
        return .unmatched
    }

    private mutating func sealOpenSegment() {
        guard previous != nil, let image = openImage(), image.height > 0 else { return }
        segments.append(ScrollSegment(image: image, confidentSeamYs: confidentYs))
        header = nil
        footer = nil
        parts = []
        previous = nil
        lockedHeader = nil
        lockedFooter = nil
        confidentYs = []
    }

    private func openImage() -> RGBAImage? {
        var chunks: [RGBAImage] = []
        if let header { chunks.append(header) }
        chunks.append(contentsOf: parts)
        if let footer { chunks.append(footer) }
        return RGBAImage.verticalJoin(chunks)
    }

    private mutating func splitSeedIfNeeded(headerH: Int, footerH: Int) {
        guard header == nil, footer == nil, headerH > 0 || footerH > 0, parts.count == 1 else { return }
        let seed = parts[0]
        guard seed.height > headerH + footerH else { return }
        if headerH > 0 {
            header = seed.crop(rows: 0..<headerH)
        }
        let midEnd = seed.height - footerH
        parts = [seed.crop(rows: headerH..<midEnd)]
        if footerH > 0 {
            footer = seed.crop(rows: midEnd..<seed.height)
        }
    }
}

/// Screen-local selection (Cocoa, origin bottom-left) → ScreenCaptureKit `sourceRect`
/// (points, origin top-left of the display).
enum ScrollingCaptureGeometry {
    static func sourceRect(selection: CGRect, screenSize: CGSize) -> CGRect {
        guard screenSize.width > 0, screenSize.height > 0 else { return .null }
        let flipped = CGRect(
            x: selection.minX,
            y: screenSize.height - selection.maxY,
            width: selection.width,
            height: selection.height
        )
        return flipped.integral.intersection(CGRect(origin: .zero, size: screenSize))
    }
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
            let row = y * image.width * 4
            for x in xs {
                let i = row + x * 4
                let r = image.pixels[i]
                let g = image.pixels[i + 1]
                let b = image.pixels[i + 2]
                bytes.append(r)
                bytes.append(g)
                bytes.append(b)
                minC = min(minC, Int(r), Int(g), Int(b))
                maxC = max(maxC, Int(r), Int(g), Int(b))
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

    /// Leading rows that stayed put while something below them moved. Blank rows do not start a band.
    static func stickyPrefix(_ a: [RowSample], _ b: [RowSample], options: ScrollStitcher.Options) -> Int {
        stickyRun(a, b, options: options, fromTop: true)
    }

    static func stickySuffix(_ a: [RowSample], _ b: [RowSample], options: ScrollStitcher.Options) -> Int {
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

        guard let best = scored.min(by: { $0.value < $1.value }) else { return nil }
        let rivals = scored.filter { $0.key != best.key }
        if let second = rivals.min(by: { $0.value < $1.value }), best.value > 3, second.value < best.value + 5 {
            // A close second guess is not safe to bake in. Hand the hint to the review UI instead.
            return ShiftChoice(shift: best.key, confident: false)
        }
        return ShiftChoice(shift: best.key, confident: true)
    }

    // MARK: - Private

    private static func stickyRun(_ a: [RowSample], _ b: [RowSample], options: ScrollStitcher.Options, fromTop: Bool) -> Int {
        let count = min(a.count, b.count)
        let limit = min(count, max(1, Int(Double(count) * options.maxBandFraction)))
        var confirmed = 0
        var gaps = 0
        var sawDetail = false
        for step in 0..<limit {
            let y = fromTop ? step : (count - 1 - step)
            let same = distance(a[y], b[y]) <= options.matchDistance
            let detailed = a[y].distinctive || b[y].distinctive
            if same && detailed {
                sawDetail = true
                gaps = 0
                confirmed = step + 1
            } else if same && sawDetail {
                gaps = 0
                confirmed = step + 1
            } else {
                gaps += 1
                if gaps > 2 { break }
            }
        }
        guard sawDetail, confirmed > 0 else { return 0 }
        // The band must actually end: a distinctive row just past it has to have moved.
        let look = min(6, count - confirmed)
        for step in 0..<look {
            let y = fromTop ? (confirmed + step) : (count - 1 - confirmed - step)
            guard y >= 0, y < count else { break }
            if (a[y].distinctive || b[y].distinctive) && distance(a[y], b[y]) > options.alignDistance {
                return confirmed
            }
        }
        return 0
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

