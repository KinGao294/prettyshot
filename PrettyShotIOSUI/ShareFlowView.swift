import SwiftUI

/// Frames 02–14, 11, 14, and S10c–S10f.
/// The extension stays on one image; several images or a PDF are handed to the app.
struct ShareFlowView: View {
    @ObservedObject var model: EditorModel
    var phase: SharePhase
    var showsLargeSheet: Bool
    var showsDeniedSheet: Bool
    var canTransferToApp: Bool
    var onCancel: () -> Void
    var onCopy: () -> Void
    var onSave: () -> Void
    var onStitchInApp: () -> Void
    var onReselectInApp: () -> Void
    var onRetryHandoff: () -> Void
    var onContinuePartial: () -> Void
    var onCancelHandoff: () -> Void
    var onDismissLarge: () -> Void
    var onDismissDenied: () -> Void
    var onOpenSettings: () -> Void
    /// S12. Set when the app did not open and nothing was staged. The page stays `.multi`.
    var showsS12OpenHint = false
    /// Frame 13. Opening the app from the read-failed page failed.
    var showsReadFailedOpenHint = false
    /// S10f for a multi-image or PDF share that cannot hand files to the app.
    var showsMultiInlineFootnote = false

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
                EditorScreen(
                    model: model,
                    showsClose: true,
                    onClose: onCancel,
                    onCopy: onCopy,
                    onSave: onSave,
                    showsPreviewDownsampleChip: PreviewDownsampleChip.shows(
                        inExtension: true,
                        pixelWidth: model.pixelWidth,
                        pixelHeight: model.pixelHeight,
                        canTransferToApp: canTransferToApp
                    )
                )
                    .sheet(isPresented: largeBinding) { largeSheet }
                    .sheet(isPresented: deniedBinding) { deniedSheet }
            case .multi(let classification):
                multiPage(classification)
            case .failed:
                readFailedPage
            case .handoffProgress(let copied, let total, let received):
                progressPage(copied: copied, total: total, received: received)
            case .handoffFailed:
                handoffFailedPage
            case .stagedAwaitingApp(let count):
                stagedPage(count: count)
            case .handoffPartial(let received, let missingCount, let firstOrdinal, let loaded):
                partialPage(received: received, missingCount: missingCount, firstOrdinal: firstOrdinal, loaded: loaded)
            case .cannotHandOff(let manualOpenHint):
                cannotHandOffPage(manualOpenHint: manualOpenHint)
            case .saved(let title, let detail):
                messagePage(title: title, body: detail, showsButton: ExtensionSavedToast.hasButtons)
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
            if showsS12OpenHint {
                Text(IOSCopy.s12OpenFailedHint)
                    .font(.system(size: 14))
                    .foregroundStyle(IOSTheme.charcoal)
            }
            if canTransferToApp {
                Text(IOSCopy.multiFootnote)
                    .font(.system(size: 12))
                    .foregroundStyle(IOSTheme.muted)
            }
            Spacer()
        }
        .padding(20)
        .background(IOSTheme.paper)
    }

    /// S10c. Cancel drops this attempt's staged copies and leaves the photo-library original alone.
    private func progressPage(copied: Int, total: Int, received: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(IOSCopy.receivedShots(received))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(IOSTheme.bloomInk)
            Text(IOSCopy.handoffProgressTitle)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(IOSTheme.charcoal)
            ProgressView(value: total == 0 ? 0 : Double(copied) / Double(total))
                .tint(IOSTheme.bloom)
            HStack {
                Text(IOSCopy.progressCount(done: max(copied, 1), total: max(total, 1)))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(IOSCopy.copyingToStaging)
                    .font(.system(size: 13))
                    .foregroundStyle(IOSTheme.muted)
            }
            Text(IOSCopy.handoffProgressBody)
                .font(.system(size: 14))
                .foregroundStyle(IOSTheme.charcoal)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(IOSTheme.card, in: RoundedRectangle(cornerRadius: 14))
            Spacer()
            Button(IOSCopy.cancel, action: onCancelHandoff)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .foregroundStyle(IOSTheme.charcoal)
            Text(IOSCopy.cancelHandoffNote)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(IOSTheme.muted)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(IOSTheme.paper)
    }

    /// S10d. The staged ticket stays so retry can run. 「关闭」 leaves it for the app.
    private var handoffFailedPage: some View {
        VStack(spacing: 16) {
            HStack {
                Button(IOSCopy.close, action: onCancel)
                Spacer()
            }
            Spacer()
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundStyle(IOSTheme.muted)
                .frame(width: 88, height: 108)
                .background(IOSTheme.card, in: RoundedRectangle(cornerRadius: 16))
            Text(IOSCopy.handoffFailedTitle)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            Text(IOSCopy.handoffFailedBody)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(IOSTheme.muted)
            Button(IOSCopy.retry, action: onRetryHandoff).buttonStyle(BloomButtonStyle())
            Button(IOSCopy.reselectInApp, action: onReselectInApp)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IOSTheme.charcoal)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IOSTheme.paper)
    }

    /// S10e. Continuing hands the loaded files to the app and remembers which shot is missing.
    private func partialPage(received: Int, missingCount: Int, firstOrdinal: Int, loaded: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(IOSCopy.cancel, action: onCancel)
                Spacer()
            }
            Text(IOSCopy.partialEyebrow)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(IOSTheme.warn)
            Text(IOSCopy.partialTitle(received: received, missing: missingCount))
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(IOSTheme.charcoal)
            Text(IOSCopy.partialFailure(firstOrdinal))
                .font(.system(size: 14))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(IOSTheme.warn.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            Spacer()
            Button(IOSCopy.continuePartial(loaded), action: onContinuePartial).buttonStyle(BloomButtonStyle())
            Button(IOSCopy.retry, action: onRetryHandoff).buttonStyle(PlainCardButtonStyle())
            Text(IOSCopy.retryReadsAll(received))
                .font(.system(size: 12))
                .foregroundStyle(IOSTheme.muted)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IOSTheme.paper)
    }

    /// Frame 63b. The files are staged. 「关闭」 and 「好的」 both leave them for A1b. There is no retry.
    private func stagedPage(count: Int) -> some View {
        VStack(spacing: 16) {
            HStack {
                Button(IOSCopy.close, action: onCancel)
                    .foregroundStyle(IOSTheme.charcoal)
                Spacer()
                Text(IOSCopy.brand)
                    .font(.system(size: 16.5, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            Spacer()
            Image(systemName: "checkmark")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(IOSTheme.stagedCheck)
                .frame(width: 96, height: 96)
                .background(IOSTheme.stagedCircle, in: Circle())
            Text(IOSCopy.stagedTitle(count))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(IOSTheme.charcoal)
            Text(IOSCopy.stagedBody(count: count))
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(IOSTheme.muted)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(IOSTheme.muted)
                Text(IOSCopy.stagedHint)
                    .font(.system(size: 13))
                    .foregroundStyle(IOSTheme.muted)
                    .multilineTextAlignment(.leading)
            }
            Button(IOSCopy.readFailedOK, action: onCancel).buttonStyle(BloomButtonStyle())
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IOSTheme.paper)
    }

    /// S10f. No App Group, so the original cannot move. The photo library copy is untouched.
    /// If opening the app fails, stay on this page. Do not switch to S10d.
    private func cannotHandOffPage(manualOpenHint: Bool) -> some View {
        VStack(spacing: 16) {
            HStack {
                Button(IOSCopy.close, action: onCancel)
                Spacer()
            }
            Spacer()
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundStyle(IOSTheme.muted)
                .frame(width: 88, height: 108)
                .background(IOSTheme.card, in: RoundedRectangle(cornerRadius: 16))
            Text(IOSCopy.cannotHandTitle)
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
            Text(showsMultiInlineFootnote ? IOSCopy.multiInlineFootnote : IOSCopy.cannotHandBody)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(IOSTheme.muted)
            if manualOpenHint {
                Text(IOSCopy.pickerOpenFailedHint)
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(IOSTheme.charcoal)
            }
            Button(IOSCopy.reselectInApp, action: onReselectInApp).buttonStyle(BloomButtonStyle())
            Button(IOSCopy.readFailedOK, action: onCancel)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(IOSTheme.charcoal)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IOSTheme.paper)
    }

    /// Frame 13.
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
            if showsReadFailedOpenHint {
                Text(IOSCopy.s12OpenFailedHint)
                    .font(.system(size: 14))
                    .foregroundStyle(IOSTheme.charcoal)
            }
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

    /// Frame 14. No 「前往设置开启」. The settings path stays as a line of text.
    /// 「稍后再说」 returns to the editor and keeps the edits.
    private var deniedSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(IOSCopy.deniedTitle).font(.system(size: 21, weight: .bold))
            Text(IOSCopy.deniedBody).font(.system(size: 15))
            Text(IOSCopy.deniedPath).font(.system(size: 13)).foregroundStyle(IOSTheme.muted)
            ForEach(PhotoDeniedAction.actions(inApp: false), id: \.self) { action in
                deniedButton(action)
            }
        }
        .padding(20)
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private func deniedButton(_ action: PhotoDeniedAction) -> some View {
        switch action {
        case .useCopyInstead:
            Button(action.title, action: onCopy).buttonStyle(BloomButtonStyle())
        case .openSettings:
            Button(action.title, action: onOpenSettings).buttonStyle(PlainCardButtonStyle())
        case .later:
            Button(action.title, action: onDismissDenied).buttonStyle(PlainCardButtonStyle())
        }
    }

    private func messagePage(title: String, body: String, showsButton: Bool) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(body).font(.system(size: 14)).multilineTextAlignment(.center).foregroundStyle(IOSTheme.muted)
            if showsButton {
                Button(IOSCopy.cancel, action: onCancel).buttonStyle(PlainCardButtonStyle())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IOSTheme.paper)
    }

    private var largeBinding: Binding<Bool> {
        Binding(get: { showsLargeSheet }, set: { if !$0 { onDismissLarge() } })
    }

    private var deniedBinding: Binding<Bool> {
        Binding(get: { showsDeniedSheet }, set: { if !$0 { onDismissDenied() } })
    }

    /// Frame 11, extension only, and only when the original file can be handed off.
    private var largeSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(IOSCopy.largeTitle).font(.system(size: 21, weight: .bold))
            Text(LargeHandoff.body(
                changedStyle: model.changedStyleThisSession,
                changedCrop: model.changedCropThisSession,
                addedArrow: model.addedArrowThisSession,
                addedRedaction: model.addedRedactionThisSession
            ))
            .font(.system(size: 15))
            Button(IOSCopy.continueInApp, action: onStitchInApp).buttonStyle(BloomButtonStyle())
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
    case saved(title: String, detail: String)
    /// S10c. `copied` files are in the temp copy so far.
    case handoffProgress(copied: Int, total: Int, received: Int)
    /// S10d. Staging itself failed.
    case handoffFailed
    /// Frame 63b. Staging succeeded and opening the app did not.
    case stagedAwaitingApp(count: Int)
    /// S10e. `firstOrdinal` is the 1-based index of the first shot that failed.
    case handoffPartial(received: Int, missingCount: Int, firstOrdinal: Int, loaded: Int)
    /// S10f. `manualOpenHint` is set when the app did not open. The page does not change.
    case cannotHandOff(manualOpenHint: Bool)
}

