import AppKit
import PrettyShotCore
import SwiftUI

struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    /// Relative luminance, used to pick a legible number colour on counter badges.
    var isLight: Bool { (0.299 * red + 0.587 * green + 0.114 * blue) > 0.7 }

    static let bloomRose = RGBAColor(hex: 0xE8A0A8)
    static let palette: [RGBAColor] = [
        .bloomRose,
        RGBAColor(hex: 0xD9485F), // rose red — high contrast on light UIs
        RGBAColor(hex: 0xE8A33D), // amber
        RGBAColor(hex: 0x7EB8A8), // soft mint
        RGBAColor(hex: 0x4A6FA5), // ink blue
        RGBAColor(hex: 0x2C2A28), // charcoal
        RGBAColor(hex: 0xFFFFFF), // white
    ]
}

enum StrokeLevel: Int, CaseIterable, Identifiable, Codable {
    case thin, medium, thick

    var id: Int { rawValue }

    /// Points; multiplied by the capture scale.
    var lineWidth: CGFloat {
        switch self {
        case .thin: return 2
        case .medium: return 4
        case .thick: return 7
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .thin: return 16
        case .medium: return 22
        case .thick: return 32
        }
    }

    var title: String {
        switch self {
        case .thin: return "细"
        case .medium: return "中"
        case .thick: return "粗"
        }
    }
}

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, text, counter, crop, pixelate, blur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "选择 / 移动"
        case .arrow: return "箭头"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .text: return "文字"
        case .counter: return "计数"
        case .crop: return "裁剪"
        case .pixelate: return "马赛克 / 像素化"
        case .blur: return "模糊"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .crop: return "crop"
        case .pixelate: return "square.grid.3x3.fill"
        case .blur: return "drop.halffull"
        }
    }

    /// Single-key tool switching (disabled while typing text).
    var key: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .text: return "t"
        case .counter: return "n"
        case .crop: return "c"
        case .pixelate: return "p"
        case .blur: return "b"
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .text: return .text
        case .counter: return .counter
        case .pixelate: return .pixelate
        case .blur: return .blur
        case .select, .crop: return nil
        }
    }
}

/// One mark on the screenshot. Geometry is in *image pixel* coordinates (origin top-left, y down),
/// so the same data renders identically in the live canvas and in the exported PNG.
struct Annotation: Identifiable, Equatable {
    enum Kind: String, Codable {
        case arrow, rectangle, ellipse, text, counter, pixelate, blur

        var isRedaction: Bool { self == .pixelate || self == .blur }
    }

    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var color: RGBAColor
    var lineWidth: CGFloat
    var fontSize: CGFloat
    var text: String = ""
    var number: Int = 0

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var counterRadius: CGFloat { fontSize * 0.75 }

    /// Whether a freshly drawn shape is big enough to keep (filters accidental clicks).
    var isMeaningful: Bool {
        switch kind {
        case .arrow: return hypot(end.x - start.x, end.y - start.y) >= 6
        case .rectangle, .ellipse, .pixelate, .blur: return rect.width >= 4 && rect.height >= 4
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .counter: return true
        }
    }

    /// Visual bounds in image pixels, used for hit-testing and selection outlines.
    var bounds: CGRect {
        switch kind {
        case .text:
            return CGRect(origin: start, size: AnnotationRenderer.textSize(for: self))
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .arrow:
            return rect.insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        default:
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .arrow:
            return Self.distance(from: point, toSegment: start, end) <= max(lineWidth, tolerance)
        case .rectangle, .ellipse:
            // Hollow shapes: hit near the outline or inside (easier to grab small ones).
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        default:
            return bounds.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point)
        }
    }

    func offset(by delta: CGSize) -> Annotation {
        var copy = self
        copy.start = CGPoint(x: start.x + delta.width, y: start.y + delta.height)
        copy.end = CGPoint(x: end.x + delta.width, y: end.y + delta.height)
        return copy
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

extension Annotation: Redactable {
    var redactionKind: RedactionKind? {
        switch kind {
        case .pixelate: return .pixelate
        case .blur: return .blur
        default: return nil
        }
    }

    var redactionRect: CGRect { rect }

    var isMeaningfulRedaction: Bool { isMeaningful }
}
