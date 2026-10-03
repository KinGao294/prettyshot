import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import PrettyShotCore

/// Frozen copy of the beautify + redaction path as it shipped in the Mac app before the shared module.
/// Pixel tests compare `BeautifyRenderer` / `Redactor` against this snapshot. Do not "fix" it to match
/// a new look — a mismatch means the shared module changed output.
enum PreRefactorSnapshot {
    struct Stop {
        var hex: UInt32
        var location: CGFloat
    }

    struct Wash {
        var hex: UInt32
        var x: CGFloat
        var y: CGFloat
        var radius: CGFloat
    }

    struct Preset {
        var key: String
        var angle: Double
        var stops: [Stop]
        var washes: [Wash]
    }

    static let presets: [Preset] = [
        Preset(key: "paper-mist", angle: 145, stops: [
            Stop(hex: 0xF7F2EA, location: 0), Stop(hex: 0xE8DFD4, location: 0.48), Stop(hex: 0xD9CFC4, location: 1),
        ], washes: []),
        Preset(key: "ink-wash", angle: 160, stops: [
            Stop(hex: 0x2A2E35, location: 0), Stop(hex: 0x4A5560, location: 0.45), Stop(hex: 0x8A9AA8, location: 1),
        ], washes: []),
        Preset(key: "soft-bloom", angle: 135, stops: [
            Stop(hex: 0xF3D5D8, location: 0), Stop(hex: 0xE8A0A8, location: 0.40), Stop(hex: 0xC9B8D4, location: 1),
        ], washes: []),
        Preset(key: "moss-quiet", angle: 150, stops: [
            Stop(hex: 0x1E2E28, location: 0), Stop(hex: 0x3D5A4C, location: 0.50), Stop(hex: 0x7EB8A8, location: 1),
        ], washes: []),
        Preset(key: "dusk-lilac", angle: 140, stops: [
            Stop(hex: 0x2B2438, location: 0), Stop(hex: 0x6B5B7A, location: 0.50), Stop(hex: 0xC4B0D4, location: 1),
        ], washes: []),
        Preset(key: "ceramic-white", angle: 180, stops: [
            Stop(hex: 0xFFFFFF, location: 0), Stop(hex: 0xF5F2EC, location: 0.60), Stop(hex: 0xE8E2D8, location: 1),
        ], washes: []),
        Preset(key: "night-ink", angle: 160, stops: [
            Stop(hex: 0x0E0F12, location: 0), Stop(hex: 0x1C1C1E, location: 0.55), Stop(hex: 0x3A3A3C, location: 1),
        ], washes: []),
        Preset(key: "citrus-fog", angle: 145, stops: [
            Stop(hex: 0xF6E7C8, location: 0), Stop(hex: 0xE8C99A, location: 0.45), Stop(hex: 0xD4B48A, location: 1),
        ], washes: []),
        Preset(key: "pastel-air", angle: 115, stops: [
            Stop(hex: 0xFDF6DF, location: 0), Stop(hex: 0xF7DDFC, location: 0.34),
            Stop(hex: 0xD6EAFE, location: 0.68), Stop(hex: 0xFEF7DA, location: 1),
        ], washes: [
            Wash(hex: 0xF7DDFC, x: 0.42, y: 0.00, radius: 0.85),
            Wash(hex: 0xD6EAFE, x: 1.00, y: 0.08, radius: 0.82),
            Wash(hex: 0xEFDFFD, x: 0.00, y: 0.42, radius: 0.78),
            Wash(hex: 0xDEEBFD, x: 0.06, y: 1.00, radius: 0.80),
            Wash(hex: 0xFDE1F8, x: 0.48, y: 1.02, radius: 0.72),
            Wash(hex: 0xFEF7DA, x: 1.00, y: 1.00, radius: 0.70),
            Wash(hex: 0xFDF5DE, x: 0.00, y: 0.00, radius: 0.58),
        ]),
    ]

    struct Region {
        var pixelate: Bool
        var rect: CGRect
    }

