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
            onSave: { [weak self] in self?.saveOut(forcePreview: false) },
            onStitchInApp: { [weak self] in self?.handOff() },
            onSavePreview: { [weak self] in self?.saveOut(forcePreview: true) },
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
        provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data else {
                    self.phase = .failed
                    self.refresh()
                    return
                }
                self.editor.load(data)
                self.phase = .editor
                self.refresh()
            }
        }
    }

    private func copyOut() {
        guard let image = exportedImage(forcePreview: false) else { return }
        PhotoLibrarySaver.copyToPasteboard(image)
        phase = .saved(title: IOSCopy.toastCopied, detail: IOSCopy.toastCopiedDetail)
        refresh()
        finishSoon()
    }

    private func saveOut(forcePreview: Bool) {
        if !forcePreview, case .handoff = editor.export(canTransferToApp: store.canTransferToApp) {
            showsLarge = true
            pendingKind = .singleImage
            refresh()
            return
        }
        guard let image = exportedImage(forcePreview: forcePreview), let data = ShotEncoder.pngData(image) else {
            phase = .failed
            refresh()
            return
        }
        let preview = forcePreview || editor.usingPreviewResolution
        PhotoLibrarySaver.savePNG(data) { [weak self] status in
            guard let self else { return }
            if PhotoSaveRouter.route(for: status) == .offerCopy {
                self.phase = .denied
                self.refresh()
                return
            }
            self.phase = .saved(
                title: preview ? IOSCopy.toastPreviewResolution : IOSCopy.toastSaved,
                detail: preview ? IOSCopy.toastPreviewResolutionDetail : IOSCopy.toastSavedDetail
            )
            self.refresh()
            self.finishSoon()
        }
    }

    private func exportedImage(forcePreview: Bool) -> CGImage? {
        if forcePreview { return editor.exportPreviewResolution() }
        if case .image(let image, _) = editor.export(canTransferToApp: store.canTransferToApp) {
            return image
        }
        return editor.exportPreviewResolution()
    }

    private func handOff() {
        guard store.canTransferToApp else { return }
        if pendingKind == .singleImage, let url = editor.writeEncodedToTemporaryFile() {
            _ = try? store.stage(copying: [url], kind: .singleImage)
            openApp()
            return
        }
        copyProviders { [weak self] urls in
            guard let self else { return }
            _ = try? self.store.stage(copying: urls, kind: self.pendingKind)
            self.openApp()
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

    private func openApp() {
        guard let url = URL(string: "prettyshot://handoff") else { return }
        extensionContext?.open(url) { [weak self] _ in
            self?.finishSoon()
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
