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
    @State private var showSinglePicker = false
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
                        openFailedPage
                    }
                }
        }
        .onAppear(perform: refreshPending)
        .onOpenURL { url in
            refreshPending()
            if url.host?.lowercased() == "pick" {
                showSinglePicker = true
            }
        }
        .photosPicker(isPresented: $showSinglePicker, selection: $singleItem, matching: .images, photoLibrary: .shared())
        .fileImporter(isPresented: $showPDF, allowedContentTypes: [.pdf]) { result in
            if case .success = result {
                pdfStub = true
            }
        }
        .sheet(isPresented: $pdfStub) {
            VStack(alignment: .leading, spacing: 12) {
                Text(IOSCopy.pdfTitle).font(.title2.weight(.bold))
                Text(IOSCopy.pdfBody)
                #if DEBUG
                Text(IOSCopy.pdfPickedStub).foregroundStyle(IOSTheme.muted)
                #endif
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
                    continueShareBanner
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
                let images = StitchSourceLoader.images(from: ordered.map(\.data))
                stitch.ingest(images)
                route = .stitch
            }
            .buttonStyle(BloomButtonStyle())
            .disabled(ordered.count < 2)
            .padding(.horizontal, 16)
        }
        .navigationTitle(IOSCopy.stitchCardTitle)
    }

    /// A1b. The frame is still being drawn; this is the banner from the description.
    private var continueShareBanner: some View {
        Button(action: openPending) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(IOSTheme.bloom)
                    .frame(width: 4, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(IOSCopy.handoffBannerTitle)
                        .font(.system(size: 16, weight: .semibold))
                    Text(IOSCopy.handoffBannerDetail(count: pending.reduce(0) { $0 + $1.fileNames.count }))
                        .font(.system(size: 13))
                        .foregroundStyle(IOSTheme.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IOSTheme.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IOSTheme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(IOSTheme.bloom.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(IOSTheme.charcoal)
    }

    /// Frame 19. Reselect opens the system picker at the file's original resolution.
    private var openFailedPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text(IOSCopy.memoryFailedTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(IOSTheme.charcoal)
            Text(IOSCopy.memoryFailedBody)
                .font(.system(size: 16))
                .foregroundStyle(IOSTheme.muted)
            Button(IOSCopy.pickAgain) {
                route = nil
                showSinglePicker = true
            }
            .buttonStyle(BloomButtonStyle())
            Button(IOSCopy.backHome) { route = nil }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .foregroundStyle(IOSTheme.muted)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IOSTheme.paper)
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
                await MainActor.run { route = .error }
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
        let loaded = urls.enumerated().compactMap { index, url -> ShotFile? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return ShotFile(label: "\(index + 1)", data: data)
        }
        guard !urls.isEmpty, loaded.count == urls.count else {
            route = .error
            return
        }
        do {
            try store.confirmReceipt(ticketID: ticket.id)
        } catch {
            route = .error
            return
        }
        ordered = loaded
        refreshPending()
        if ordered.count >= 2 {
            route = .order
        } else if let first = ordered.first {
            editor.load(first.data)
            route = .editor
        }
    }

    private func copyEditor() {
        guard let image = editor.exportOriginalResolution() else {
            route = .error
            return
        }
        PhotoLibrarySaver.copyToPasteboard(image)
        editor.showToast(IOSCopy.toastCopied, detail: IOSCopy.toastCopiedDetail)
    }

    private func saveEditor() {
        guard let image = editor.exportOriginalResolution(), let data = ShotEncoder.pngData(image) else {
            route = .error
            return
        }
        PhotoLibrarySaver.savePNG(data) { status in
            if PhotoSaveRouter.route(for: status) == .offerCopy {
                editor.showToast(IOSCopy.deniedTitle, detail: IOSCopy.deniedBody)
            } else {
                editor.showToast(IOSCopy.toastSaved, detail: IOSCopy.toastSavedDetail)
            }
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
