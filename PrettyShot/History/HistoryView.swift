import SwiftUI

struct HistoryActions {
    var open: (HistoryItem) -> Void
    var pin: (HistoryItem) -> Void
    var copy: (HistoryItem) -> Void
    var reveal: (HistoryItem) -> Void
    var captureRegion: () -> Void
}

/// F5 · History — empty state + grid; open (re-edit) / Pin / copy / delete per card.
@MainActor
struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var hotkeys: HotkeyManager
    let actions: HistoryActions

    @State private var confirmClear = false

    private let columns = [GridItem(.adaptive(minimum: 196, maximum: 280), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.borderLight).frame(height: 1)
            if store.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.items) { item in
                            HistoryCard(item: item, store: store, actions: actions)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Palette.canvas)
        .frame(minWidth: 560, minHeight: 420)
        .confirmationDialog("清空全部历史？", isPresented: $confirmClear) {
            Button("清空 \(store.items.count) 张截图", role: .destructive) { store.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅删除 PrettyShot 历史中的副本，已保存/导出的文件不受影响。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 22)
            Text("历史 History")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.charcoal)
            if !store.items.isEmpty {
                Text("\(store.items.count) 张 · 仅保存在本机")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(store.directory)
            } label: {
                Label("打开文件夹", systemImage: "folder")
            }
            .buttonStyle(LightButtonStyle())
            if !store.items.isEmpty {
                Button("清空") { confirmClear = true }
                    .buttonStyle(LightButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(Palette.ivory)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Palette.bloomRose.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .frame(width: 120, height: 84)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Palette.bloomRose)
            }
            .padding(.bottom, 4)
            Text("还没有截图")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.charcoal)
            Text("捕获一张，开始你的纸感光晕")
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
            let hint = hotkeys.displayString(for: .captureRegion)
            Button(hint.isEmpty ? "捕获区域" : "捕获区域 · \(hint)", action: actions.captureRegion)
                .buttonStyle(BloomPrimaryButtonStyle())
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct HistoryCard: View {
    let item: HistoryItem
    @ObservedObject var store: HistoryStore
    let actions: HistoryActions

    @State private var thumbnail: NSImage?
    @State private var hovering = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Palette.rail
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(8)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 132)
                .clipped()

                if hovering {
                    HStack(spacing: 4) {
                        op("pencil", "编辑 / 重开") { actions.open(item) }
                        op("pin", "Pin") { actions.pin(item) }
                        op("doc.on.doc", "复制") { actions.copy(item) }
                        op("magnifyingglass", "在 Finder 中显示") { actions.reveal(item) }
                        op("trash", "删除") { confirmDelete = true }
                    }
                    .padding(6)
                    .transition(.opacity)
                }
            }

            HStack {
                Text(item.createdAt, format: .dateTime.hour().minute())
                Text("·")
                Text(item.modeLabel)
                Spacer()
                Text(Self.dayLabel(for: item.createdAt))
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(hovering ? Palette.bloomRose : Palette.borderLight, lineWidth: hovering ? 1.5 : 1)
        )
        .shadow(color: Palette.charcoal.opacity(hovering ? 0.12 : 0.05), radius: hovering ? 10 : 4, y: 2)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .onTapGesture(count: 2) { actions.open(item) }
        .focusable()
        .onKeyPress(.return) { actions.open(item); return .handled }
        .contextMenu {
            Button("编辑 / 重开") { actions.open(item) }
            Button("Pin") { actions.pin(item) }
            Button("复制") { actions.copy(item) }
            Button("在 Finder 中显示") { actions.reveal(item) }
            Divider()
            Button("删除", role: .destructive) { store.delete(item) }
        }
        .confirmationDialog("删除这张截图？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { store.delete(item) }
            Button("取消", role: .cancel) {}
        }
        .onDrag { NSItemProvider(contentsOf: store.url(for: item)) ?? NSItemProvider() }
        .task(id: item.id) {
            thumbnail = await store.thumbnail(for: item)
        }
        .help("双击或 ↩ 打开编辑器")
    }

    private func op(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ivory)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.chrome.opacity(0.82)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.month().day())
    }
}
