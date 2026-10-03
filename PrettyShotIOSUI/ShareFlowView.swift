import SwiftUI

/// Frames 02–14, plus S10c / S10d while those frames are still being drawn.
/// The extension stays on one image; several images or a PDF stop at the handoff page.
struct ShareFlowView: View {
    @ObservedObject var model: EditorModel
    var phase: SharePhase
    var showsLargeSheet: Bool
    var canTransferToApp: Bool
    var onCancel: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onStitchInApp: () -> Void
    var onReselectInApp: () -> Void
    var onRetryHandoff: () -> Void
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
                readFailedPage
            case .handoffProgress:
                progressPage
            case .reselectInApp:
                reselectPage
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
            Text(canTransferToApp ? IOSCopy.multiDetail : IOSCopy.reselectBody)
                .font(.system(size: 14))
                .foregroundStyle(IOSTheme.muted)
            if canTransferToApp {
                Button(IOSCopy.multiStitch, action: onStitchInApp).buttonStyle(BloomButtonStyle())
                Text(IOSCopy.multiFootnote)
                    .font(.system(size: 12))
                    .foregroundStyle(IOSTheme.muted)
            } else {
                Button(IOSCopy.reselectInApp, action: onReselectInApp).buttonStyle(BloomButtonStyle())
            }
            Spacer()
        }
        .padding(20)
        .background(IOSTheme.paper)
    }

    /// S10c. The staged file stays until the app confirms.
    private var progressPage: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(IOSCopy.handoffProgressTitle)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(IOSTheme.charcoal)
            Text(IOSCopy.handoffProgressBody)
                .font(.system(size: 15))
                .foregroundStyle(IOSTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IOSTheme.paper)
    }

    /// S10d. Primary opens the in-app picker. Nothing here deletes the shared photo.
    private var reselectPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(IOSCopy.reselectTitle).font(.system(size: 21, weight: .bold))
            Text(IOSCopy.reselectBody).font(.system(size: 15))
            Button(IOSCopy.reselectInApp, action: onReselectInApp).buttonStyle(BloomButtonStyle())
            if canTransferToApp {
                Button(IOSCopy.handoffRetry, action: onRetryHandoff).buttonStyle(PlainCardButtonStyle())
            }
            Button(IOSCopy.cancel, action: onCancel).buttonStyle(PlainCardButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(IOSTheme.paper)
    }

    /// Frame 13. 「好的」closes. The text button opens the in-app picker.
    private var readFailedPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(IOSCopy.close, action: onCancel)
                    .foregroundStyle(IOSTheme.charcoal)
                Spacer()
            }
            Spacer()
            Text(IOSCopy.readFailedTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(IOSTheme.charcoal)
            Text(IOSCopy.readFailedBody)
                .font(.system(size: 16))
                .foregroundStyle(IOSTheme.muted)
            Button(IOSCopy.readFailedOK, action: onCancel).buttonStyle(BloomButtonStyle())
            Button(IOSCopy.reselectInApp, action: onReselectInApp)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .foregroundStyle(IOSTheme.charcoal)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Frame 11, extension only, and only when the original file can be handed off.
    private var largeSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            if canTransferToApp {
                Text(IOSCopy.largeTitle).font(.system(size: 21, weight: .bold))
                Text(IOSCopy.largeBody).font(.system(size: 15))
                Button(IOSCopy.continueInApp, action: onStitchInApp).buttonStyle(BloomButtonStyle())
                Button(IOSCopy.cancel, action: onDismissLarge).buttonStyle(PlainCardButtonStyle())
            } else {
                Text(IOSCopy.reselectTitle).font(.system(size: 21, weight: .bold))
                Text(IOSCopy.reselectBody).font(.system(size: 15))
                Button(IOSCopy.reselectInApp, action: onReselectInApp).buttonStyle(BloomButtonStyle())
                Button(IOSCopy.cancel, action: onDismissLarge).buttonStyle(PlainCardButtonStyle())
            }
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
    /// S10c. A ticket may already be staged. This phase does not discard it.
    case handoffProgress
    /// S10d. The photo library original stays. The user reselects it in the app.
    case reselectInApp
}

extension ShareClassification {
    var pdfCount: Int {
        if case .stitch(_, let pdfs, _) = route { return pdfs }
        return 0
    }
}