extension ShareClassification {
    var pdfCount: Int {
        if case .stitch(_, let pdfs, _) = route { return pdfs }
        return 0
    }
}

/// The sheet the extension shows when export goes to the app (frame 11 / 11a).
struct LargeHandoffSheet: Equatable {
    var frame: LargeHandoffFrame
    var title: String
    var body: String
}

/// What the extension does on copy or save.
enum ShareExportRoute: Equatable {
    case inline
    case largeSheet(LargeHandoffSheet)
    case reselectInApp

    /// Placeholder matching `ShareViewController` and `ShareFlowView` today: over budget with a transfer
    /// channel shows `IOSCopy.largeTitle` and `LargeHandoff.body`; without one it asks to reselect in the app.
    static func decide(_ model: EditorModel, canTransferToApp: Bool) -> ShareExportRoute {
        switch ExportFidelityRouter.decide(
            pixelWidth: model.pixelWidth,
            pixelHeight: model.pixelHeight,
            canTransferToApp: canTransferToApp,
            style: model.style,
            scale: model.cropMatch.map { CGFloat($0.scale) }
        ) {
        case .fullResolutionPNG:
            return .inline
        case .reselectInApp:
            return .reselectInApp
        case .handOffOriginal:
            let changedStyle = model.changedStyleThisSession
            let changedCrop = model.changedCropThisSession
            let addedArrow = model.addedArrowThisSession
            let addedRedaction = model.addedRedactionThisSession
            return .largeSheet(LargeHandoffSheet(
                frame: LargeHandoff.frame(
                    changedStyle: changedStyle, changedCrop: changedCrop,
                    addedArrow: addedArrow, addedRedaction: addedRedaction
                ),
                title: IOSCopy.largeTitle,
                body: LargeHandoff.body(
                    changedStyle: changedStyle, changedCrop: changedCrop,
                    addedArrow: addedArrow, addedRedaction: addedRedaction
                )
            ))
        }
    }
}
