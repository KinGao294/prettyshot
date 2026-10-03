import AppKit
import SwiftUI

// Paper Bloom · 纸感光晕 — tokens from design/DESIGN.md §3.1.
// Intentionally warm neutrals + Bloom Rose; no teal/dark-chrome clone of any other product.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum Palette {
    static let bloomRose = Color(hex: 0xE8A0A8)
    /// Pending-confirmation seam. Same amber as a comment pin.
    static let amber = Color(hex: 0xE8A33D)
    static let bloomDeep = Color(hex: 0xD48993)
    static let softMint = Color(hex: 0x7EB8A8)
    static let ivory = Color(hex: 0xF5F2EC)
    static let canvas = Color(hex: 0xECE8E1)
    static let rail = Color(hex: 0xF7F4EE)
    static let drawer = Color(hex: 0xFBFAF7)
    static let charcoal = Color(hex: 0x2C2A28)
    static let chrome = Color(hex: 0x1C1C1E)
    static let borderLight = Color(hex: 0xE2DDD4)
    static let borderDark = Color.white.opacity(0.12)
    static let muted = Color(hex: 0x8A857C)
    static let ivoryMuted = Color(hex: 0xF5F2EC, alpha: 0.55)
}

enum Metrics {
    static let overlayRadius: CGFloat = 14
    static let cardRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 9
}

// MARK: - Frosted chrome (#1C1C1E @ 88% over a behind-window blur)

@MainActor
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

@MainActor
struct FrostedChrome: View {
    var cornerRadius: CGFloat = Metrics.overlayRadius

    var body: some View {
        ZStack {
            VisualEffectBlur()
            Palette.chrome.opacity(0.88)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Palette.borderDark, lineWidth: 1)
        )
    }
}

// MARK: - Buttons

/// Primary CTA — Bloom Rose; flips to Soft Mint for the short "已复制" success state.
struct BloomPrimaryButtonStyle: ButtonStyle {
    var success = false
    var expand = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(success ? Color.white : Palette.charcoal)
            .padding(.horizontal, 16)
            .frame(maxWidth: expand ? .infinity : nil, minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: Metrics.buttonRadius, style: .continuous)
                    .fill(success ? Palette.softMint : Palette.bloomRose)
                    .shadow(color: (success ? Palette.softMint : Palette.bloomRose).opacity(0.35), radius: 8, y: 3)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.18), value: success)
    }
}

/// Secondary action on a dark (chrome) surface.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.ivory)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: Metrics.buttonRadius, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09))
            )
    }
}

/// Square icon button on a dark surface; `active` shows the Soft Mint "pinned" state.
struct IconGhostButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? Palette.softMint : Palette.ivory)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: Metrics.buttonRadius, style: .continuous)
                    .fill(active ? Palette.softMint.opacity(0.2) : Color.white.opacity(configuration.isPressed ? 0.16 : 0.09))
            )
    }
}

/// Secondary action on a light (paper) surface.
struct LightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.charcoal)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: Metrics.buttonRadius, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.buttonRadius, style: .continuous)
                    .strokeBorder(Palette.borderLight, lineWidth: 1)
            )
    }
}

/// Shortcut hint capsule, right-aligned in menus (e.g. "⌥⌘1").
@MainActor
struct KeyHint: View {
    let text: String
    var dark = true

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(dark ? Palette.ivoryMuted : Palette.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(dark ? Color.white.opacity(0.07) : Palette.rail)
            )
    }
}
