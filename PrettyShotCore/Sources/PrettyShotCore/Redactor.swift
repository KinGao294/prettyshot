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
                // Must stay amount*4+2: smaller reach changes gaussian edge pixels vs main/PreRefactor.
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

    /// Runs the redaction filters over `roi` only and writes the redacted rects back into `bitmap`.
    /// `roi` covers every redacted rect plus the distance its filter reads, so clamping at the patch
    /// edge does not reach the redacted pixels.
    ///
    /// Marks in a group are applied one at a time (same order as a single full-ROI pass). Each mark
    /// is processed in vertical strips so the read-apron scratch stays bounded; strip outputs land
    /// in a mark-sized side buffer and are blitted only after every strip finishes, so later strips
    /// still read pristine canvas pixels in their aprons — byte-identical to an untiled pass (and to
    /// PreRefactor / main). Amount and reach formulas match main.
    private static func redactPatch(
        _ planned: [(kind: RedactionKind, rect: CGRect, amount: Float)],
        roi: CGRect,
        in bitmap: OwnedBitmap,
        bytesPerRow: Int,
        imageHeight: Int,
        space: CGColorSpace
    ) {
        for region in planned {
            redactMark(region, roi: roi, in: bitmap, bytesPerRow: bytesPerRow,
                       imageHeight: imageHeight, space: space)
            context.clearCaches()
        }
    }

    private static func redactMark(
        _ region: (kind: RedactionKind, rect: CGRect, amount: Float),
        roi: CGRect,
        in bitmap: OwnedBitmap,
        bytesPerRow: Int,
        imageHeight: Int,
        space: CGColorSpace
    ) {
        let writeBounds = region.rect.integral.intersection(roi)
        guard !writeBounds.isEmpty else { return }

        let reach: CGFloat
        switch region.kind {
        case .pixelate: reach = CGFloat(region.amount) + 2
        case .blur: reach = CGFloat(region.amount) * 4 + 2
        }
        let padX = reach
        let padY = reach

        let outWidth = Int(writeBounds.width)
        let outHeight = Int(writeBounds.height)
        let outBytesPerRow = outWidth * 4
        guard let outBytes = NSMutableData(length: outBytesPerRow * outHeight) else { return }

        // Cap read-apron scratch. Floor write width at 1px — apron still dominates for large blur.
        let maxScratch = 256 * 1024
        let writeHeight = outHeight
        let apronHeight = min(Int(roi.height), writeHeight + Int(ceil(padY)) * 2)
        let bytesPerWriteCol = max(1, apronHeight) * 4
        let maxWriteW = max(1, (maxScratch / bytesPerWriteCol) - Int(ceil(padX)) * 2)
        var col = Int(writeBounds.minX)
        let colEnd = Int(writeBounds.maxX)
        let rowMin = writeBounds.minY
        let rowH = writeBounds.height
        while col < colEnd {
            let sliceW = min(maxWriteW, colEnd - col)
            let slice = CGRect(x: CGFloat(col), y: rowMin, width: CGFloat(sliceW), height: rowH)
            col += sliceW
            autoreleasepool {
                redactStrip(region, write: slice, writeBounds: writeBounds, outBytes: outBytes,
                            outBytesPerRow: outBytesPerRow, roi: roi, padX: padX, padY: padY,
                            in: bitmap, bytesPerRow: bytesPerRow, imageHeight: imageHeight, space: space)
                context.clearCaches()
            }
        }

        // Blit the finished mark once — canvas was pristine for every strip read above.
        let outTop = imageHeight - Int(writeBounds.maxY)
        let outLeft = Int(writeBounds.minX)
        let outBase = outBytes.mutableBytes
        for row in 0..<outHeight {
            let dest = bitmap.baseAddress + (outTop + row) * bytesPerRow + outLeft * 4
            dest.copyMemory(from: outBase + row * outBytesPerRow, byteCount: outBytesPerRow)
        }
    }

    /// One vertical strip: copy read apron from canvas → filter → write into the mark side buffer.
    private static func redactStrip(
        _ region: (kind: RedactionKind, rect: CGRect, amount: Float),
        write: CGRect,
        writeBounds: CGRect,
        outBytes: NSMutableData,
        outBytesPerRow: Int,
        roi: CGRect,
        padX: CGFloat,
        padY: CGFloat,
        in bitmap: OwnedBitmap,
        bytesPerRow: Int,
        imageHeight: Int,
        space: CGColorSpace
    ) {
        let read = write.insetBy(dx: -padX, dy: -padY).integral.intersection(roi)
        let patchWidth = Int(read.width)
        let patchHeight = Int(read.height)
        guard patchWidth > 0, patchHeight > 0 else { return }
        let patchBytesPerRow = patchWidth * 4
        let top = imageHeight - Int(read.maxY)
        let left = Int(read.minX)
        guard let bytes = NSMutableData(length: patchBytesPerRow * patchHeight) else { return }
        let base = bytes.mutableBytes
        for row in 0..<patchHeight {
            let from = bitmap.baseAddress + (top + row) * bytesPerRow + left * 4
            (base + row * patchBytesPerRow).copyMemory(from: from, byteCount: patchBytesPerRow)
        }
        // CIImage(bitmapData:) — skip CGImage wrapper so we do not hold a second decoded copy.
        let bitmapData = Data(bytesNoCopy: base, count: patchBytesPerRow * patchHeight, deallocator: .none)
        let source = CIImage(
            bitmapData: bitmapData,
            bytesPerRow: patchBytesPerRow,
            size: CGSize(width: patchWidth, height: patchHeight),
            format: .RGBA8,
            colorSpace: space
        ).transformed(by: CGAffineTransform(translationX: read.minX, y: read.minY))

        let effect: CIImage?
        switch region.kind {
        case .pixelate:
            let filter = CIFilter.pixellate()
            filter.inputImage = source.clampedToExtent()
            filter.scale = region.amount
            filter.center = region.rect.origin
            effect = filter.outputImage
        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = source.clampedToExtent()
            filter.radius = region.amount
            effect = filter.outputImage
        }
        guard let effect else { return }
        let markSlice = region.rect.intersection(write)
        guard !markSlice.isEmpty else { return }
        let output = effect.cropped(to: markSlice)

        // Local coords inside the mark side buffer.
        let local = CGRect(
            x: write.minX - writeBounds.minX,
            y: write.minY - writeBounds.minY,
            width: write.width,
            height: write.height
        )
        let outPtr = outBytes.mutableBytes + Int(local.minY) * outBytesPerRow + Int(local.minX) * 4
        context.render(
            output, toBitmap: outPtr, rowBytes: outBytesPerRow,
            bounds: write, format: .RGBA8, colorSpace: space
        )
        // Keep `bytes` alive for the bytesNoCopy CIImage through render.
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
