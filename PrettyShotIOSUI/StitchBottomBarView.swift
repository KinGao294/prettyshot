import SwiftUI
import UIKit

/// Colours of the stitch preview controls, so tests can resolve them per appearance.
enum StitchPalette {
    /// ⚠ gate line and 「重复？」.
    static let warnText = IOSTheme.warnTextColor
    /// Pending duplicate card (L7e): light #FFFCF5, dark IOSTheme.card. The amber dashed border is separate.
    static let pendingCardBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? IOSTheme.cardColor.resolvedColor(with: traits) : UIColor(hex: 0xFFFCF5)
    }
    /// 「✓ 已处理 · …」 capsule. Same pair as frame 63b: light #4F8F7E, dark #7EB8A8.
    static let handledMint = IOSTheme.stagedCheckColor
}

/// The single bottom bar under the stitch preview. L4–L7j only change what `StitchBottomBar` holds.
struct StitchBottomBarView<Sticky: View>: View {
    var bar: StitchBottomBar
    var onSecondary: () -> Void
    var onPrimary: () -> Void
    @ViewBuilder var sticky: () -> Sticky

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let line = bar.line {
                Text(line)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(uiColor: StitchPalette.warnText))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(IOSTheme.warn.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(IOSTheme.warn.opacity(0.6)))
                    .accessibilityIdentifier("stitch.bottomBar.gate")
            }
            sticky()
            HStack(spacing: 10) {
                Button(IOSCopy.exclusionBands, action: onSecondary)
                    .buttonStyle(PlainCardButtonStyle())
                    .frame(maxWidth: 120)
                Button(bar.primaryTitle, action: onPrimary)
                    .buttonStyle(BloomButtonStyle())
                    .accessibilityIdentifier("stitch.bottomBar.primary")
            }
        }
        .padding(16)
        .background(IOSTheme.paper)
    }
}

/// Dark toast at the top of the stitch preview, with an optional 「撤销」 text button on the right.
struct StitchToastView: View {
    var toast: StitchToast
    var onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(IOSTheme.mint)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 15, weight: .semibold))
                if let detail = toast.detail {
                    Text(detail).font(.system(size: 12)).opacity(0.75)
                }
            }
            Spacer(minLength: 8)
            if let action = toast.actionTitle {
                Button(action, action: onAction)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IOSTheme.bloom)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.12), in: Capsule())
            }
        }
        .foregroundStyle(Color(hex: 0xF5F2EC))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: 0x2C2A28).opacity(0.94), in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
