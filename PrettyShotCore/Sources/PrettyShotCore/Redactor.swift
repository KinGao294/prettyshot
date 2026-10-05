import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum RedactionKind: Equatable {
    case pixelate
    case blur
}

/// A region the redactor can bake. The Mac app's `Annotation` conforms; iOS can pass its own marks.
public protocol Redactable {
    var redactionKind: RedactionKind? { get }
    /// Image pixels, origin top-left, y down. Same rect `Annotation.rect` uses.
    var redactionRect: CGRect { get }
    /// Pixelate/blur marks smaller than 4×4 are dropped, matching `Annotation.isMeaningful`.
    var isMeaningfulRedaction: Bool { get }
}

/// Bakes pixelate / blur regions into a copy of the source (destructive in the export —
/// the original pixels under a redaction never reach the clipboard or PNG).
public enum Redactor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// `geometryScale` maps annotation geometry (full-size image pixels) onto `image`, which may be a
    /// downscaled preview used while a redaction is being dragged.
    /// Marks that are not a meaningful pixelate/blur are ignored. With none left, `image` is returned as-is.
    public static func apply<S: Sequence>(
        _ redactions: S,
        to image: CGImage,
        scale: CGFloat,
        geometryScale: CGFloat = 1
    ) -> CGImage where S.Element: Redactable {
        var regions: [(kind: RedactionKind, rect: CGRect)] = []
        for mark in redactions {
            guard let kind = mark.redactionKind, mark.isMeaningfulRedaction else { continue }
            regions.append((kind, mark.redactionRect))
        }
        guard !regions.isEmpty else { return image }

        let width = image.width
        let height = image.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // Core Image y-up rects, plus how far each filter reads past its rect.
        var planned: [(kind: RedactionKind, rect: CGRect, amount: Float)] = []
        var reaches: [CGRect] = []
        for region in regions {
            // Image pixels (y-down) → Core Image (y-up).
            let full = region.rect
            let r = CGRect(x: full.minX * geometryScale, y: full.minY * geometryScale,
                           width: full.width * geometryScale, height: full.height * geometryScale)
            let ciRect = CGRect(x: r.minX, y: extent.height - r.maxY, width: r.width, height: r.height)
                .intersection(extent)
            guard !ciRect.isEmpty else { continue }
            let amount: Float
            let reach: CGFloat
            switch region.kind {
            case .pixelate:
                amount = Float(max(10 * scale * geometryScale, min(ciRect.width, ciRect.height) / 8))
                reach = CGFloat(amount) + 2
            case .blur:
                amount = Float(max(14 * scale * geometryScale, min(ciRect.width, ciRect.height) / 10))
                reach = CGFloat(amount) * 4 + 2
            }
            planned.append((region.kind, ciRect, amount))
            reaches.append(ciRect.insetBy(dx: -reach, dy: -reach).integral.intersection(extent))
        }
        let groups = patchGroups(reaches)

        return autoreleasepool { () -> CGImage in
            let bytesPerRow = (width * 4 + 15) & ~15
            let byteCount = bytesPerRow * height
            guard width > 0, height > 0, byteCount > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return image }

            // Phase 1, before the full-size buffer exists: run Core Image on each patch and keep only
            // the bytes it changed. Core Image's patch copies, intermediates and kernel set-up then
            // peak on top of the source alone, not on top of the source plus a full-size canvas.
            // One patch per group of marks whose filter reach overlaps. Marks far apart (a name at
            // the top, a number at the bottom) never make a patch that spans the image between them.
            // Groups' patches are disjoint, so no patch reads pixels another patch writes.
            var patches: [RedactedPatch] = []
            for group in groups {
                autoreleasepool {
                    if let patch = redactPatch(group.members.map { planned[$0] }, roi: group.roi,
                                               from: image, imageHeight: height, space: space) {
                        patches.append(patch)
                    }
                    context.clearCaches()
                }
            }

            // Phase 2: the only full-size buffer. The source is drawn into it once, then each patch's
            // changed bytes are copied over it. A full-extent Core Image render would add its own
            // full-size result and intermediates beside this copy.
            let owned = OwnedBitmap(byteCount: byteCount)
            guard let canvas = CGContext(
                data: owned.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return image }
            canvas.interpolationQuality = .none
            canvas.setBlendMode(.copy)
            canvas.draw(image, in: extent)
            canvas.flush()
            for patch in patches {
                patch.write(into: owned, bytesPerRow: bytesPerRow)
            }
            patches.removeAll()

            let info = Unmanaged.passRetained(owned).toOpaque()
            guard let provider = CGDataProvider(
                dataInfo: info, data: owned.baseAddress, size: byteCount,
                releaseData: { info, _, _ in
                    guard let info else { return }
                    Unmanaged<OwnedBitmap>.fromOpaque(info).takeRetainedValue()
                }
            ) else {
                Unmanaged<OwnedBitmap>.fromOpaque(info).takeRetainedValue()
                return image
            }
            guard let detached = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            ) else { return image }
            return detached
        }
    }

    /// Groups marks whose reach rects overlap, directly or through other marks, so the groups' patches
    /// are disjoint. Overlapping marks stay together and keep their order, because a later mark filters
    /// the earlier one's output.
    private static func patchGroups(_ reaches: [CGRect]) -> [(roi: CGRect, members: [Int])] {
        var groups: [(roi: CGRect, members: [Int])] = []
        for (index, reach) in reaches.enumerated() where !reach.isEmpty {
            var roi = reach
            var members = [index]
            var merged = true
            while merged {
                merged = false
                if let hit = groups.firstIndex(where: { $0.roi.intersects(roi) }) {
                    roi = roi.union(groups[hit].roi)
                    members += groups[hit].members
                    groups.remove(at: hit)
                    merged = true
                }
            }
            groups.append((roi, members.sorted()))
        }
        return groups
    }

    /// The bytes one patch changed: RGBA8 premultiplied sRGB rows, `width` × `height` pixels, whose
    /// top-left pixel sits at (`left`, `top`) in the image (y down).
    private struct RedactedPatch {
        let left: Int
        let top: Int
        let width: Int
        let height: Int
        let bytes: NSMutableData

        func write(into bitmap: OwnedBitmap, bytesPerRow: Int) {
            let rowBytes = width * 4
            let base = UnsafeRawPointer(bytes.mutableBytes)
            for row in 0..<height {
                let dest = bitmap.baseAddress + (top + row) * bytesPerRow + left * 4
                dest.copyMemory(from: base + row * rowBytes, byteCount: rowBytes)
            }
        }
    }

    /// Runs the redaction filters over `roi` only and returns the pixels that differ from the source.
    /// `roi` covers every redacted rect plus the distance its filter reads, so clamping at the patch
    /// edge does not reach the redacted pixels.
    ///
    /// Byte-identical to the canvas path it replaces (main): the patch is drawn from `image` with the
    /// same CG call, format and colour space the full-size canvas uses, shifted by the integral ROI
    /// origin, so it holds the same bytes main copied out of the canvas. Core Image then runs the same
    /// graph and renders the same `roi` bounds main rendered. Only the bounding box of pixels whose
    /// rendered bytes differ from the drawn bytes is kept; every pixel outside it is already equal to
    /// what the canvas holds once the source is drawn into it.
    private static func redactPatch(
        _ planned: [(kind: RedactionKind, rect: CGRect, amount: Float)],
        roi: CGRect,
        from image: CGImage,
        imageHeight: Int,
        space: CGColorSpace
    ) -> RedactedPatch? {
        let patchWidth = Int(roi.width)
        let patchHeight = Int(roi.height)
        guard patchWidth > 0, patchHeight > 0 else { return nil }
        let patchBytesPerRow = patchWidth * 4
        let top = imageHeight - Int(roi.maxY)
        let left = Int(roi.minX)
        // Filled in place and handed over toll-free: bridging a Swift `Data` may copy the patch again.
        guard let input = NSMutableData(length: patchBytesPerRow * patchHeight),
              let drawn = CGContext(
                data: input.mutableBytes, width: patchWidth, height: patchHeight,
                bitsPerComponent: 8, bytesPerRow: patchBytesPerRow,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        drawn.interpolationQuality = .none
        drawn.setBlendMode(.copy)
        drawn.draw(image, in: CGRect(x: -roi.minX, y: -roi.minY,
                                     width: CGFloat(image.width), height: CGFloat(image.height)))
        drawn.flush()

        guard let output = NSMutableData(length: patchBytesPerRow * patchHeight) else { return nil }
        // Main left the canvas untouched when the patch image could not be built; so does this.
        var rendered = false
        autoreleasepool {
            guard let provider = CGDataProvider(data: input as CFData),
                  let patch = CGImage(
                    width: patchWidth, height: patchHeight,
                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: patchBytesPerRow,
                    space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                  ) else { return }

            let source = CIImage(cgImage: patch)
                .transformed(by: CGAffineTransform(translationX: roi.minX, y: roi.minY))
            var result = source
            for region in planned {
                let effect: CIImage?
                switch region.kind {
                case .pixelate:
                    let filter = CIFilter.pixellate()
                    filter.inputImage = result.clampedToExtent()
                    filter.scale = region.amount
                    filter.center = region.rect.origin
                    effect = filter.outputImage
                case .blur:
                    let filter = CIFilter.gaussianBlur()
                    filter.inputImage = result.clampedToExtent()
                    filter.radius = region.amount
                    effect = filter.outputImage
                }
                if let effect {
                    result = effect.cropped(to: region.rect).composited(over: result)
                }
            }
            // Same bounds main rendered; Core Image writes the top row of `roi` first.
            context.render(result, toBitmap: output.mutableBytes, rowBytes: patchBytesPerRow,
                           bounds: roi, format: .RGBA8, colorSpace: space)
            rendered = true
        }
        guard rendered else { return nil }

        // Bounding box of the pixels the render changed.
        let before = UnsafeRawPointer(input.mutableBytes)
        let after = UnsafeRawPointer(output.mutableBytes)
        var minRow = patchHeight, maxRow = -1, minCol = patchWidth, maxCol = -1
        for row in 0..<patchHeight {
            let a = before + row * patchBytesPerRow
            let b = after + row * patchBytesPerRow
            guard memcmp(a, b, patchBytesPerRow) != 0 else { continue }
            minRow = min(minRow, row)
            maxRow = row
            let pa = a.assumingMemoryBound(to: UInt32.self)
            let pb = b.assumingMemoryBound(to: UInt32.self)
            var first = 0
            while first < patchWidth, pa[first] == pb[first] { first += 1 }
            var last = patchWidth - 1
            while last > first, pa[last] == pb[last] { last -= 1 }
            minCol = min(minCol, first)
            maxCol = max(maxCol, last)
        }
        guard maxRow >= 0, maxCol >= minCol else { return nil }
        let keptWidth = maxCol - minCol + 1
        let keptHeight = maxRow - minRow + 1
        let keptRowBytes = keptWidth * 4
        guard let kept = NSMutableData(length: keptRowBytes * keptHeight) else { return nil }
        for row in 0..<keptHeight {
            (kept.mutableBytes + row * keptRowBytes).copyMemory(
                from: after + (minRow + row) * patchBytesPerRow + minCol * 4, byteCount: keptRowBytes)
        }
        return RedactedPatch(left: left + minCol, top: top + minRow,
                             width: keptWidth, height: keptHeight, bytes: kept)
    }

    /// Downscaled copy of `image` for cheap live previews.
    /// Returns nil when the image already fits in `maxSide` and `maxPixels`, so ordinary screenshots
    /// keep their full bitmap. `factor` maps full-image annotation geometry onto the preview.
    /// The default `maxPixels` leaves the historical long-side-only behaviour (`maxSide` 1280) unchanged.
    public static func previewSource(
        for image: CGImage,
        maxSide: Int = 1280,
        maxPixels: Int = Int.max
    ) -> (image: CGImage, factor: CGFloat)? {
        let longSide = max(image.width, image.height)
        let pixels = Int64(image.width) * Int64(image.height)
        guard longSide > maxSide || pixels > Int64(maxPixels) else { return nil }
        var factor = CGFloat(1)
        if longSide > maxSide {
            factor = min(factor, CGFloat(maxSide) / CGFloat(longSide))
        }
        if pixels > Int64(maxPixels) {
            factor = min(factor, (CGFloat(maxPixels) / CGFloat(pixels)).squareRoot())
        }
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return (scaled, CGFloat(width) / CGFloat(image.width))
    }

    /// On-screen stand-in for a very tall capture. Ordinary screenshots (long side ≤ 4096 and
    /// under ~12 megapixels) return nil and the editor keeps drawing the original.
    public static func displaySource(for image: CGImage) -> (image: CGImage, factor: CGFloat)? {
        let longSide = max(image.width, image.height)
        let pixels = Int64(image.width) * Int64(image.height)
        guard longSide > 4096 || pixels > 12_000_000 else { return nil }
        return previewSource(for: image, maxSide: 4096, maxPixels: 2_000_000)
    }
}
