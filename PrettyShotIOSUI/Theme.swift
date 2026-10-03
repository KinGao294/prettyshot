import SwiftUI
import UIKit

enum IOSTheme {
    static let bloom = Color(hex: 0xE8A0A8)
    static let bloomInk = Color(hex: 0x3A1A20)
    static let mint = Color(hex: 0x7EB8A8)
    static let warn = Color(hex: 0xE3B26B)
    static let canvas = dynamic(light: 0xECE8E1, dark: 0x171615)
    static let rail = dynamic(light: 0xF7F4EE, dark: 0x2B2927)
    static let paper = dynamic(light: 0xFBF9F5, dark: 0x1E1D1C)
    static let charcoal = dynamic(light: 0x2C2A28, dark: 0xEDE8E1)
    static let muted = dynamic(light: 0x8A857C, dark: 0x9C958B)
    static let hairline = dynamic(light: 0xE2DDD4, dark: 0x3A3735)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x3A3735)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
