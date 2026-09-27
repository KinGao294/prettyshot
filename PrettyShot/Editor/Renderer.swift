import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Everything needed to draw a finished shot.
struct RenderInput {
    /// Full-size source with redactions (pixelate/blur) already baked in.
    var base: CGImage
    /// Visible part of `base`, in image pixels (y-down).
    var crop: CGRect
    /// Vector annotations (redactions excluded — they live in `base`).
    var annotations: [Annotation]
    /// Beautify settings; ignored when `presetKey` is nil.
    var background: BackgroundStyle
    /// Pixels per point, so padding/radius/shadow look the same on Retina and non-Retina captures.
    var scale: CGFloat
    /// Size `base` is drawn at, in image pixels. Set when `base` is a downscaled preview (redaction drag).
    var baseSize: CGSize? = nil
}

struct RenderLayout: Equatable {
    let canvasSize: CGSize
    let imageRect: CGRect
    let crop: CGRect

    /// Canvas (output pixel) point → image pixel point.
    func imagePoint(fromCanvas p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - imageRect.minX + crop.minX, y: p.y - imageRect.minY + crop.minY)
    }

    func canvasPoint(fromImage p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + imageRect.minX - crop.minX, y: p.y + imageRect.minY - crop.minY)
    }
}

/// Single drawing path for the live editor canvas *and* the exported PNG (WYSIWYG).
/// All drawing happens in a y-down user space measured in output pixels.
enum Renderer {
    static func layout(for input: RenderInput) -> RenderLayout {
        let crop = input.crop
        let padding = input.background.preset != nil
            ? (CGFloat(input.background.padding) * input.scale).rounded()
            : 0
        return RenderLayout(
            canvasSize: CGSize(width: crop.width + padding * 2, height: crop.height + padding * 2),
            imageRect: CGRect(x: padding, y: padding, width: crop.width, height: crop.height),
            crop: crop
        )
    }

    /// Draws the composite. `overlay` (editor chrome: drafts, selection, crop mask) runs last,
    /// in image-pixel coordinates.
    static func draw(_ input: RenderInput, in context: CGContext, overlay: ((CGContext) -> Void)? = nil) {
        let layout = Renderer.layout(for: input)
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)

        context.saveGState()
        context.interpolationQuality = .high

        let imageClip: CGPath
        if let preset = input.background.preset {
            preset.fill(canvas, in: context)
            let radius = min(CGFloat(input.background.radius) * input.scale,
                             layout.imageRect.width / 2, layout.imageRect.height / 2)
            imageClip = CGPath(roundedRect: layout.imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

            if input.background.shadow > 0 {
                let metrics = shadowMetrics(amount: CGFloat(input.background.shadow) * input.scale, in: context)
                context.saveGState()
                context.setShadow(offset: metrics.offset, blur: metrics.blur,
                                  color: CGColor(srgbRed: 0.17, green: 0.16, blue: 0.16, alpha: 0.32))
                // Shadow the composited layer, so transparent window corners cast a correct shadow.
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                drawBase(input, layout: layout, clip: imageClip, in: context)
                context.endTransparencyLayer()
                context.restoreGState()
            } else {
                drawBase(input, layout: layout, clip: imageClip, in: context)
            }
        } else {
            imageClip = CGPath(rect: layout.imageRect, transform: nil)
            drawBase(input, layout: layout, clip: imageClip, in: context)
        }

        context.saveGState()
        context.addPath(imageClip)
        context.clip()
        context.translateBy(x: layout.imageRect.minX - input.crop.minX, y: layout.imageRect.minY - input.crop.minY)
        for annotation in input.annotations {
            AnnotationRenderer.draw(annotation, in: context)
        }
        context.restoreGState()

        if let overlay {
            context.saveGState()
            context.translateBy(x: layout.imageRect.minX - input.crop.minX, y: layout.imageRect.minY - input.crop.minY)
            overlay(context)
            context.restoreGState()
        }

        context.restoreGState()
    }

    /// Renders to a new sRGB bitmap at output resolution.
    static func render(_ input: RenderInput) -> CGImage? {
        let layout = Renderer.layout(for: input)
        let width = Int(layout.canvasSize.width.rounded(.up))
        let height = Int(layout.canvasSize.height.rounded(.up))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(input, in: context)
        return context.makeImage()
    }

    /// Draws a CGImage into a y-down context without flipping it upside down.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func drawBase(_ input: RenderInput, layout: RenderLayout, clip: CGPath, in context: CGContext) {
        context.saveGState()
        context.addPath(clip)
        context.clip()
        let origin = layout.canvasPoint(fromImage: .zero)
        let size = input.baseSize ?? CGSize(width: input.base.width, height: input.base.height)
        drawImage(input.base, in: CGRect(origin: origin, size: size), context: context)
        context.restoreGState()
    }

    /// CG shadows are specified in device space (unaffected by the CTM), so derive a consistent
    /// "downwards, proportional" shadow for both the zoomed canvas and the 1:1 bitmap export.
    private static func shadowMetrics(amount: CGFloat, in context: CGContext) -> (offset: CGSize, blur: CGFloat) {
        let t = context.userSpaceToDeviceSpaceTransform
        let deviceScale = max(hypot(t.c, t.d), 0.0001)
        let down: CGFloat = t.d < 0 ? -1 : 1
        return (CGSize(width: 0, height: down * amount * 0.25 * deviceScale), amount * 0.6 * deviceScale)
    }
}

// MARK: - Annotations

enum AnnotationRenderer {
    static func draw(_ annotation: Annotation, in context: CGContext) {
        switch annotation.kind {
        case .arrow: drawArrow(annotation, in: context)
        case .rectangle: drawRectangle(annotation, in: context)
        case .ellipse: drawEllipse(annotation, in: context)
        case .text: drawText(annotation, in: context)
        case .counter: drawCounter(annotation, in: context)
        case .pixelate, .blur: break // baked into the base image by Redactor
        }
    }

