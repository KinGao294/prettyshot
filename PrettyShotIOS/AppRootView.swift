import PhotosUI
import PrettyShotCore
import SwiftUI
import UniformTypeIdentifiers

/// Frames 15–19 and the long-screenshot path 35–48 / 51–55.
struct AppRootView: View {
    @StateObject private var editor = EditorModel()
    @StateObject private var stitch = StitchModel()
    @State private var route: AppRoute?
    @State private var singleItem: PhotosPickerItem?
    @State private var stitchItems: [PhotosPickerItem] = []
    @State private var ordered: [ShotFile] = []
    @State private var showPDF = false
    @State private var pdfStub = false
    @State private var pending: [HandoffTicket] = []
    @State private var loadError = false
    private let store: HandoffStore = HandoffStoreFactory.live()

    var body: some View {
        NavigationStack {
            home
                .navigationDestination(item: $route) { destination in
                    switch destination {
                    case .editor:
                        EditorScreen(model: editor, showsClose: true, onClose: { route = nil }, onCopy: copyEditor, onSave: saveEditor)
                            .navigationBarHidden(true)
                    case .order:
                        orderScreen
                    case .stitch:
                        StitchScreen(model: stitch, onBack: { route = nil }, onBeautify: openFlattened, onExportSegments: saveSegments)
                            .navigationBarHidden(true)
                    case .error:
                        VStack(spacing: 12) {
                            Text(IOSCopy.memoryFailedTitle).font(.title2.weight(.semibold))
                            Text(IOSCopy.memoryFailedBody).foregroundStyle(IOSTheme.muted)
                            Button(IOSCopy.cancel) { route = nil }.buttonStyle(PlainCardButtonStyle())
                        }
                        .padding(24)
                    }
                }
        }
        .onAppear(perform: refreshPending)
        .onOpenURL { _ in refreshPending() }
        .fileImporter(isPresented: $showPDF, allowedContentTypes: [.pdf]) { result in
            if case .success = result {
                pdfStub = true
            }
        }
        .sheet(isPresented: $pdfStub) {
            VStack(alignment: .leading, spacing: 12) {
                Text(IOSCopy.pdfTitle).font(.title2.weight(.bold))
                Text(IOSCopy.pdfBody)
                Text(IOSCopy.pdfPickedStub).foregroundStyle(IOSTheme.muted)
                Button(IOSCopy.cancel) { pdfStub = false }.buttonStyle(PlainCardButtonStyle())
            }
            .padding(20)
            .presentationDetents([.medium])
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(IOSCopy.homeTitle)
                    .font(.system(size: 33, weight: .bold))
                    .foregroundStyle(IOSTheme.charcoal)
                PhotosPicker(selection: $singleItem, matching: .images, photoLibrary: .shared()) {
                    Text(IOSCopy.pickFromLibrary)
                        .font(.system(size: 16.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(IOSTheme.bloom)
                        .foregroundStyle(IOSTheme.bloomInk)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .onChange(of: singleItem) { _, item in
                    guard let item else { return }
                    Task { await loadSingle(item) }
                }
                HStack(spacing: 10) {
                    PhotosPicker(selection: $stitchItems, maxSelectionCount: 20, matching: .images, photoLibrary: .shared()) {
                        card(IOSCopy.stitchCardTitle, IOSCopy.stitchCardDetail)
                    }
                    .onChange(of: stitchItems) { _, items in
                        guard items.count >= 2 else { return }
                        Task { await loadStitch(items) }
                    }
                    Button {
                        showPDF = true
                    } label: {
                        card(IOSCopy.pdfCardTitle, IOSCopy.pdfCardDetail)
                    }
                    .buttonStyle(.plain)
                }
                if stitchItems.count == 1 {
                    Text(IOSCopy.stitchNeedTwo).font(.footnote).foregroundStyle(IOSTheme.muted)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(IOSCopy.homeShareHint).font(.system(size: 15, weight: .semibold))
                    Text(IOSCopy.homeShareHintDetail).font(.system(size: 13)).foregroundStyle(IOSTheme.muted)
                }
                if !pending.isEmpty {
                    Button(action: openPending) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(IOSCopy.handoffBannerTitle).font(.system(size: 15, weight: .semibold))
                            Text(IOSCopy.handoffBannerDetail(count: pending.reduce(0) { $0 + $1.fileNames.count }))
                                .font(.system(size: 12))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(IOSTheme.rail, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(IOSTheme.charcoal)
                }
                if pdfStub == false && loadError {
                    Text(IOSCopy.readFailedBody).font(.footnote).foregroundStyle(IOSTheme.muted)
                }
                Text(IOSCopy.homeFooter).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
                Text(IOSCopy.pdfBody).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
            }
            .padding(20)
        }
        .background(IOSTheme.paper)
    }

    private var orderScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(IOSCopy.stitchOrderHint).font(.system(size: 13)).foregroundStyle(IOSTheme.muted)
            List {
                ForEach(ordered) { shot in
                    Text(shot.label)
                }
                .onMove { ordered.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            Button(IOSCopy.stitchStart) {
                let images = ordered.compactMap { ImagePrep.downsample($0.data, maxLongSide: ExtensionMemoryBudget.stitchInputMaxLongSide) }
                stitch.ingest(images)
                route = .stitch
            }
            .buttonStyle(BloomButtonStyle())
            .disabled(ordered.count < 2)
            .padding(.horizontal, 16)
        }
        .navigationTitle(IOSCopy.stitchCardTitle)
    }

    private func card(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(10)
        .background(IOSTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(IOSTheme.hairline))
        .foregroundStyle(IOSTheme.charcoal)
    }

    private func loadSingle(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                loadError = true
                return
            }
            await MainActor.run {
                editor.load(data)
                route = .editor
            }
        } catch {
            await MainActor.run { route = .error }
        }
    }

    private func loadStitch(_ items: [PhotosPickerItem]) async {
        var files: [ShotFile] = []
        for (index, item) in items.enumerated() {
            if let data = try? await item.loadTransferable(type: Data.self) {
                files.append(ShotFile(label: "\(index + 1)", data: data))
            }
        }
        await MainActor.run {
            ordered = files
            route = files.count >= 2 ? .order : nil
        }
    }

    private func refreshPending() {
        pending = (try? store.pendingTickets()) ?? []
    }

    private func openPending() {
        guard let ticket = pending.last else { return }
        let urls = (try? store.files(for: ticket.id)) ?? []
        ordered = urls.enumerated().compactMap { index, url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ShotFile(label: "\(index + 1)", data: data)
        }
        if ordered.count >= 2 {
            route = .order
        } else if let first = ordered.first {
            editor.load(first.data)
            route = .editor
        }
    }

    private func copyEditor() {
        guard case .image(let image, let preview) = editor.export(canTransferToApp: store.canTransferToApp) else { return }
        PhotoLibrarySaver.copyToPasteboard(image)
        editor.showToast(preview ? IOSCopy.toastPreviewResolution : IOSCopy.toastCopied,
                          detail: preview ? IOSCopy.toastPreviewResolutionDetail : IOSCopy.toastCopiedDetail)
    }

    private func saveEditor() {
        switch editor.export(canTransferToApp: store.canTransferToApp) {
        case .handoff:
            if let url = editor.writeEncodedToTemporaryFile() {
                _ = try? store.stage(copying: [url], kind: .singleImage)
            }
            editor.showToast(IOSCopy.largeTitle, detail: store.canTransferToApp ? IOSCopy.largeBody : IOSCopy.largeInlineBody)
        case .image(let image, let preview):
            guard let data = ShotEncoder.pngData(image) else { return }
            PhotoLibrarySaver.savePNG(data) { status in
                if PhotoSaveRouter.route(for: status) == .offerCopy {
                    editor.showToast(IOSCopy.deniedTitle, detail: IOSCopy.deniedBody)
                } else {
                    editor.showToast(preview ? IOSCopy.toastPreviewResolution : IOSCopy.toastSaved,
                                      detail: preview ? IOSCopy.toastPreviewResolutionDetail : IOSCopy.toastSavedDetail)
                }
            }
        case nil:
            route = .error
        }
    }

    private func openFlattened(_ image: CGImage) {
        guard let data = ShotEncoder.pngData(image) else { return }
        editor.load(data)
        route = .editor
    }

    private func saveSegments(_ images: [CGImage]) {
        let blobs = images.compactMap { ShotEncoder.pngData($0) }
        guard !blobs.isEmpty else { return }
        var remaining = blobs.count
        for blob in blobs {
            PhotoLibrarySaver.savePNG(blob) { _ in
                remaining -= 1
                if remaining == 0 {
                    editor.showToast(IOSCopy.toastSegments(blobs.count), detail: IOSCopy.toastSavedDetail)
                }
            }
        }
    }
}

private struct ShotFile: Identifiable {
    let id = UUID()
    var label: String
    var data: Data
}

private enum AppRoute: Hashable {
    case editor
    case order
    case stitch
    case error
}
