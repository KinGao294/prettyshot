import CoreGraphics
import Foundation

/// Platform-neutral inputs for a beautified shot. Annotations are drawn by the caller.
public struct BeautifyInput {
    public var base: CGImage
    /// Visible part of `base`, in image pixels (y-down).
    public var crop: CGRect
    public var background: BackgroundStyle
    /// Pixels per point, so padding/radius/shadow look the same on Retina and non-Retina captures.
    public var scale: CGFloat
    /// Size `base` is drawn at, in image pixels. Set when `base` is a downscaled preview.
    public var baseSize: CGSize?

    public init(base: CGImage, crop: CGRect, background: BackgroundStyle, scale: CGFloat, baseSize: CGSize? = nil) {
        self.base = base
        self.crop = crop
        self.background = background
        self.scale = scale
        self.baseSize = baseSize
    }
}

public struct RenderLayout: Equatable {
    public let canvasSize: CGSize
    public let imageRect: CGRect
    public let crop: CGRect

    public init(canvasSize: CGSize, imageRect: CGRect, crop: CGRect) {
        self.canvasSize = canvasSize
        self.imageRect = imageRect
        self.crop = crop
    }

    /// Canvas (output pixel) point → image pixel point.
    public func imagePoint(fromCanvas p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - imageRect.minX + crop.minX, y: p.y - imageRect.minY + crop.minY)
    }

    public func canvasPoint(fromImage p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + imageRect.minX - crop.minX, y: p.y + imageRect.minY - crop.minY)
    }
}

/// Background, rounded image, and shadow. All drawing is in a y-down user space measured in output pixels.
/// The Mac editor passes AppKit annotation drawing in; iOS can pass its own.
public enum BeautifyRenderer {
    public static func layout(for input: BeautifyInput) -> RenderLayout {
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

    /// Draws the composite. `drawAnnotations` and `overlay` run in image-pixel coordinates, annotations first.
    public static func draw(
        _ input: BeautifyInput,
        in context: CGContext,
        drawAnnotations: ((CGContext) -> Void)? = nil,
        overlay: ((CGContext) -> Void)? = nil
    ) {
        let layout = BeautifyRenderer.layout(for: input)
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
        drawAnnotations?(context)
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
    public static func render(
        _ input: BeautifyInput,
        drawAnnotations: ((CGContext) -> Void)? = nil
    ) -> CGImage? {
        let layout = BeautifyRenderer.layout(for: input)
        let width = Int(layout.canvasSize.width.rounded(.up))
        let height = Int(layout.canvasSize.height.rounded(.up))
        let bytesPerRow = (width * 4 + 15) & ~15
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(input, in: context, drawAnnotations: drawAnnotations)
        return context.makeImage()
    }

    /// Draws a CGImage into a y-down context without flipping it upside down.
    public static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private static func drawBase(_ input: BeautifyInput, layout: RenderLayout, clip: CGPath, in context: CGContext) {
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