    static func drawArrow(_ a: Annotation, in context: CGContext) {
        let dx = a.end.x - a.start.x
        let dy = a.end.y - a.start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length
        let uy = dy / length
        let headLength = min(max(a.lineWidth * 3.8, 10), length * 0.6)
        let halfWidth = headLength * 0.52
        let base = CGPoint(x: a.end.x - ux * headLength, y: a.end.y - uy * headLength)

        context.saveGState()
        context.setStrokeColor(a.color.cgColor)
        context.setFillColor(a.color.cgColor)
        context.setLineWidth(a.lineWidth)
        context.setLineCap(.round)
        context.move(to: a.start)
        context.addLine(to: CGPoint(x: base.x + ux * a.lineWidth * 0.5, y: base.y + uy * a.lineWidth * 0.5))
        context.strokePath()

        context.setLineJoin(.round)
        context.move(to: a.end)
        context.addLine(to: CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth))
        context.addLine(to: CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth))
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    static func drawRectangle(_ a: Annotation, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(a.color.cgColor)
        context.setLineWidth(a.lineWidth)
        context.setLineJoin(.round)
        let radius = min(a.lineWidth * 1.5, a.rect.width / 2, a.rect.height / 2)
        context.addPath(CGPath(roundedRect: a.rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
        context.restoreGState()
    }

    static func drawEllipse(_ a: Annotation, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(a.color.cgColor)
        context.setLineWidth(a.lineWidth)
        context.strokeEllipse(in: a.rect)
        context.restoreGState()
    }

    static func textAttributes(for a: Annotation) -> [NSAttributedString.Key: Any] {
        let base = NSFont.systemFont(ofSize: a.fontSize, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: a.fontSize) } ?? base
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(a.color.isLight ? 0.45 : 0.18)
        shadow.shadowBlurRadius = max(1, a.fontSize * 0.08)
        shadow.shadowOffset = .zero
        return [.font: font, .foregroundColor: a.color.nsColor, .shadow: shadow]
    }

    static func textSize(for a: Annotation) -> CGSize {
        let string = a.text.isEmpty ? " " : a.text
        return NSAttributedString(string: string, attributes: textAttributes(for: a)).size()
    }

    static func drawText(_ a: Annotation, in context: CGContext) {
        guard !a.text.isEmpty else { return }
        withAppKitContext(context) {
            NSAttributedString(string: a.text, attributes: textAttributes(for: a)).draw(at: a.start)
        }
    }

    static func drawCounter(_ a: Annotation, in context: CGContext) {
        let r = a.counterRadius
        let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        context.saveGState()
        context.setFillColor(a.color.cgColor)
        context.fillEllipse(in: circle)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
        context.setLineWidth(max(1.5, r * 0.12))
        context.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
        context.restoreGState()

        let base = NSFont.systemFont(ofSize: r * 1.1, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: r * 1.1) } ?? base
        let label = NSAttributedString(string: "\(a.number)", attributes: [
            .font: font,
            .foregroundColor: a.color.isLight ? NSColor(hex: 0x2C2A28) : NSColor.white,
        ])
        let size = label.size()
        withAppKitContext(context) {
            label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2))
        }
    }

    /// Runs AppKit text drawing against a y-down CGContext.
    private static func withAppKitContext(_ context: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}

// MARK: - Redaction

/// Bakes pixelate / blur regions into a copy of the source (destructive in the export —
/// the original pixels under a redaction never reach the clipboard or PNG).
enum Redactor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// `geometryScale` maps annotation geometry (full-size image pixels) onto `image`, which may be a
    /// downscaled preview used while a redaction is being dragged.
    static func apply(_ redactions: [Annotation], to image: CGImage, scale: CGFloat, geometryScale: CGFloat = 1) -> CGImage {
        let regions = redactions.filter { $0.kind.isRedaction && $0.isMeaningful }
        guard !regions.isEmpty else { return image }

        let source = CIImage(cgImage: image)
        let extent = source.extent
        var output = source

        for region in regions {
            // Image pixels (y-down) → Core Image (y-up).
            let full = region.rect
            let r = CGRect(x: full.minX * geometryScale, y: full.minY * geometryScale,
                           width: full.width * geometryScale, height: full.height * geometryScale)
            let ciRect = CGRect(x: r.minX, y: extent.height - r.maxY, width: r.width, height: r.height)
                .intersection(extent)
            guard !ciRect.isEmpty else { continue }

            let effect: CIImage?
            switch region.kind {
            case .pixelate:
                let filter = CIFilter.pixellate()
                filter.inputImage = output.clampedToExtent()
                filter.scale = Float(max(10 * scale * geometryScale, min(ciRect.width, ciRect.height) / 8))
                filter.center = ciRect.origin
                effect = filter.outputImage
            case .blur:
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = output.clampedToExtent()
                filter.radius = Float(max(14 * scale * geometryScale, min(ciRect.width, ciRect.height) / 10))
                effect = filter.outputImage
            default:
                effect = nil
            }
            if let effect {
                output = effect.cropped(to: ciRect).composited(over: output)
            }
        }
        return context.createCGImage(output, from: extent) ?? image
    }

    /// Downscaled copy of `image` (long side ≤ `maxSide`) for cheap live redaction previews.
    static func previewSource(for image: CGImage, maxSide: Int = 1280) -> (image: CGImage, factor: CGFloat)? {
        let longSide = max(image.width, image.height)
        guard longSide > maxSide else { return nil }
        let factor = CGFloat(maxSide) / CGFloat(longSide)
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
}
