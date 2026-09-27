import AppKit
import ServiceManagement
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var hotkeys: HotkeyManager
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var history: HistoryStore

    var body: some View {
        TabView {
            GeneralSettings(preferences: preferences, history: history)
                .tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutSettings(hotkeys: hotkeys)
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            PermissionSettings(permissions: permissions)
                .tabItem { Label("权限", systemImage: "lock.shield") }
            AboutSettings()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .tint(Palette.bloomDeep)
        .frame(width: 580, height: 440)
    }
}

@MainActor
private struct GeneralSettings: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var history: HistoryStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("保存") {
                LabeledContent("Save 保存到") {
                    HStack {
                        Text(preferences.saveDirectory.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("选择…", action: chooseFolder)
                    }
                }
                Toggle("复制成功时播放提示音", isOn: $preferences.copySoundEnabled)
            }

            Section("启动") {
                Toggle("登录时启动 PrettyShot", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(Palette.bloomDeep)
                }
            }

            Section("历史") {
                LabeledContent("本地历史") {
                    HStack {
                        Text("\(history.items.count) 张（最多 \(HistoryStore.defaultLimit) 张，仅本机）")
                            .foregroundStyle(.secondary)
                        Button("打开文件夹") { NSWorkspace.shared.open(history.directory) }
                        Button("清空…") { confirmClear = true }
                            .disabled(history.items.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清空全部历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) {}
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.saveDirectory
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            preferences.saveDirectory = url
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "无法更改登录项：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

@MainActor
private struct ShortcutSettings: View {
    @ObservedObject var hotkeys: HotkeyManager

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(action: action, hotkeys: hotkeys)
                    }
                }
            } header: {
                Text("全局快捷键")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("默认 ⌥⌘1 / ⌥⌘2 / ⌥⌘3 / ⌥⌘H / ⌥⌘P，均为建议值，可随时重映射。")
                    Text("PrettyShot 不会占用系统截图键 ⌘⇧3 / ⌘⇧4 / ⌘⇧5。与其它 App 冲突时会在对应行提示。")
                    Text("捕获中：Esc 取消；Quick Overlay：↩ / ⌘C 复制，Esc 关闭。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("全部恢复默认") { hotkeys.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct PermissionSettings: View {
    @ObservedObject var permissions: PermissionManager

    var body: some View {
        Form {
            Section("屏幕录制") {
                HStack(spacing: 10) {
                    Image(systemName: permissions.screenCaptureGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(permissions.screenCaptureGranted ? Palette.softMint : Palette.bloomDeep)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permissions.screenCaptureGranted ? "已授权" : "未授权")
                            .font(.system(size: 13, weight: .semibold))
                        Text("捕获区域 / 窗口 / 全屏都需要此权限。截图只保存在本机。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack {
                    Button("打开系统设置") { permissions.openSystemSettings() }
                    Button("重新检测") { permissions.refresh() }
                    Spacer()
                    Button("重新启动 PrettyShot") { permissions.relaunch() }
                }
            }
            Section("全局快捷键") {
                Text("PrettyShot 使用系统热键 API 注册快捷键，不需要「辅助功能」权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.refresh() }
    }
}

@MainActor
private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            BrandMark(size: 56)
            Text("PrettyShot")
                .font(.system(size: 20, weight: .semibold))
            Text("纸感光晕 · Paper Bloom · v\(version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Mac 截图 标注 + 美化。截图仅保存在本机。")
                .font(.system(size: 12))
            Text("MIT License · 架构思路参考 DodoShot / OpenShots / SimplShot（MIT），代码均为原创重写。详见 README。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
