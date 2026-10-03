import PrettyShotCore
import SwiftUI
import UIKit

/// Frames 04–09 and 17. Share extension and the app use the same structure.
struct EditorScreen: View {
    @ObservedObject var model: EditorModel
    var showsClose: Bool
    var onClose: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var missingLine: String?
    var missingOrdinals: [Int] = []
    var onReadd: (Int) -> Void = { _ in }
    /// Extension only, and only for an image that is over the extension memory budget.
    var showsPreviewDownsampleChip: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let missingLine {
                VStack(alignment: .leading, spacing: 6) {
                    Text(missingLine)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(IOSTheme.charcoal)
                    ForEach(missingOrdinals, id: \.self) { ordinal in
                        Button("\(IOSCopy.readdShot) · 第 \(ordinal) 张") { onReadd(ordinal) }
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(IOSTheme.warn.opacity(0.22))
            }
            canvas
            tabBar
            panel
            actionBar
        }
        .background(IOSTheme.paper)
        .overlay(alignment: .top) { toast }
    }

    private var topBar: some View {
        HStack {
            if showsClose {
                Button(IOSCopy.cancel, action: onClose)
                    .foregroundStyle(IOSTheme.charcoal)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
            Spacer()
            Text(IOSCopy.brand)
                .font(.system(size: 16.5, weight: .semibold))
                .foregroundStyle(IOSTheme.charcoal)
            Spacer()
            HStack(spacing: 0) {
                Button(IOSCopy.undo, action: model.undo).disabled(!model.canUndo)
                Button(IOSCopy.redo, action: model.redo).disabled(!model.canRedo)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(IOSTheme.charcoal)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(IOSTheme.rail)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                IOSTheme.canvas
                if let preview = model.preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                        .gesture(drawGesture(in: proxy.size))
                }
                VStack(alignment: .leading, spacing: 8) {
                    chip
                    if showsPreviewDownsampleChip {
                        chipLabel(IOSCopy.chipDownsampled)
                    }
                }
                .padding(12)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var chip: some View {
        Group {
            if let match = model.cropMatch {
                chipLabel(model.removeStatusBar ? "\(IOSCopy.chipStatusRemoved) · \(match.modelLabel)" : IOSCopy.chipStatusKept)
            } else if model.pixelWidth > 0 {
                chipLabel(IOSCopy.chipNotScreenshot)
            }
        }
    }

    private func chipLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(IOSTheme.charcoal)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    model.tool = tool
                } label: {
                    VStack(spacing: 4) {
                        Text(tool.title).font(.system(size: 11, weight: .medium))
                        Capsule()
                            .fill(model.tool == tool ? IOSTheme.bloom : .clear)
                            .frame(width: 16, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .foregroundStyle(model.tool == tool ? IOSTheme.charcoal : IOSTheme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .background(IOSTheme.rail)
    }

    @ViewBuilder
    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.tool {
            case .background:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(BackgroundPreset.all) { preset in
                            Button {
                                model.style.presetKey = preset.key
                            } label: {
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(swatch(preset))
                                        .frame(width: 46, height: 46)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(model.style.presetKey == preset.key ? IOSTheme.bloom : .clear, lineWidth: 2)
                                        )
                                    Text(preset.localizedName).font(.system(size: 10))
                                    if preset.key == BackgroundStyle.default.presetKey {
                                        Text(IOSCopy.defaultBadge).font(.system(size: 9)).foregroundStyle(IOSTheme.muted)
                                    }
                                }
                                .foregroundStyle(IOSTheme.charcoal)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            case .style:
                slider(IOSCopy.styleRadius, value: $model.style.radius, range: BackgroundStyle.radiusRange)
                slider(IOSCopy.stylePadding, value: $model.style.padding, range: BackgroundStyle.paddingRange)
                slider(IOSCopy.styleShadow, value: $model.style.shadow, range: BackgroundStyle.shadowRange)
            case .crop:
                Toggle(IOSCopy.removeStatusBar, isOn: Binding(
                    get: { model.removeStatusBar },
                    set: { model.setRemoveStatusBar($0) }
                ))
                .disabled(model.cropMatch == nil)
                Text(model.cropMatch == nil ? IOSCopy.cropUnavailable : IOSCopy.cropApplied)
                    .font(.system(size: 12))
                    .foregroundStyle(IOSTheme.muted)
            case .arrow:
                Text(IOSCopy.arrowHint).font(.system(size: 13)).foregroundStyle(IOSTheme.charcoal)
                Button(IOSCopy.delete, action: model.deleteLastMark).disabled(model.arrows.isEmpty)
            case .redact:
                Text(IOSCopy.redactHint).font(.system(size: 13)).foregroundStyle(IOSTheme.charcoal)
                Text(IOSCopy.redactRule).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
                Button(IOSCopy.delete, action: model.deleteLastMark).disabled(model.redactions.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(IOSTheme.rail)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(IOSCopy.copy, action: onCopy)
                .frame(width: 96, height: 52)
                .background(IOSTheme.card)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(IOSTheme.hairline))
                .foregroundStyle(IOSTheme.charcoal)
            Button(IOSCopy.saveToPhotos, action: onSave)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(IOSTheme.bloom)
                .foregroundStyle(IOSTheme.bloomInk)
        }
        .font(.system(size: 16.5, weight: .semibold))
        .padding(16)
        .background(IOSTheme.paper)
    }

    @ViewBuilder
    private var toast: some View {
        if let title = model.toastTitle {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let detail = model.toastDetail {
                    Text(detail).font(.system(size: 12))
                }
            }
            .foregroundStyle(Color(hex: 0xF5F2EC))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(hex: 0x1C1C1E).opacity(0.88), in: Capsule())
            .padding(.top, 70)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 36, alignment: .leading).font(.system(size: 12))
            Slider(value: value, in: range)
                .tint(IOSTheme.bloom)
            Text("\(Int(value.wrappedValue.rounded()))")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 28, alignment: .trailing)
        }
        .foregroundStyle(IOSTheme.charcoal)
    }

    private func swatch(_ preset: BackgroundPreset) -> Color {
        let hex = preset.stops.first?.hex ?? 0xFDF6DF
        return Color(hex: hex)
    }

    private func drawGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: model.tool == .redact ? 8 : 18)
            .onEnded { value in
                switch model.tool {
                case .arrow:
                    model.addArrow(start: value.startLocation, end: value.location, in: size)
                case .redact:
                    let rect = CGRect(
                        x: min(value.startLocation.x, value.location.x),
                        y: min(value.startLocation.y, value.location.y),
                        width: abs(value.location.x - value.startLocation.x),
                        height: abs(value.location.y - value.startLocation.y)
                    )
                    model.addRedaction(rect: rect, in: size)
                default:
                    break
                }
            }
    }
}
