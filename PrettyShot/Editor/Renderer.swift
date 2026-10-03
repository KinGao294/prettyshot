import AppKit
import PrettyShotCore

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

    var beautifyInput: BeautifyInput {
        BeautifyInput(base: base, crop: crop, background: background, scale: scale, baseSize: baseSize)
    }
}

/// Single drawing path for the live editor canvas *and* the exported PNG (WYSIWYG).
/// Background, clip, and shadow come from `BeautifyRenderer`; annotations stay here because text uses AppKit.
enum Renderer {
    static func layout(for input: RenderInput) -> RenderLayout {
        BeautifyRenderer.layout(for: input.beautifyInput)
    }

    /// Draws the composite. `overlay` (editor chrome: drafts, selection, crop mask) runs last,
    /// in image-pixel coordinates.
    static func draw(_ input: RenderInput, in context: CGContext, overlay: ((CGContext) -> Void)? = nil) {
        BeautifyRenderer.draw(input.beautifyInput, in: context, drawAnnotations: { context in
            for annotation in input.annotations {
                AnnotationRenderer.draw(annotation, in: context)
            }
        }, overlay: overlay)
    }

    /// Renders to a new sRGB bitmap at output resolution.
    static func render(_ input: RenderInput) -> CGImage? {
        BeautifyRenderer.render(input.beautifyInput, drawAnnotations: { context in
            for annotation in input.annotations {
                AnnotationRenderer.draw(annotation, in: context)
            }
        })
    }

    /// Draws a CGImage into a y-down context without flipping it upside down.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        BeautifyRenderer.drawImage(image, in: rect, context: context)
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
