import Combine
import SwiftUI

/// F7 · Permission Denied — readable copy + deep link to System Settings. Never a black screen.
@MainActor
struct PermissionView: View {
    @ObservedObject var permissions: PermissionManager
    /// Optional extra context, e.g. the underlying capture error.
    var detail: String?
    let onLater: () -> Void
    let onRetryCapture: () -> Void

    @State private var pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Palette.bloomRose.opacity(0.16)).frame(width: 64, height: 64)
                    Image(systemName: permissions.screenCaptureGranted ? "checkmark" : "exclamationmark")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(permissions.screenCaptureGranted ? Palette.softMint : Palette.bloomRose)
                }

                Text(permissions.screenCaptureGranted ? "屏幕录制权限已开启" : "需要屏幕录制权限")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.charcoal)

                VStack(spacing: 8) {
                    if permissions.screenCaptureGranted {
                        Text("如果捕获仍然失败，请重新启动 PrettyShot 让系统应用新的授权。")
                    } else {
                        Text("PrettyShot 需要「屏幕录制」权限才能捕获屏幕内容。")
                        Text("截图只保存在这台 Mac 上 —— v0.1 不会上传到任何云端。授权失败时我们会清楚说明原因，不会静默黑屏。")
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Palette.charcoal.opacity(0.8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                if !permissions.screenCaptureGranted {
                    VStack(alignment: .leading, spacing: 6) {
                        step(1, "点击「打开系统设置」")
                        step(2, "在 隐私与安全性 › 屏幕录制 中打开 PrettyShot")
                        step(3, "回到这里；如提示，重新启动 PrettyShot")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.rail))
                }

                HStack(spacing: 10) {
                    if permissions.screenCaptureGranted {
                        Button("重新启动 PrettyShot") { permissions.relaunch() }
                            .buttonStyle(LightButtonStyle())
                        Button("开始捕获", action: onRetryCapture)
                            .buttonStyle(BloomPrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("稍后再说", action: onLater)
                            .buttonStyle(LightButtonStyle())
                            .keyboardShortcut(.cancelAction)
                        Button("打开系统设置") { permissions.openSystemSettings() }
                            .buttonStyle(BloomPrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                }

                if !permissions.screenCaptureGranted {
                    Button("已经授权？重新启动 PrettyShot") { permissions.relaunch() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(28)
            .frame(width: 440)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Palette.charcoal.opacity(0.12), radius: 20, y: 8)
            )
            .padding(24)
        }
        .onReceive(pollTimer) { _ in permissions.refresh() }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.charcoal)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Palette.bloomRose.opacity(0.5)))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.charcoal.opacity(0.85))
        }
    }
}
