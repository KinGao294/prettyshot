import UIKit
import SwiftUI

final class ShareViewController: UIViewController {
    private let editor = EditorModel()
    private let store: HandoffStore = HandoffStoreFactory.live()
    private var phase: SharePhase = .loading
    private var showsLarge = false
    private var showsDenied = false
    private var host: UIHostingController<ShareFlowView>?
    private var providers: [NSItemProvider] = []
    private var pendingKind: HandoffKind = .stitch
    /// Stays set until the app confirms, or the user cancels the handoff.
    private var stagedTicket: HandoffTicket?
    /// Temp copies from this attempt. Cancel deletes these, not the photo-library originals.
    private var attemptCopies: [URL] = []
    private var gathered: GatheredShareFiles?
    /// S12. True after a multi-image open failed and nothing was staged.
    private var showsS12OpenHint = false
    /// Frame 13. The picker failed to open while the read-failed page was showing.
    private var showsReadFailedOpenHint = false
    /// S10f body for a multi-image or PDF share.
    private var showsMultiInlineFootnote = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: rootView())
        self.host = host
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        classify()
    }

    private func rootView() -> ShareFlowView {
        ShareFlowView(
            model: editor,
            phase: phase,
            showsLargeSheet: showsLarge,
            showsDeniedSheet: showsDenied,
            canTransferToApp: store.canTransferToApp,
            onCancel: { [weak self] in self?.cancel() },
            onCopy: { [weak self] in self?.copyOut() },
            onSave: { [weak self] in self?.saveOut() },
            onStitchInApp: { [weak self] in self?.beginPrimaryHandoff() },
            onReselectInApp: { [weak self] in self?.openPicker() },
            onRetryHandoff: { [weak self] in self?.retryHandoff() },
            onContinuePartial: { [weak self] in self?.continuePartial() },
            onCancelHandoff: { [weak self] in self?.cancelHandoff() },
            onDismissLarge: { [weak self] in
                self?.keepEditsAndDismissLarge()
            },
            onShrinkPadding: { [weak self] in
                // 11b: same as 「取消」 (all edits kept), then S5 with the padding slider in view.
                self?.keepEditsAndDismissLarge()
                self?.editor.openPaddingControl()
                self?.refresh()
            },
            onDismissDenied: { [weak self] in
                self?.showsDenied = false
                self?.phase = .editor
                self?.refresh()
            },
            onOpenSettings: { [weak self] in self?.openSettings() },
            showsS12OpenHint: showsS12OpenHint,
            showsReadFailedOpenHint: showsReadFailedOpenHint,
            showsMultiInlineFootnote: showsMultiInlineFootnote
        )
    }

    private func refresh() {
        host?.rootView = rootView()
    }

    private func classify() {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        var attachments: [ShareAttachment] = []
        providers = []
        for item in items {
            for provider in item.attachments ?? [] {
                attachments.append(ShareAttachment(typeIdentifiers: provider.registeredTypeIdentifiers))
                providers.append(provider)
            }
        }
        let classification = SharePayloadParser.classify(attachments)
        switch classification.route {
        case .empty, .unreadable:
            phase = .failed
        case .singleImage:
            pendingKind = .singleImage
            loadFirstImage()
            return
        case .stitch(_, let pdfs, _):
            pendingKind = pdfs > 0 && classification.imageCount == 0 ? .pdf : .stitch
            phase = .multi(classification)
        }
        refresh()
    }

    private func loadFirstImage() {
        guard let provider = providers.first(where: { SharePayloadParser.kind($0.registeredTypeIdentifiers) == .image }),
              let type = provider.registeredTypeIdentifiers.first(where: SharePayloadParser.isImage) else {
            phase = .failed
            refresh()
            return
        }
        provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, _ in
            let copied = url.flatMap { source -> URL? in
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: source, to: dest)
                    return dest
                } catch {
                    return nil
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let copied else {
                    self.phase = .failed
                    self.refresh()
                    return
                }
                self.editor.load(fileURL: copied)
                self.phase = .editor
                self.refresh()
            }
        }
    }

    private func copyOut() {
        switch editor.export(canTransferToApp: store.canTransferToApp) {
        case .image(let image):
            PhotoLibrarySaver.copyToPasteboard(image)
            phase = .saved(title: IOSCopy.toastCopied, detail: IOSCopy.toastCopiedDetail)
            refresh()
            finishSoon()
        case .handoff:
            presentOverBudget()
        case .reselectInApp, nil:
            presentCannotHandOff()
        }
    }

    private func saveOut() {
        switch editor.export(canTransferToApp: store.canTransferToApp) {
        case .image(let image):
            guard let data = ShotEncoder.pngData(image) else {
                phase = .failed
                refresh()
                return
            }
            PhotoLibrarySaver.savePNG(data) { [weak self] status in
                guard let self else { return }
                if PhotoSaveRouter.route(for: status) == .offerCopy {
                    self.showsDenied = true
                    self.phase = .editor
                    self.refresh()
                    return
                }
                self.phase = .saved(title: IOSCopy.toastSaved, detail: IOSCopy.toastSavedDetail)
                self.refresh()
                self.finishSoon()
            }
        case .handoff:
            presentOverBudget()
        case .reselectInApp, nil:
            presentCannotHandOff()
        }
    }

    /// Frame 11 when the original file can move to the app. Otherwise S10f. Never a smaller bitmap.
    private func presentOverBudget() {
        pendingKind = .singleImage
        showsDenied = false
        if store.canTransferToApp {
            showsLarge = true
        } else {
            showsLarge = false
            phase = .cannotHandOff(manualOpenHint: false)
        }
        refresh()
    }

    private func presentCannotHandOff(multiFootnote: Bool = false) {
        showsLarge = false
        showsDenied = false
        showsS12OpenHint = false
        showsMultiInlineFootnote = multiFootnote
        phase = .cannotHandOff(manualOpenHint: false)
        refresh()
    }

    private func keepEditsAndDismissLarge() {
        let kept = Frame11Cancel.preserved(
            padding: editor.style.padding,
            arrowCount: editor.arrows.count,
            redactionCount: editor.redactions.count,
            removeStatusBar: editor.removeStatusBar
        )
        editor.style.padding = kept.padding
        editor.removeStatusBar = kept.removeStatusBar
        editor.arrows = Array(editor.arrows.prefix(kept.arrowCount))
        editor.redactions = Array(editor.redactions.prefix(kept.redactionCount))
        showsLarge = false
        refresh()
    }

    private func beginPrimaryHandoff() {
        if pendingKind == .singleImage {
            beginSingleHandoff()
        } else {
            beginMultiHandoff()
        }
    }

    private func beginMultiHandoff() {
        if !store.canTransferToApp {
            let stagedCount = stagedTicket?.fileNames.count ?? 0
            switch S12Launch.afterOpenFailed(stagedFileCount: stagedCount) {
            case .stayOnMultiPage:
                showsS12OpenHint = true
                refresh()
            case .notThisPage:
                phase = .stagedAwaitingApp(count: stagedCount)
                refresh()
            case .reselectOnS10f:
                presentCannotHandOff(multiFootnote: pendingKind != .singleImage)
            }
            return
        }
        showsLarge = false
        copyProviders()
    }

    private func retryHandoff() {
        ExtensionLaunchRouter.prepareRetry(previousTicketID: stagedTicket?.id, store: store)
        stagedTicket = nil
        if pendingKind == .singleImage {
            beginSingleHandoff()
        } else {
            beginMultiHandoff()
        }
    }

    private func beginSingleHandoff() {
        showsLarge = false
        guard let url = editor.handoffSourceURL() else {
            phase = .handoffFailed
            refresh()
            return
        }
        phase = .handoffProgress(copied: 0, total: 1, received: 1)
        refresh()
        attemptCopies = [url]
        phase = .handoffProgress(copied: 1, total: 1, received: 1)
        deliver(HandoffTransfer.persist(copying: [url], kind: .singleImage, store: store))
    }

    private func continuePartial() {
        guard let gathered else {
            phase = .handoffFailed
            refresh()
            return
        }
        if !store.canTransferToApp {
            presentCannotHandOff()
            return
        }
        let urls = gathered.loaded.map(\.url)
        let missing = gathered.missingOrdinals.map { MissingShot(ordinal: $0) }
        phase = .handoffProgress(copied: urls.count, total: urls.count + missing.count, received: urls.count + missing.count)
        refresh()
        deliver(HandoffTransfer.persist(copying: urls, kind: pendingKind, store: store, missingShots: missing))
    }

    private func deliver(_ receipt: HandoffReceipt) {
        switch receipt {
        case .waitingForApp(let ticket), .interrupted(let ticket):
            stagedTicket = ticket
            guard store.canTransferToApp else {
                phase = .cannotHandOff(manualOpenHint: false)
                refresh()
                return
            }
            openApp(ticket)
        case .failed:
            phase = .handoffFailed
            refresh()
        }
    }

    private func copyProviders() {
        let targets: [(ordinal: Int, provider: NSItemProvider, type: String)] = providers.enumerated().compactMap { index, provider in
            guard let type = provider.registeredTypeIdentifiers.first(where: { SharePayloadParser.isImage($0) || SharePayloadParser.isPDF($0) }) else {
                return nil
            }
            return (index + 1, provider, type)
        }
        let total = targets.count
        phase = .handoffProgress(copied: 0, total: max(total, 1), received: total)
        refresh()
        let group = DispatchGroup()
        let lock = NSLock()
        var copies: [(ordinal: Int, url: URL?)] = []
        for target in targets {
            group.enter()
            target.provider.loadFileRepresentation(forTypeIdentifier: target.type) { [weak self] url, _ in
                let copied: URL?
                if let url {
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                    copied = (try? FileManager.default.copyItem(at: url, to: dest)) == nil ? nil : dest
                } else {
                    copied = nil
                }
                lock.lock()
                copies.append((target.ordinal, copied))
                let done = copies.filter { $0.url != nil }.count
                lock.unlock()
                DispatchQueue.main.async {
                    self?.attemptCopies.append(contentsOf: copied.map { [$0] } ?? [])
                    self?.phase = .handoffProgress(copied: done, total: max(total, 1), received: total)
                    self?.refresh()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let ordered = copies.sorted { $0.ordinal < $1.ordinal }
            let gathered = ShareFileGather.gather(ordered)
            self.gathered = gathered
            if gathered.loaded.isEmpty {
                self.phase = .handoffFailed
                self.refresh()
                return
            }
            if !gathered.missingOrdinals.isEmpty {
                self.phase = .handoffPartial(
                    received: total,
                    missingCount: gathered.missingOrdinals.count,
                    firstOrdinal: gathered.missingOrdinals[0],
                    loaded: gathered.loadedCount
                )
                self.refresh()
                return
            }
            self.deliver(HandoffTransfer.persist(copying: gathered.loaded.map(\.url), kind: self.pendingKind, store: self.store))
        }
    }

    private func openApp(_ ticket: HandoffTicket) {
        guard let url = URL(string: "prettyshot://handoff") else {
            phase = .stagedAwaitingApp(count: ticket.fileNames.count)
            refresh()
            return
        }
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                switch ExtensionLaunchRouter.afterHandoffOpen(succeeded: success, ticket: ticket, store: self.store) {
                case .opened:
                    self.finishSoon()
                case .stagedNeedsManualOpen(let count):
                    self.phase = .stagedAwaitingApp(count: count)
                    self.refresh()
                case .stagingFailed:
                    self.phase = .handoffFailed
                    self.refresh()
                }
            }
        }
    }

    /// Opens the in-app photo picker. Does not discard a staged ticket or the shared photo.
    /// Failure stays on S10f. It does not stage a file and does not switch to S10d.
    private func openPicker() {
        let fromReadFailedPage = phase == .failed
        guard let url = URL(string: "prettyshot://pick") else {
            applyPickerOutcome(.stayAndAskToOpenApp, fromReadFailedPage: fromReadFailedPage)
            return
        }
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                let outcome = ExtensionLaunchRouter.afterPickerOpen(
                    succeeded: success,
                    fromReadFailedPage: fromReadFailedPage
                )
                self.applyPickerOutcome(outcome, fromReadFailedPage: fromReadFailedPage)
            }
        }
    }

    private func applyPickerOutcome(_ outcome: PickerLaunchOutcome, fromReadFailedPage: Bool) {
        switch outcome {
        case .opened:
            finishSoon()
        case .stayOnReadFailedPage:
            phase = .failed
            showsReadFailedOpenHint = true
            refresh()
        case .stayAndAskToOpenApp:
            if fromReadFailedPage {
                phase = .failed
                showsReadFailedOpenHint = true
            } else {
                phase = .cannotHandOff(manualOpenHint: true)
            }
            refresh()
        }
    }

    /// S10c cancel. Clears this attempt's staged copies. The album original stays.
    private func cancelHandoff() {
        HandoffCancellation.abort(ticketID: stagedTicket?.id, store: store)
        stagedTicket = nil
        for url in attemptCopies {
            try? FileManager.default.removeItem(at: url)
        }
        attemptCopies = []
        cancel()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        extensionContext?.open(url, completionHandler: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func finishSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + ExtensionSavedToast.dismissAfter) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
