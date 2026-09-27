import SwiftUI

struct EditorActions {
    /// Returns true when the image landed on the clipboard.
    var copy: (EditorDocument) -> Bool
    var export: (EditorDocument) -> Void
    var pin: (EditorDocument) -> Void
}

/// F4 · Editor — tool rail (left, always reachable) · canvas · background drawer (right, secondary).
@MainActor
struct EditorView: View {
    @ObservedObject var doc: EditorDocument
    let actions: EditorActions

    @State private var showDrawer = true
    @State private var copied = false

    private var typing: Bool { doc.pendingText != nil }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Palette.borderLight).frame(height: 1)
            HStack(spacing: 0) {
                ToolRail(doc: doc, shortcutsEnabled: !typing)
                Rectangle().fill(Palette.borderLight).frame(width: 1)
                EditorCanvas(doc: doc)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.canvas)
                if showDrawer {
                    Rectangle().fill(Palette.borderLight).frame(width: 1)
                    BackgroundDrawer(doc: doc)
                        .frame(width: 264)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Palette.canvas)
        .background(hiddenShortcuts)
        .frame(minWidth: 860, minHeight: 540)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            BrandMark(size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("PrettyShot Editor")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.charcoal)
                Text("标注优先 · 美化不挡路")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }

            Spacer(minLength: 12)

            HStack(spacing: 12) {
                colorPicker
                strokePicker
                divider
                historyControls
            }

            HStack(spacing: 12) {
                if doc.cropRect != nil {
                    Button("重置裁剪") { doc.resetCrop() }
                        .buttonStyle(LightButtonStyle())
                }
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showDrawer.toggle() }
                } label: {
                    Image(systemName: "sidebar.right")
                        .foregroundStyle(showDrawer ? Palette.bloomDeep : Palette.charcoal)
                }
                .buttonStyle(.borderless)
                .help("背景抽屉")
                divider
                outputControls
            }
        }
        .foregroundStyle(Palette.charcoal)
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Palette.ivory)
    }

    private var historyControls: some View {
        HStack(spacing: 10) {
            Button { doc.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .disabled(!doc.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("撤销 ⌘Z")
            Button { doc.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.borderless)
                .disabled(!doc.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("重做 ⇧⌘Z")
        }
    }

    private var outputControls: some View {
        HStack(spacing: 10) {
            Button { actions.pin(doc) } label: { Image(systemName: "pin") }
                .buttonStyle(.borderless)
                .help("Pin 到桌面浮窗")

            Button("Export") { actions.export(doc) }
                .buttonStyle(LightButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
                .help("导出 PNG ⌘S")

            Button(copied ? "已复制" : "Copy") { copy() }
                .buttonStyle(BloomPrimaryButtonStyle(success: copied))
                .keyboardShortcut(typing ? nil : KeyboardShortcut("c", modifiers: .command))
                .help("复制到剪贴板 ⌘C")
        }
    }

    private var divider: some View {
        Rectangle().fill(Palette.borderLight).frame(width: 1, height: 22)
    }

    private var colorPicker: some View {
        HStack(spacing: 6) {
            ForEach(RGBAColor.palette, id: \.self) { swatch in
                Button {
                    doc.color = swatch
                    doc.applyStyleToSelection()
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Palette.charcoal.opacity(0.15), lineWidth: 1))
                        .padding(2)
                        .overlay(
                            Circle().strokeBorder(doc.color == swatch ? Palette.bloomDeep : .clear, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .help("颜色")
    }

    private var strokePicker: some View {
        HStack(spacing: 2) {
            ForEach(StrokeLevel.allCases) { level in
                Button {
                    doc.strokeLevel = level
                    doc.applyStyleToSelection()
                } label: {
                    Capsule()
                        .fill(Palette.charcoal)
                        .frame(width: 16, height: level.lineWidth)
                        .frame(width: 26, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(doc.strokeLevel == level ? Palette.bloomRose.opacity(0.3) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help("线宽 / 字号：\(level.title)")
            }
        }
    }

    /// Keyboard-only commands (zero-size buttons keep SwiftUI's shortcut routing).
    private var hiddenShortcuts: some View {
        ZStack {
            Button("") { doc.deleteSelected() }
                .keyboardShortcut(typing ? nil : KeyboardShortcut(.delete, modifiers: []))
            Button("") {
                if doc.pendingText != nil { doc.cancelPendingText() } else { doc.selectedID = nil }
            }
            .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func copy() {
        guard actions.copy(doc) else { return }
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }
}

// MARK: - Tool rail

@MainActor
private struct ToolRail: View {
    @ObservedObject var doc: EditorDocument
    let shortcutsEnabled: Bool

    private let drawingTools: [EditorTool] = [.select, .arrow, .rectangle, .ellipse, .text, .counter]
    private let imageTools: [EditorTool] = [.crop, .pixelate, .blur]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(drawingTools) { toolButton($0) }
            Rectangle().fill(Palette.borderLight).frame(width: 26, height: 1).padding(.vertical, 6)
            ForEach(imageTools) { toolButton($0) }
            Spacer()
            Button { doc.clearAll() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 40, height: 36)
            }
            .buttonStyle(.plain)
            .help("清除全部标注与裁剪")
        }
        .padding(.vertical, 12)
        .frame(width: 60)
        .background(Palette.rail)
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        let active = doc.tool == tool
        return Button {
            doc.tool = tool
        } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.charcoal)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(active ? Palette.bloomRose.opacity(0.25) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(active ? Palette.bloomRose : .clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcutsEnabled ? KeyboardShortcut(KeyEquivalent(tool.key), modifiers: []) : nil)
        .help("\(tool.title)（\(String(tool.key).uppercased())）")
    }
}

// MARK: - Background drawer

@MainActor
private struct BackgroundDrawer: View {
    @ObservedObject var doc: EditorDocument

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("BACKGROUND · 背景")

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(BackgroundPreset.all) { preset in
                        Button { doc.background.presetKey = preset.key } label: {
                            BackgroundSwatch(preset: preset, selected: doc.background.presetKey == preset.key)
                        }
                        .buttonStyle(.plain)
                        .help("\(preset.name) · \(preset.localizedName)")
                    }
                }

                Button { doc.background.presetKey = nil } label: {
                    HStack {
                        Image(systemName: "square.slash")
                        Text("无背景（仅标注）")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.charcoal)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(doc.background.presetKey == nil ? Palette.bloomRose : Palette.borderLight,
                                          lineWidth: doc.background.presetKey == nil ? 2 : 1)
                    )
                }
                .buttonStyle(.plain)

                sectionTitle("美化（次级）")
                    .padding(.top, 4)

                Group {
                    slider("Padding", value: $doc.background.padding, range: BackgroundStyle.paddingRange)
                    slider("Radius", value: $doc.background.radius, range: BackgroundStyle.radiusRange)
                    slider("Shadow", value: $doc.background.shadow, range: BackgroundStyle.shadowRange)
                }
                .disabled(doc.background.presetKey == nil)
                .opacity(doc.background.presetKey == nil ? 0.45 : 1)

                Text("工具轨始终可达 · 背景抽屉不遮挡标注（P2）")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .background(Palette.drawer)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Palette.muted)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))")
                    .monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(Palette.charcoal.opacity(0.8))
            Slider(value: value, in: range)
                .tint(Palette.bloomRose)
                .controlSize(.small)
        }
    }
}

@MainActor
struct BackgroundSwatch: View {
    let preset: BackgroundPreset
    let selected: Bool

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                preset.fill(CGRect(origin: .zero, size: size), in: cg)
            }
        }
        .frame(height: 48)
        .overlay(alignment: .bottomLeading) {
            Text(preset.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(preset.isLight ? Palette.charcoal : Color.white)
                .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Palette.bloomRose : Palette.borderLight, lineWidth: selected ? 2.5 : 1)
        )
        .contentShape(Rectangle())
    }
}
