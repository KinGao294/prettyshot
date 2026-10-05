import PhotosUI
import PrettyShotCore
import SwiftUI
import UIKit
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
    @State private var showStitchPicker = false
    @State private var showReaddPicker = false
    @State private var readdItem: PhotosPickerItem?
    @State private var readdOrdinal: Int?
    @State private var failedPickCount = 1
    @State private var showPhotoDenied = false
    @State private var missingOrdinals: [Int] = []
    @State private var expectedTotal = 0
    private let store: HandoffStore = HandoffStoreFactory.live()

    var body: some View {
        NavigationStack {
            home
                .navigationDestination(item: $route) { destination in
                    switch destination {
                    case .editor:
                        EditorScreen(
                            model: editor,
                            showsClose: true,
                            onClose: { route = nil },
                            onCopy: copyEditor,
                            onSave: saveEditor,
                            missingLine: missingOrdinals.isEmpty ? nil : IOSCopy.missingEditorLine(missingOrdinals),
                            missingOrdinals: missingOrdinals,
                            onReadd: beginReadd
                        )
                            .navigationBarHidden(true)
                            .task(id: editor.toastTitle) { await dismissReaddToastIfNeeded() }
                    case .order:
                        orderScreen
                    case .stitch:
                        StitchScreen(
                            model: stitch,
                            onBack: { route = nil },
                            onBeautify: openFlattened,
                            onExportSegments: saveSegments,
                            missingLine: missingOrdinals.isEmpty ? nil : IOSCopy.missingBanner(missingOrdinals),
                            missingOrdinals: missingOrdinals,
                            onReadd: beginReadd,
                            readdToastTitle: editor.toastDetail == nil ? editor.toastTitle : nil
                        )
                            .navigationBarHidden(true)
                            .task(id: editor.toastTitle) { await dismissReaddToastIfNeeded() }
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
            if let ticket = HandoffLaunch.ticketToOpen(host: url.host, pending: pending) {
                openHandedOff(ticket)
            }
        }
        .photosPicker(isPresented: $showSinglePicker, selection: $singleItem, matching: .images, photoLibrary: .shared())
        .photosPicker(isPresented: $showStitchPicker, selection: $stitchItems, maxSelectionCount: 20, matching: .images, photoLibrary: .shared())
        .photosPicker(isPresented: $showReaddPicker, selection: $readdItem, matching: .images, photoLibrary: .shared())
        .onChange(of: readdItem) { _, item in
            guard let item else { return }
            Task { await loadReadd(item) }
        }
        .sheet(isPresented: $showPhotoDenied) { photoDeniedSheet }
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IOSTheme.bloomInk)
                Text(IOSCopy.brand)
                    .font(.system(size: 34, weight: .bold))
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
            if !missingOrdinals.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(IOSCopy.missingBanner(missingOrdinals))
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(missingOrdinals, id: \.self) { ordinal in
                        Button("\(IOSCopy.readdShot) · 第 \(ordinal) 张") { beginReadd(ordinal) }
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(IOSTheme.warn.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            }
            Text(IOSCopy.stitchOrderHint).font(.system(size: 13)).foregroundStyle(IOSTheme.muted)
            List {
                ForEach(ordered) { shot in
                    Text(shot.label)
                }
                .onMove { ordered.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.editMode, .constant(.active))
            Button(IOSCopy.stitchStart) {
                let loaded = StitchSourceLoader.load(ordered.map(\.data))
                if !loaded.missingOrdinals.isEmpty {
                    missingOrdinals = Array(Set(missingOrdinals + loaded.missingOrdinals)).sorted()
                }
                guard loaded.images.count >= 2 else {
                    route = .error
                    return
                }
                ingestLoaded(loaded, from: ordered)
                route = .stitch
            }
            .buttonStyle(BloomButtonStyle())
            .disabled(ordered.count < 2)
            .padding(.horizontal, 16)
        }
        .overlay(alignment: .top) {
            if ReaddToast.draws(on: .order), editor.toastDetail == nil, let title = editor.toastTitle {
                SuccessToastBanner(title: title)
            }
        }
        .task(id: editor.toastTitle) { await dismissReaddToastIfNeeded() }
        .navigationTitle(IOSCopy.stitchCardTitle)
    }

    /// A1b. 「继续拼接」opens the staged shots. 「不用了」drops the staged copies only.
    private var continueShareBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundStyle(IOSTheme.charcoal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(IOSCopy.handoffBannerTitle)
                        .font(.system(size: 16, weight: .semibold))
                    Text(IOSCopy.handoffBannerDetail(for: pending))
                        .font(.system(size: 13))
                        .foregroundStyle(IOSTheme.muted)
                }
            }
            HStack(spacing: 16) {
                Button(IOSCopy.continueStitch, action: openPending)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(IOSTheme.bloom, in: Capsule())
                    .foregroundStyle(IOSTheme.bloomInk)
                Button(IOSCopy.dismissPending, action: dismissPending)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(IOSTheme.charcoal)
            }
            Text(IOSCopy.bannerFootnote)
                .font(.system(size: 12))
                .foregroundStyle(IOSTheme.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSTheme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(IOSTheme.hairline))
    }

    /// Frame 31. 「稍后再说」dismisses the sheet and keeps the edit.
    private var photoDeniedSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(IOSCopy.deniedTitle).font(.system(size: 21, weight: .bold))
            Text(IOSCopy.deniedBody).font(.system(size: 15))
            Text(IOSCopy.deniedPath).font(.system(size: 13)).foregroundStyle(IOSTheme.muted)
            ForEach(PhotoDeniedAction.actions(inApp: true), id: \.self) { action in
                switch action {
                case .useCopyInstead:
                    Button(action.title) {
                        showPhotoDenied = false
                        copyEditor()
                    }
                    .buttonStyle(BloomButtonStyle())
                case .openSettings:
                    Button(action.title, action: openSettings).buttonStyle(PlainCardButtonStyle())
                case .later:
                    Button(action.title) { showPhotoDenied = false }.buttonStyle(PlainCardButtonStyle())
                }
            }
        }
        .padding(20)
        .presentationDetents([.medium])
    }

    /// Frame 19 for one image. A multi-image pick that could not be read uses the multi-image copy
    /// and reopens the multi-image picker. 「重新选图」 is the same button label either way.
    private var openFailedPage: some View {
        let multi = InAppStitchLoader.reselectOpensMultiPicker(pickedCount: failedPickCount)
        return VStack(alignment: .leading, spacing: 16) {
            Spacer()
            Text(InAppStitchLoader.errorTitle(pickedCount: failedPickCount))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(IOSTheme.charcoal)
            Text(InAppStitchLoader.errorBody(pickedCount: failedPickCount))
                .font(.system(size: 16))
                .foregroundStyle(IOSTheme.muted)
            Button(IOSCopy.pickAgain) {
                route = nil
                if multi {
                    stitchItems = []
                    showStitchPicker = true
                } else {
                    showSinglePicker = true
                }
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
            guard let data = try await item.loadTransferable(type: Data.self), ImagePrep.fullImage(data) != nil else {
                await MainActor.run {
                    failedPickCount = 1
                    route = .error
                }
                return
            }
            await MainActor.run {
                let cleared = MissingShotSession.beginNewPick(
                    replacing: MissingShotSession(ordinals: missingOrdinals, expectedTotal: expectedTotal),
                    failedOrdinals: [],
                    loadedCount: 1
                )
                missingOrdinals = cleared.ordinals
                expectedTotal = cleared.expectedTotal
                editor.load(data)
                route = .editor
            }
        } catch {
            await MainActor.run {
                failedPickCount = 1
                route = .error
            }
        }
    }

    private func loadStitch(_ items: [PhotosPickerItem]) async {
        var files: [ShotFile] = []
        var failed: [Int] = []
        for (index, item) in items.enumerated() {
            if let data = try? await item.loadTransferable(type: Data.self), ImagePrep.fullImage(data) != nil {
                let ordinal = index + 1
                files.append(ShotFile(
                    label: "\(ordinal)",
                    data: data,
                    capturedAt: ImagePrep.captureDate(data),
                    originalOrdinal: ordinal
                ))
            } else {
                failed.append(index + 1)
            }
        }
        let outcome = InAppStitchLoader.outcome(readableCount: files.count, failedOrdinals: failed)
        await MainActor.run {
            let session = MissingShotSession.beginNewPick(
                replacing: MissingShotSession(ordinals: missingOrdinals, expectedTotal: expectedTotal),
                failedOrdinals: failed,
                loadedCount: files.count
            )
            missingOrdinals = session.ordinals
            expectedTotal = session.expectedTotal
            ordered = files
            switch outcome {
            case .ready, .missing:
                route = .order
            case .failed:
                failedPickCount = items.count
                route = .error
            }
        }
    }

    private func refreshPending() {
        pending = (try? store.pendingTickets()) ?? []
    }

    private func dismissPending() {
        for ticket in pending {
            HandoffCancellation.abort(ticketID: ticket.id, store: store)
        }
        refreshPending()
    }

    private func dismissReaddToastIfNeeded() async {
        guard editor.toastTitle != nil, editor.toastDetail == nil else { return }
        let title = editor.toastTitle
        try? await Task.sleep(nanoseconds: UInt64(ReaddToast.dismissAfter * 1_000_000_000))
        guard editor.toastTitle == title else { return }
        editor.expireToast(after: ReaddToast.dismissAfter)
    }

    private func beginReadd(_ ordinal: Int) {
        readdOrdinal = ordinal
        showReaddPicker = true
    }

    private func loadReadd(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await MainActor.run { insertReadded(data) }
    }

    private func insertReadded(_ data: Data) {
        guard let ordinal = readdOrdinal else { return }
        let step = MissingShotSession(ordinals: missingOrdinals, expectedTotal: expectedTotal).addingBack(ordinal: ordinal)
        guard step.restored == ordinal else { return }
        readdOrdinal = nil
        let date = ImagePrep.captureDate(data)
        let shot = ShotFile(label: "\(ordinal)", data: data, capturedAt: date, originalOrdinal: ordinal)
        let mapped = ordered.map {
            OrderedShot(id: $0.id.uuidString, capturedAt: $0.capturedAt, globalOrdinal: $0.originalOrdinal)
        }
        let placed = ShotOrdering.inserting(
            OrderedShot(id: shot.id.uuidString, capturedAt: date, globalOrdinal: ordinal),
            into: mapped,
            missingOrdinal: ordinal
        )
        var byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id.uuidString, $0) })
        byID[shot.id.uuidString] = shot
        ordered = placed.compactMap { byID[$0.id] }
        for index in ordered.indices {
            ordered[index].label = "\(ordered[index].originalOrdinal)"
        }
        let total = max(expectedTotal, ordered.count)
        missingOrdinals = step.session.ordinals
        readdItem = nil
        if missingOrdinals.isEmpty {
            editor.showReaddToast(IOSCopy.addedBack(ordinal: ordinal, total: total))
        } else {
            editor.showReaddToast(IOSCopy.addedBackStillMissing(ordinal: ordinal, stillMissing: missingOrdinals.count))
        }
        if route == .stitch || route == .editor {
            let loaded = StitchSourceLoader.load(ordered.map(\.data))
            if loaded.images.count >= 2 {
                ingestLoaded(loaded, from: ordered)
                route = .stitch
            }
        }
    }

    private func ingestLoaded(_ loaded: LoadedStitchSources, from files: [ShotFile]) {
        let missingIndexes = Set(loaded.missingOrdinals)
        let ordinals = files.enumerated().compactMap { index, file -> Int? in
            missingIndexes.contains(index + 1) ? nil : file.originalOrdinal
        }
        stitch.ingest(loaded.images, ordinals: ordinals)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func openPending() {
        let tickets = PendingShareResume.ordered(pending)
        guard !tickets.isEmpty else { return }
        let data: [Data]
        do {
            data = try ReceiptConfirmation.imageData(of: tickets, store: store)
        } catch {
            route = .error
            return
        }
        guard !data.isEmpty else {
            refreshPending()
            return
        }
        let ordinals = PendingShareResume.globalFileOrdinals(tickets)
        let loaded = data.enumerated().map { index, blob in
            let ordinal = index < ordinals.count ? ordinals[index] : index + 1
            return ShotFile(
                label: "\(ordinal)",
                data: blob,
                capturedAt: ImagePrep.captureDate(blob),
                originalOrdinal: ordinal
            )
        }
        let missing = tickets.flatMap { $0.missingShots.map(\.ordinal) }
        let session = MissingShotSession.remember(
            failedOrdinals: missing,
            loadedCount: loaded.count
        )
        missingOrdinals = session.ordinals
        expectedTotal = session.expectedTotal
        ordered = loaded
        refreshPending()
        if ordered.count >= 2 {
            route = .order
        } else if let first = ordered.first {
            editor.load(first.data)
            route = .editor
        }
    }

    /// A4. The large image from frame 11 opens in the editor at full resolution.
    /// If its file cannot be read, the ticket stays pending and the home banner still offers it.
    private func openHandedOff(_ ticket: HandoffTicket) {
        guard let data = try? ReceiptConfirmation.imageData(of: [ticket], store: store),
              let first = data.first else {
            refreshPending()
            return
        }
        missingOrdinals = []
        expectedTotal = 0
        ordered = []
        editor.load(first)
        refreshPending()
        route = .editor
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
                showPhotoDenied = true
            } else {
                editor.showToast(IOSCopy.toastSaved, detail: IOSCopy.inAppSavedDetail)
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
                    editor.showToast(IOSCopy.toastSegments(blobs.count), detail: IOSCopy.inAppSavedDetail)
                }
            }
        }
    }
}

private struct ShotFile: Identifiable {
    let id = UUID()
    var label: String
    var data: Data
    var capturedAt: Date? = nil
    /// Original 1-based position. Re-adding inserts by this, never by capture time.
    var originalOrdinal: Int = 0
}

private enum AppRoute: Hashable {
    case editor
    case order
    case stitch
    case error
}
