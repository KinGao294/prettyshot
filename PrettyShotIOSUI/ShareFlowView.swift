import SwiftUI

/// Frames 02–14. The extension stays on one image; several images or a PDF stop at the handoff page.
struct ShareFlowView: View {
    @ObservedObject var model: EditorModel
    var phase: SharePhase
    var showsLargeSheet: Bool
    var canTransferToApp: Bool
    var onCancel: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onStitchInApp: () -> Void
    var onSavePreview: () -> Void
    var onDismissLarge: () -> Void

    var body: some View {
        ZStack {
            switch phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text(IOSCopy.brand).foregroundStyle(IOSTheme.charcoal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(IOSTheme.paper)
            case .editor:
                EditorScreen(model: model, showsClose: true, onClose: onCancel, onCopy: onCopy, onSave: onSave)
                    .sheet(isPresented: largeBinding) { largeSheet }
            case .multi(let classification):
                multiPage(classification)
            case .failed:
                messagePage(title: IOSCopy.readFailedTitle, body: IOSCopy.readFailedBody)
            case .denied:
                deniedPage
            case .saved(let title, let detail):
                messagePage(title: title, body: detail)
            }
        }
    }

    private func multiPage(_ classification: ShareClassification) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(IOSCopy.cancel, action: onCancel)
                Spacer()
            }
            Text(title(classification))
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(IOSTheme.charcoal)
            Text(question(classification))
                .font(.system(size: 17))
            Text(IOSCopy.multiDetail)
                .font(.system(size: 14))
                .foregroundStyle(IOSTheme.muted)
            Button(IOSCopy.multiStitch, action: onStitchInApp).buttonStyle(BloomButtonStyle())
            Text(canTransferToApp ? IOSCopy.multiFootnote : IOSCopy.multiInlineFootnote)
                .font(.system(size: 12))
                .foregroundStyle(IOSTheme.muted)
            Spacer()
        }
        .padding(20)
        .background(IOSTheme.paper)
    }

    private var deniedPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(IOSCopy.deniedTitle).font(.system(size: 21, weight: .bold))
            Text(IOSCopy.deniedBody).font(.system(size: 15))
            Text(IOSCopy.deniedPath).font(.system(size: 13)).foregroundStyle(IOSTheme.muted)
            Button(IOSCopy.useCopyInstead, action: onCopy).buttonStyle(BloomButtonStyle())
            Button(IOSCopy.cancel, action: onCancel).buttonStyle(PlainCardButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(IOSTheme.paper)
    }

    private func messagePage(title: String, body: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(body).font(.system(size: 14)).multilineTextAlignment(.center).foregroundStyle(IOSTheme.muted)
            Button(IOSCopy.cancel, action: onCancel).buttonStyle(PlainCardButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IOSTheme.paper)
    }

    private var largeBinding: Binding<Bool> {
        Binding(get: { showsLargeSheet }, set: { if !$0 { onDismissLarge() } })
    }

    private var largeSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(IOSCopy.largeTitle).font(.system(size: 21, weight: .bold))
            Text(canTransferToApp ? IOSCopy.largeBody : IOSCopy.largeInlineBody)
                .font(.system(size: 15))
            if canTransferToApp {
                Button(IOSCopy.openApp, action: onStitchInApp).buttonStyle(BloomButtonStyle())
            }
            Button(IOSCopy.savePreviewAnyway, action: onSavePreview).buttonStyle(PlainCardButtonStyle())
            Button(IOSCopy.cancel, action: onDismissLarge).buttonStyle(PlainCardButtonStyle())
        }
        .padding(20)
        .presentationDetents([.medium])
    }

    private func title(_ classification: ShareClassification) -> String {
        if classification.pdfCount > 0, classification.imageCount == 0 {
            return IOSCopy.pdfShareTitle(count: classification.pdfCount)
        }
        return IOSCopy.multiTitle(count: max(classification.imageCount, 1))
    }

    private func question(_ classification: ShareClassification) -> String {
        classification.pdfCount > 0 && classification.imageCount == 0 ? IOSCopy.pdfShareQuestion : IOSCopy.multiQuestion
    }
}

enum SharePhase: Equatable {
    case loading
    case editor
    case multi(ShareClassification)
    case failed
    case denied
    case saved(title: String, detail: String)
}

extension ShareClassification {
    var pdfCount: Int {
        if case .stitch(_, let pdfs, _) = route { return pdfs }
        return 0
    }
}
