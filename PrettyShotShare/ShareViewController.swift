import UIKit
import SwiftUI

final class ShareViewController: UIViewController {
    private let editor = EditorModel()
    private let store: HandoffStore = HandoffStoreFactory.live()
    private var phase: SharePhase = .loading
    private var showsLarge = false
    private var host: UIHostingController<ShareFlowView>?
    private var providers: [NSItemProvider] = []
    private var pendingKind: HandoffKind = .stitch
    /// Stays set until the app confirms. A failed open does not clear it.
    private var stagedTicket: HandoffTicket?

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
            canTransferToApp: store.canTransferToApp,
            onCancel: { [weak self] in self?.cancel() },
            onCopy: { [weak self] in self?.copyOut() },
            onSave: { [weak self] in self?.saveOut() },
            onStitchInApp: { [weak self] in self?.beginHandoff() },
            onReselectInApp: { [weak self] in self?.openPicker() },
            onRetryHandoff: { [weak self] in self?.beginHandoff() },
            onDismissLarge: { [weak self] in
                self?.showsLarge = false
                self?.refresh()
            }
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
        case .handoff, .reselectInApp, nil:
            presentOverBudget()
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
                    self.phase = .denied
                    self.refresh()
                    return
                }
                self.phase = .saved(title: IOSCopy.toastSaved, detail: IOSCopy.toastSavedDetail)
                self.refresh()
                self.finishSoon()
            }
        case .handoff, .reselectInApp, nil:
            presentOverBudget()
        }
    }

    /// Frame 11 only when the original file can move to the app. Otherwise S10d.
    private func presentOverBudget() {
        pendingKind = .singleImage
        if store.canTransferToApp {
            showsLarge = true
        } else {
            showsLarge = false
            phase = .reselectInApp
        }
        refresh()
    }

    private func beginHandoff() {
        showsLarge = false
        phase = .handoffProgress
        refresh()
        handOff()
    }

    private func handOff() {
        if let ticket = stagedTicket {
            deliver(.waitingForApp(ticket))
            return
        }
        if pendingKind == .singleImage {
            guard let url = editor.handoffSourceURL() else {
                phase = .reselectInApp
                refresh()
                return
            }
            deliver(HandoffTransfer.persist(copying: [url], kind: .singleImage, store: store))
            return
        }
        copyProviders { [weak self] urls in
            guard let self else { return }
            self.deliver(HandoffTransfer.persist(copying: urls, kind: self.pendingKind, store: self.store))
        }
    }

    private func deliver(_ receipt: HandoffReceipt) {
        switch receipt {
        case .waitingForApp(let ticket), .interrupted(let ticket):
            stagedTicket = ticket
            guard store.canTransferToApp else {
                phase = .reselectInApp
                refresh()
                return
            }
            openApp(ticket)
        case .failed:
            phase = .reselectInApp
            refresh()
        }
    }

    private func copyProviders(done: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            let type = provider.registeredTypeIdentifiers.first { SharePayloadParser.isImage($0) || SharePayloadParser.isPDF($0) }
            guard let type else { continue }
            group.enter()
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: copy)
                lock.lock()
                urls.append(copy)
                lock.unlock()
            }
        }
        group.notify(queue: .main) { done(urls) }
    }

    private func openApp(_ ticket: HandoffTicket) {
        guard let url = URL(string: "prettyshot://handoff") else {
            phase = .reselectInApp
            refresh()
            return
        }
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                switch HandoffTransfer.resolveOpen(succeeded: success, ticket: ticket, store: self.store) {
                case .waitingForApp:
                    self.finishSoon()
                case .interrupted, .failed:
                    self.phase = .reselectInApp
                    self.refresh()
                }
            }
        }
    }

    /// Opens the in-app photo picker. Does not discard a staged ticket or the shared photo.
    private func openPicker() {
        guard let url = URL(string: "prettyshot://pick") else {
            phase = .reselectInApp
            refresh()
            return
        }
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.finishSoon()
                } else {
                    self.phase = .reselectInApp
                    self.refresh()
                }
            }
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func finishSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
