import CoreGraphics
import Foundation

/// Paper Bloom backgrounds and beautify settings. CoreGraphics only, so macOS and iOS draw the same fill.
public struct GradientStop: Hashable {
    public let hex: UInt32
    public let location: CGFloat

    public init(hex: UInt32, location: CGFloat) {
        self.hex = hex
        self.location = location
    }

    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A soft color bloom. Position is in the fill rect (y grows downward); radius is a fraction of the longer side.
public struct RadialWash: Hashable {
    public let hex: UInt32
    public let x: CGFloat
    public let y: CGFloat
    public let radius: CGFloat

    public init(hex: UInt32, x: CGFloat, y: CGFloat, radius: CGFloat) {
        self.hex = hex
        self.x = x
        self.y = y
        self.radius = radius
    }

    public func cgColor(alpha: CGFloat) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Paper Bloom backgrounds. Linear presets match DESIGN §3.3; `pastel-air` is a corner-bloom wash.
public struct BackgroundPreset: Identifiable, Hashable {
    public let key: String
    public let name: String
    public let localizedName: String
    /// CSS `linear-gradient` angle in degrees (0 = towards top, 90 = towards right).
    public let angle: Double
    public let stops: [GradientStop]
    /// Light presets get dark swatch labels.
    public let isLight: Bool
    /// When set, these blooms are painted over `stops.first` instead of the linear gradient.
    public let washes: [RadialWash]

    public var id: String { key }

    public init(key: String, name: String, localizedName: String, angle: Double, stops: [GradientStop], isLight: Bool, washes: [RadialWash] = []) {
        self.key = key
        self.name = name
        self.localizedName = localizedName
        self.angle = angle
        self.stops = stops
        self.isLight = isLight
        self.washes = washes
    }

    public static let all: [BackgroundPreset] = [
        BackgroundPreset(key: "paper-mist", name: "Paper Mist", localizedName: "纸雾", angle: 145,
                         stops: [.init(hex: 0xF7F2EA, location: 0), .init(hex: 0xE8DFD4, location: 0.48), .init(hex: 0xD9CFC4, location: 1)],
                         isLight: true),
        BackgroundPreset(key: "ink-wash", name: "Ink Wash", localizedName: "墨洗", angle: 160,
                         stops: [.init(hex: 0x2A2E35, location: 0), .init(hex: 0x4A5560, location: 0.45), .init(hex: 0x8A9AA8, location: 1)],
                         isLight: false),
        BackgroundPreset(key: "soft-bloom", name: "Soft Bloom", localizedName: "柔瓣", angle: 135,
                         stops: [.init(hex: 0xF3D5D8, location: 0), .init(hex: 0xE8A0A8, location: 0.40), .init(hex: 0xC9B8D4, location: 1)],
                         isLight: false),
        BackgroundPreset(key: "moss-quiet", name: "Moss Quiet", localizedName: "苔静", angle: 150,
                         stops: [.init(hex: 0x1E2E28, location: 0), .init(hex: 0x3D5A4C, location: 0.50), .init(hex: 0x7EB8A8, location: 1)],
                         isLight: false),
        BackgroundPreset(key: "dusk-lilac", name: "Dusk Lilac", localizedName: "暮紫", angle: 140,
                         stops: [.init(hex: 0x2B2438, location: 0), .init(hex: 0x6B5B7A, location: 0.50), .init(hex: 0xC4B0D4, location: 1)],
                         isLight: false),
        BackgroundPreset(key: "ceramic-white", name: "Ceramic White", localizedName: "瓷白", angle: 180,
                         stops: [.init(hex: 0xFFFFFF, location: 0), .init(hex: 0xF5F2EC, location: 0.60), .init(hex: 0xE8E2D8, location: 1)],
                         isLight: true),
        BackgroundPreset(key: "night-ink", name: "Night Ink", localizedName: "夜墨", angle: 160,
                         stops: [.init(hex: 0x0E0F12, location: 0), .init(hex: 0x1C1C1E, location: 0.55), .init(hex: 0x3A3A3C, location: 1)],
                         isLight: false),
        BackgroundPreset(key: "citrus-fog", name: "Citrus Fog", localizedName: "柑雾", angle: 145,
                         stops: [.init(hex: 0xF6E7C8, location: 0), .init(hex: 0xE8C99A, location: 0.45), .init(hex: 0xD4B48A, location: 1)],
                         isLight: true),
        // Cream corners, pink at the top and bottom, sky and lilac along the sides.
        BackgroundPreset(key: "pastel-air", name: "Pastel Air", localizedName: "彩霭", angle: 115,
                         stops: [.init(hex: 0xFDF6DF, location: 0), .init(hex: 0xF7DDFC, location: 0.34),
                                 .init(hex: 0xD6EAFE, location: 0.68), .init(hex: 0xFEF7DA, location: 1)],
                         isLight: true,
                         washes: [
                            .init(hex: 0xF7DDFC, x: 0.42, y: 0.00, radius: 0.85),
                            .init(hex: 0xD6EAFE, x: 1.00, y: 0.08, radius: 0.82),
                            .init(hex: 0xEFDFFD, x: 0.00, y: 0.42, radius: 0.78),
                            .init(hex: 0xDEEBFD, x: 0.06, y: 1.00, radius: 0.80),
                            .init(hex: 0xFDE1F8, x: 0.48, y: 1.02, radius: 0.72),
                            .init(hex: 0xFEF7DA, x: 1.00, y: 1.00, radius: 0.70),
                            .init(hex: 0xFDF5DE, x: 0.00, y: 0.00, radius: 0.58),
                         ]),
    ]

