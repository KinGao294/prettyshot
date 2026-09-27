import AppKit
import SwiftUI

/// PrettyShot mark: soft rounded aperture + a single bloom petal (original artwork,
/// geometry mirrors the inline SVG in design/prototype.html, 32×32 viewBox).
@MainActor
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        let u = size / 32
        ZStack {
            RoundedRectangle(cornerRadius: 9 * u, style: .continuous)
                .fill(Palette.bloomRose.opacity(0.2))
                .frame(width: 28 * u, height: 28 * u)
            Circle()
                .stroke(Palette.bloomRose, lineWidth: 2 * u)
                .frame(width: 15 * u, height: 15 * u)
            Circle()
                .fill(Palette.bloomRose)
                .frame(width: 6 * u, height: 6 * u)
            PetalShape()
                .stroke(Palette.ivory.opacity(0.85), style: StrokeStyle(lineWidth: 1.4 * u, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

/// The petal stroke: `M22.5 7.5 c1.2-.2 2.4.6 2.6 1.8 .2 1.2-.6 2.2-1.6 2.5` in a 32-unit box.
struct PetalShape: Shape {
    func path(in rect: CGRect) -> Path {
        let u = min(rect.width, rect.height) / 32
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * u) }
        var path = Path()
        path.move(to: p(22.5, 7.5))
        path.addCurve(to: p(25.1, 9.3), control1: p(23.7, 7.3), control2: p(24.9, 8.1))
        path.addCurve(to: p(23.5, 11.8), control1: p(25.3, 10.5), control2: p(24.5, 11.5))
        return path
    }
}

enum BrandImages {
    /// Template image for the status bar (monochrome so macOS tints it for light/dark menu bars).
    static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            let u = rect.width / 32
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let ring = NSBezierPath(ovalIn: NSRect(x: 8 * u, y: 8 * u, width: 16 * u, height: 16 * u))
            ring.lineWidth = 3 * u
            ring.stroke()

            NSBezierPath(ovalIn: NSRect(x: 13 * u, y: 13 * u, width: 6 * u, height: 6 * u)).fill()

            let petal = NSBezierPath()
            petal.move(to: NSPoint(x: 22.5 * u, y: 5.5 * u))
            petal.curve(to: NSPoint(x: 26.6 * u, y: 8.4 * u),
                        controlPoint1: NSPoint(x: 24.2 * u, y: 5.0 * u),
                        controlPoint2: NSPoint(x: 26.2 * u, y: 6.4 * u))
            petal.curve(to: NSPoint(x: 24.4 * u, y: 12.2 * u),
                        controlPoint1: NSPoint(x: 27.0 * u, y: 10.2 * u),
                        controlPoint2: NSPoint(x: 25.8 * u, y: 11.7 * u))
            petal.lineWidth = 2.2 * u
            petal.lineCapStyle = .round
            petal.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "PrettyShot"
        return image
    }
}