    static func render(
        base: CGImage,
        crop: CGRect,
        presetKey: String?,
        padding: Double,
        radius: Double,
        shadow: Double,
        scale: CGFloat,
        baseSize: CGSize? = nil
    ) -> CGImage? {
        let preset = presets.first { $0.key == presetKey }
        let pad = preset != nil ? (CGFloat(padding) * scale).rounded() : 0
        let canvasSize = CGSize(width: crop.width + pad * 2, height: crop.height + pad * 2)
        let imageRect = CGRect(x: pad, y: pad, width: crop.width, height: crop.height)
        let width = Int(canvasSize.width.rounded(.up))
        let height = Int(canvasSize.height.rounded(.up))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        context.saveGState()
        context.interpolationQuality = .high
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let imageClip: CGPath
        if let preset {
            fill(preset, rect: canvas, in: context)
            let corner = min(CGFloat(radius) * scale, imageRect.width / 2, imageRect.height / 2)
            imageClip = CGPath(roundedRect: imageRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
            if shadow > 0 {
                let metrics = shadowMetrics(amount: CGFloat(shadow) * scale, in: context)
                context.saveGState()
                context.setShadow(offset: metrics.offset, blur: metrics.blur,
                                  color: CGColor(srgbRed: 0.17, green: 0.16, blue: 0.16, alpha: 0.32))
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                drawBase(base, baseSize: baseSize, imageRect: imageRect, crop: crop, clip: imageClip, in: context)
                context.endTransparencyLayer()
                context.restoreGState()
            } else {
                drawBase(base, baseSize: baseSize, imageRect: imageRect, crop: crop, clip: imageClip, in: context)
            }
        } else {
            imageClip = CGPath(rect: imageRect, transform: nil)
            drawBase(base, baseSize: baseSize, imageRect: imageRect, crop: crop, clip: imageClip, in: context)
        }
        context.saveGState()
        context.addPath(imageClip)
        context.clip()
        context.translateBy(x: imageRect.minX - crop.minX, y: imageRect.minY - crop.minY)
        context.restoreGState()
        context.restoreGState()
        return context.makeImage()
    }

    static func redact(_ regions: [Region], image: CGImage, scale: CGFloat, geometryScale: CGFloat = 1) -> CGImage {
        let kept = regions.filter { $0.rect.width >= 4 && $0.rect.height >= 4 }
        guard !kept.isEmpty else { return image }
        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let source = CIImage(cgImage: image)
        let extent = source.extent
        var output = source
        for region in kept {
            let full = region.rect
            let r = CGRect(x: full.minX * geometryScale, y: full.minY * geometryScale,
                           width: full.width * geometryScale, height: full.height * geometryScale)
            let ciRect = CGRect(x: r.minX, y: extent.height - r.maxY, width: r.width, height: r.height)
                .intersection(extent)
            guard !ciRect.isEmpty else { continue }
            let effect: CIImage?
            if region.pixelate {
                let filter = CIFilter.pixellate()
                filter.inputImage = output.clampedToExtent()
                filter.scale = Float(max(10 * scale * geometryScale, min(ciRect.width, ciRect.height) / 8))
                filter.center = ciRect.origin
                effect = filter.outputImage
            } else {
                let filter = CIFilter.gaussianBlur()
                filter.inputImage = output.clampedToExtent()
                filter.radius = Float(max(14 * scale * geometryScale, min(ciRect.width, ciRect.height) / 10))
                effect = filter.outputImage
            }
            if let effect {
                output = effect.cropped(to: ciRect).composited(over: output)
            }
        }
        return ciContext.createCGImage(output, from: extent) ?? image
    }

    /// Historical `previewSource(for:maxSide:)` — long side only, no pixel budget.
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

    private static func drawBase(
        _ base: CGImage,
        baseSize: CGSize?,
        imageRect: CGRect,
        crop: CGRect,
        clip: CGPath,
        in context: CGContext
    ) {
        context.saveGState()
        context.addPath(clip)
        context.clip()
        let origin = CGPoint(x: 0 + imageRect.minX - crop.minX, y: 0 + imageRect.minY - crop.minY)
        let size = baseSize ?? CGSize(width: base.width, height: base.height)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(base, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
        context.restoreGState()
    }

    private static func shadowMetrics(amount: CGFloat, in context: CGContext) -> (offset: CGSize, blur: CGFloat) {
        let t = context.userSpaceToDeviceSpaceTransform
        let deviceScale = max(hypot(t.c, t.d), 0.0001)
        let down: CGFloat = t.d < 0 ? -1 : 1
        return (CGSize(width: 0, height: down * amount * 0.25 * deviceScale), amount * 0.6 * deviceScale)
    }

    private static func fill(_ preset: Preset, rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        if preset.washes.isEmpty {
            let colors = preset.stops.map { color($0.hex, alpha: 1) } as CFArray
            let locations = preset.stops.map(\.location)
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) {
                let (start, end) = endpoints(angleDegrees: preset.angle, in: rect)
                context.drawLinearGradient(gradient, start: start, end: end,
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        } else if let base = preset.stops.first {
            context.setFillColor(color(base.hex, alpha: 1))
            context.fill(rect)
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            let span = max(rect.width, rect.height)
            for wash in preset.washes {
                guard let gradient = CGGradient(
                    colorsSpace: space,
                    colors: [color(wash.hex, alpha: 1), color(wash.hex, alpha: 0.72), color(wash.hex, alpha: 0)] as CFArray,
                    locations: [0, 0.42, 1]
                ) else { continue }
                let center = CGPoint(x: rect.minX + wash.x * rect.width, y: rect.minY + wash.y * rect.height)
                context.drawRadialGradient(
                    gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: wash.radius * span,
                    options: [.drawsBeforeStartLocation]
                )
            }
        }
        context.restoreGState()
    }

    private static func endpoints(angleDegrees: Double, in rect: CGRect) -> (CGPoint, CGPoint) {
        let theta = angleDegrees * .pi / 180
        let dx = CGFloat(sin(theta))
        let dy = CGFloat(-cos(theta))
        let length = abs(rect.width * dx) + abs(rect.height * dy)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let half = length / 2
        return (
            CGPoint(x: center.x - dx * half, y: center.y - dy * half),
            CGPoint(x: center.x + dx * half, y: center.y + dy * half)
        )
    }

    private static func color(_ hex: UInt32, alpha: CGFloat) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