    public static func preset(for key: String?) -> BackgroundPreset? {
        guard let key else { return nil }
        return all.first { $0.key == key }
    }

    public var cgGradient: CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: stops.map(\.cgColor) as CFArray,
            locations: stops.map(\.location)
        )
    }

    /// Fills `rect`. Linear presets match CSS `linear-gradient`; wash presets bloom from several points. Context must be y-down.
    public func fill(_ rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        if washes.isEmpty {
            if let gradient = cgGradient {
                let (start, end) = GradientGeometry.endpoints(angleDegrees: angle, in: rect)
                context.drawLinearGradient(gradient, start: start, end: end,
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        } else {
            fillWashes(rect, in: context)
        }
        context.restoreGState()
    }

    private func fillWashes(_ rect: CGRect, in context: CGContext) {
        if let base = stops.first?.cgColor {
            context.setFillColor(base)
            context.fill(rect)
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let span = max(rect.width, rect.height)
        for wash in washes {
            guard let gradient = CGGradient(
                colorsSpace: space,
                colors: [wash.cgColor(alpha: 1), wash.cgColor(alpha: 0.72), wash.cgColor(alpha: 0)] as CFArray,
                locations: [0, 0.42, 1]
            ) else { continue }
            let center = CGPoint(x: rect.minX + wash.x * rect.width, y: rect.minY + wash.y * rect.height)
            context.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: wash.radius * span,
                options: [.drawsBeforeStartLocation]
            )
        }
    }
}

public enum GradientGeometry {
    /// CSS gradient line for `angle` in a y-down rect: passes through the centre, and is long enough
    /// that the 0%/100% stops touch the corners (|w·sinθ| + |h·cosθ|).
    public static func endpoints(angleDegrees: Double, in rect: CGRect) -> (CGPoint, CGPoint) {
        let theta = angleDegrees * .pi / 180
        let dx = CGFloat(sin(theta))
        let dy = CGFloat(-cos(theta)) // y-down: 0deg points up
        let length = abs(rect.width * dx) + abs(rect.height * dy)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let half = length / 2
        return (
            CGPoint(x: center.x - dx * half, y: center.y - dy * half),
            CGPoint(x: center.x + dx * half, y: center.y + dy * half)
        )
    }
}

/// Beautify settings. Lengths are in points and scaled by the capture's pixel scale at render time.
public struct BackgroundStyle: Codable, Equatable {
    /// `nil` = no background (plain annotated image).
    public var presetKey: String?
    public var padding: Double
    public var radius: Double
    public var shadow: Double

    /// Pastel Air, the last-added wash; padding / radius / shadow match the editor defaults.
    public static let `default` = BackgroundStyle(presetKey: "pastel-air", padding: 28, radius: 12, shadow: 48)

    public static let paddingRange: ClosedRange<Double> = 8...100
    public static let radiusRange: ClosedRange<Double> = 0...28
    public static let shadowRange: ClosedRange<Double> = 0...80

    public init(presetKey: String?, padding: Double, radius: Double, shadow: Double) {
        self.presetKey = presetKey
        self.padding = padding
        self.radius = radius
        self.shadow = shadow
    }

    public var preset: BackgroundPreset? { BackgroundPreset.preset(for: presetKey) }

    private enum CodingKeys: String, CodingKey {
        case presetKey, padding, radius, shadow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presetKey = try container.decodeIfPresent(String.self, forKey: .presetKey)
        padding = try container.decode(Double.self, forKey: .padding)
        radius = try container.decode(Double.self, forKey: .radius)
        shadow = try container.decode(Double.self, forKey: .shadow)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(presetKey, forKey: .presetKey)
        try container.encode(padding, forKey: .padding)
        try container.encode(radius, forKey: .radius)
        try container.encode(shadow, forKey: .shadow)
    }
}
