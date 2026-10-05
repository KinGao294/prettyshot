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
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: NSNull(),
    ])

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
            // The only full-size buffer. The source is drawn into it once, and Core Image
            // only renders the redacted area back over it. A full-extent Core Image render
            // would add its own full-size result and intermediates beside this copy.
            let owned = OwnedBitmap(byteCount: byteCount)
            guard let canvas = CGContext(
                data: owned.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return image }
            canvas.interpolationQuality = .none
            canvas.setBlendMode(.copy)
            canvas.draw(image, in: extent)

            // One patch per group of marks whose filter reach overlaps. Marks far apart (a name at
            // the top, a number at the bottom) never make a patch that spans the image between them.
            for group in groups {
                autoreleasepool {
                    redactPatch(group.members.map { planned[$0] }, roi: group.roi, in: owned,
                                bytesPerRow: bytesPerRow, imageHeight: height, space: space)
                    context.clearCaches()
                }
            }
            canvas.flush()

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

    /// Runs the redaction filters over `roi` only and writes the result straight back into `bitmap`.
    /// `roi` covers every redacted rect plus the distance its filter reads, so clamping at the patch
    /// edge does not reach the redacted pixels. The patch is copied out of `bitmap` first, so Core
    /// Image never reads what is being written. Full-ROI (not tiled): CIGaussianBlur needs one
    /// contiguous apron for byte-identity vs PreRefactor / main. Render only the mark writeBounds.
    private static func redactPatch(
        _ planned: [(kind: RedactionKind, rect: CGRect, amount: Float)],
        roi: CGRect,
        in bitmap: OwnedBitmap,
        bytesPerRow: Int,
        imageHeight: Int,
        space: CGColorSpace
    ) {
        let patchWidth = Int(roi.width)
        let patchHeight = Int(roi.height)
        guard patchWidth > 0, patchHeight > 0 else { return }
        let patchBytesPerRow = patchWidth * 4
        let top = imageHeight - Int(roi.maxY)
        let left = Int(roi.minX)
        // Filled in place and handed over toll-free: bridging a Swift `Data` may copy the patch again.
        guard let bytes = NSMutableData(length: patchBytesPerRow * patchHeight) else { return }
        let base = bytes.mutableBytes
        for row in 0..<patchHeight {
            let from = bitmap.baseAddress + (top + row) * bytesPerRow + left * 4
            (base + row * patchBytesPerRow).copyMemory(from: from, byteCount: patchBytesPerRow)
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let patch = CGImage(
                width: patchWidth, height: patchHeight,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: patchBytesPerRow,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return }

        let source = CIImage(cgImage: patch)
            .transformed(by: CGAffineTransform(translationX: roi.minX, y: roi.minY))
        var output = source
        for region in planned {
            let effect: CIImage?
            switch region.kind {
            case .pixelate:
                let filter = CIFilter.pixellate()
                filter.inputImage = output.clampedToExtent()
                filter.scale = region.amount
                filter.center = region.rect.origin
                effect = filter.outputImage
            case .blur:
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = output.clampedToExtent()
                filter.radius = region.amount
                effect = filter.outputImage
            }
            if let effect {
                output = effect.cropped(to: region.rect).composited(over: output)
            }
        }
        // Only mark pixels change; apron was input context and stays as drawn on the canvas.
        var writeBounds = CGRect.null
        for region in planned {
            writeBounds = writeBounds.union(region.rect)
        }
        writeBounds = writeBounds.integral.intersection(roi)
        guard !writeBounds.isEmpty else { return }
        let outTop = imageHeight - Int(writeBounds.maxY)
        let outLeft = Int(writeBounds.minX)
        let target = bitmap.baseAddress + outTop * bytesPerRow + outLeft * 4
        context.render(
            output, toBitmap: target, rowBytes: bytesPerRow,
            bounds: writeBounds, format: .RGBA8, colorSpace: space
        )
        withExtendedLifetime(bytes) {}
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
