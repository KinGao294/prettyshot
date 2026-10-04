import PrettyShotCore
import SwiftUI
import UIKit

/// Frames 36–48 and 51–55. Frames 56–60 render candidates Core already stored.
final class StitchModel: ObservableObject {
    @Published var session = StitchSession(assembly: ScrollAssembly())
    @Published var preview: UIImage?
    @Published var showChoices = false
    @Published var showSticky = false
    @Published var showOverLimit = false
    @Published var overlap = 0
    @Published var selectedSeam = 0
    @Published var manualAlign = false
    @Published var note = ""
    @Published var skippedOrdinals: [Int] = []
    @Published var flattened: CGImage?
    @Published var scrollToDuplicate: String?

    func ingest(_ images: [CGImage], ordinals: [Int] = []) {
        var stitcher = ScrollStitcher()
        var skipped: [Int] = []
        for (index, image) in images.enumerated() {
            let ordinal = ordinals.count == images.count ? ordinals[index] : index + 1
            guard let frame = RGBAImage.fromCGImage(image) else {
                skipped.append(ordinal)
                continue
            }
            if case .ignored = stitcher.ingest(frame) {
                skipped.append(ordinal)
            }
        }
        session = StitchSession(assembly: stitcher.takeAssembly())
        skippedOrdinals = skipped
        note = skipped.isEmpty ? IOSCopy.stitchPreviewNote : IOSCopy.stitchSizeMismatch(ordinals: skipped)
        if let seam = session.assembly.seams.first {
            overlap = seam.editorOverlap
        }
        refresh()
    }

    func refresh() {
        if let rendered = session.assembly.renderPreview(), let cg = rendered.image.cgImage() {
            preview = UIImage(cgImage: cg)
        } else if let flat = session.assembly.flattenedIfResolved()?.cgImage() {
            preview = UIImage(cgImage: flat)
        }
    }

    func primaryTapped() {
        flattened = nil
        switch session.gate.step {
        case .seams:
            selectedSeam = session.assembly.seams.firstIndex { !$0.isResolved } ?? 0
            let seam = session.assembly.seams.indices.contains(selectedSeam) ? session.assembly.seams[selectedSeam] : nil
            // An unresolved suggestion is not applied, so the picture on screen is overlap 0.
            overlap = seam?.suggestedOverlap == nil ? (seam?.editorOverlap ?? 0) : 0
            manualAlign = false
            showChoices = true
        case .sticky:
            showSticky = true
        case .duplicates:
            scrollToDuplicate = session.assembly.duplicateCandidates.first(where: \.isUnresolved)?.id
                ?? session.assembly.duplicateCandidates.first?.id
        case .ready:
            flattened = session.assembly.flattenedIfResolved()?.cgImage()
        }
    }

    func align() {
        session.align(seam: selectedSeam, overlap: overlap)
        showChoices = false
        refresh()
    }

    func join() {
        session.joinAsIs(seam: selectedSeam)
        showChoices = false
        refresh()
    }

    func restoreAuto() {
        session.restoreAuto(seam: selectedSeam)
        overlap = session.assembly.seams.indices.contains(selectedSeam) ? session.assembly.seams[selectedSeam].editorOverlap : 0
        refresh()
    }

    func confirmSticky(keepOnce: Bool) {
        session.confirmSticky(keepOnce: keepOnce)
        showSticky = false
        refresh()
    }

    func setDedupe(_ on: Bool) {
        if let outcome = session.setDedupe(on), case .exceedsLimit = outcome {
            showOverLimit = true
        }
        refresh()
    }

    func chooseDuplicate(_ id: String, choice: DuplicateSegmentChoice) {
        session.resolveDuplicate(id, choice: choice)
        refresh()
    }

    func restoreDuplicate(_ id: String) {
        session.restoreDuplicate(id)
        refresh()
    }

    func undoDuplicate() {
        session.undoDuplicate()
        refresh()
    }

    /// Long enough to reach 「撤销」. A newer toast restarts the wait; the undo stack itself stays.
    @MainActor
    func expireToast(after seconds: Double = 4) async {
        guard let shown = session.toast else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard !Task.isCancelled, session.toast == shown else { return }
        withAnimation { session.toast = nil }
    }
}

/// Frame 38 L4, plus the sheets behind 39–43 / 51–54.
struct StitchScreen: View {
    @ObservedObject var model: StitchModel
    var onBack: () -> Void
    var onBeautify: (CGImage) -> Void
    var onExportSegments: ([CGImage]) -> Void
    var missingLine: String?
    var missingOrdinals: [Int] = []
    var onReadd: (Int) -> Void = { _ in }
    var readdToastTitle: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(IOSCopy.cancel, action: onBack)
                Spacer()
                Text(IOSCopy.stitchCardTitle).font(.system(size: 16.5, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            summaryRow
            if let missingLine {
                missingBanner(missingLine)
            }
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let preview = model.preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    }
                    if !model.skippedOrdinals.isEmpty {
                        Text(model.note)
                            .font(.system(size: 12))
                            .foregroundStyle(IOSTheme.muted)
                    }
                    #if DEBUG
                    if model.note == IOSCopy.stitchPreviewNote {
                        Text(model.note)
                            .font(.system(size: 12))
                            .foregroundStyle(IOSTheme.muted)
                    }
                    Text(IOSCopy.exclusionStub).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
                    Text(IOSCopy.duplicateWiringNote).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
                    #endif
                    ForEach(model.session.duplicateCards, id: \.id) { card in
                        duplicateCard(card)
                            .id(card.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: model.scrollToDuplicate) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            }
            StitchBottomBarView(
                bar: model.session.bottomBar,
                onSecondary: {},
                onPrimary: {
                    model.primaryTapped()
                    if let image = model.flattened {
                        onBeautify(image)
                    }
                },
                sticky: { stickyRow }
            )
        }
        .background(IOSTheme.paper)
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let toast = model.session.toast {
                    StitchToastView(toast: toast, onAction: model.undoDuplicate)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if ReaddToast.draws(on: .stitch), let readdToastTitle {
                    SuccessToastBanner(title: readdToastTitle)
                }
            }
        }
        .task(id: model.session.toast) { await model.expireToast() }
        .sheet(isPresented: $model.showChoices) { choiceSheet }
        .sheet(isPresented: $model.showSticky) { stickySheet }
        .sheet(isPresented: $model.showOverLimit) { overLimitSheet }
    }

    private var stickyRow: some View {
        let row = StitchStickyRow.evaluate(model.session.assembly)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 15, weight: .semibold))
                Text(row.detail).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
            }
            Spacer(minLength: 8)
            if let restore = row.restoreTitle {
                Button(restore) { model.setDedupe(false) }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSTheme.charcoal)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(IOSTheme.card, in: Capsule())
                    .overlay(Capsule().stroke(IOSTheme.hairline))
                    .accessibilityIdentifier("stitch.sticky.restore")
            }
            Toggle(row.title, isOn: Binding(
                get: { model.session.assembly.dedupeStickyBars },
                set: { model.setDedupe($0) }
            ))
            .labelsHidden()
            .tint(IOSTheme.mint)
        }
    }

    /// 「4 张 · 3 处接缝」 + ✓ / 待对齐 / 直接拼 / 固定栏待确认 1 chips (frame 38, L7i frame 60).
    @ViewBuilder
    private var summaryRow: some View {
        let summary = StitchSummary.evaluate(model.session.assembly)
        if let title = summary.title {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(IOSTheme.muted)
                ForEach(Array(summary.chips.enumerated()), id: \.offset) { _, chip in
                    summaryChip(chip)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .accessibilityIdentifier("stitch.summary")
        }
    }

    @ViewBuilder
    private func summaryChip(_ chip: StitchSummary.Chip) -> some View {
        switch chip.kind {
        case .aligned:
            HStack(spacing: 3) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                Text(chip.label)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(IOSTheme.stagedCheck)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(IOSTheme.mint.opacity(0.18), in: Capsule())
        case .unaligned, .sticky:
            Text(chip.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(uiColor: StitchPalette.warnText))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(IOSTheme.warn.opacity(0.18), in: Capsule())
                .overlay(Capsule().stroke(IOSTheme.warn, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        case .joinedAsIs:
            Text(chip.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(IOSTheme.muted)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(IOSTheme.hairline.opacity(0.6), in: Capsule())
        }
    }

    private func missingBanner(_ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(IOSTheme.warn)
                Text(line)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSTheme.charcoal)
                Spacer(minLength: 8)
            }
            ForEach(missingOrdinals, id: \.self) { ordinal in
                Button(IOSCopy.readdButton(ordinal: ordinal, missingCount: missingOrdinals.count)) { onReadd(ordinal) }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IOSTheme.charcoal)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSTheme.warn.opacity(0.22))
    }

    /// Pending: amber dashed card with the two choices (L7e). Handled: Mint hairline + 「✓ 已处理 · …｜还原」 (L7f).
    private func duplicateCard(_ card: DuplicateCardState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.isPending {
                Text(IOSCopy.duplicateMark)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(uiColor: StitchPalette.warnText))
                Text(card.question).font(.system(size: 15, weight: .semibold))
                Text(card.detail).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
                HStack(spacing: 10) {
                    Button(IOSCopy.duplicateKeepOnce) { model.chooseDuplicate(card.id, choice: .keepOnce) }
                        .buttonStyle(BloomButtonStyle())
                    Button(IOSCopy.duplicateKeepBoth) { model.chooseDuplicate(card.id, choice: .keepBoth) }
                        .buttonStyle(PlainCardButtonStyle())
                }
            } else {
                HStack(spacing: 8) {
                    if let handled = card.handledLabel {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(uiColor: StitchPalette.handledMint))
                        Text(handled)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(uiColor: StitchPalette.handledMint))
                    }
                    Button(IOSCopy.duplicateRestore) { model.restoreDuplicate(card.id) }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xB0505E))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(IOSTheme.bloom.opacity(0.25), in: Capsule())
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(IOSTheme.card, in: Capsule())
                .overlay(Capsule().stroke(IOSTheme.mint))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card.isPending ? Color(uiColor: StitchPalette.pendingCardBackground) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if card.isPending {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(IOSTheme.warn, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    /// Frame 51 when a suggestion exists. Frame 39 when the seam has no reliable overlap.
    private var choiceSheet: some View {
        let seam = activeSeam
        let suggested = seam?.suggestedOverlap
        return VStack(alignment: .leading, spacing: 12) {
            if let suggested {
                Text(IOSCopy.untrustedSeamTitle(seamIndex: model.selectedSeam))
                    .font(.system(size: 21, weight: .bold))
                Text(IOSCopy.untrustedBody).font(.system(size: 15))
                HStack(spacing: 8) {
                    positionChip(IOSCopy.positionA(0), selected: model.overlap == 0) {
                        model.overlap = 0
                    }
                    positionChip(IOSCopy.positionB(delta: suggested), selected: model.overlap == suggested) {
                        model.overlap = suggested
                    }
                }
                Button(IOSCopy.confirmCurrent, action: model.align).buttonStyle(BloomButtonStyle())
                manualAlignControls
                Button(IOSCopy.joinAsIs, action: model.join).buttonStyle(PlainCardButtonStyle())
                separateExportButton
                Text(IOSCopy.confirmBlockedNote)
                    .font(.system(size: 12))
                    .foregroundStyle(IOSTheme.muted)
            } else {
                Text(IOSCopy.seamMissTitle(seamIndex: model.selectedSeam))
                    .font(.system(size: 21, weight: .bold))
                Text(IOSCopy.failBody).font(.system(size: 15))
                manualAlignControls
                Button(IOSCopy.joinAsIs, action: model.join).buttonStyle(PlainCardButtonStyle())
                separateExportButton
                Button(IOSCopy.laterSeam) { model.showChoices = false }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(IOSTheme.muted)
            }
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var manualAlignControls: some View {
        if model.manualAlign {
            Stepper(value: $model.overlap, in: 0...4000) {
                Text("\(model.overlap) pt")
            }
            Text(IOSCopy.alignDragHint).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
            Button(IOSCopy.alignDone, action: model.align).buttonStyle(BloomButtonStyle())
            Button(IOSCopy.reDetect, action: model.restoreAuto).buttonStyle(PlainCardButtonStyle())
        } else {
            Button(IOSCopy.manualAlign) { model.manualAlign = true }
                .buttonStyle(PlainCardButtonStyle())
        }
    }

    private var separateExportButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: exportSegmentsSeparately) {
                Text(IOSCopy.exportSeparate)
            }
            .buttonStyle(PlainCardButtonStyle())
            Text(IOSCopy.exportSeparateDetail)
                .font(.system(size: 12))
                .foregroundStyle(IOSTheme.muted)
        }
    }

    private var activeSeam: ScrollSeam? {
        guard model.session.assembly.seams.indices.contains(model.selectedSeam) else { return nil }
        return model.session.assembly.seams[model.selectedSeam]
    }

    private func positionChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IOSTheme.charcoal)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(selected ? IOSTheme.bloom.opacity(0.35) : IOSTheme.card, in: Capsule())
                .overlay(Capsule().stroke(selected ? IOSTheme.bloom : IOSTheme.hairline))
        }
        .buttonStyle(.plain)
    }

    /// Beautify each segment with the current default style, then save. Same pass as a merged export.
    /// Unresolved seams make `exportWithinLimits` return nothing; this path does not use that.
    private func exportSegmentsSeparately() {
        let images = model.session.assembly.segments.compactMap { segment -> CGImage? in
            guard let raw = segment.image.cgImage() else { return nil }
            return SegmentBeautifier.beautify(raw)
        }
        model.showChoices = false
        if !images.isEmpty {
            onExportSegments(images)
        }
    }

    private var stickySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.session.gate.stickyPrompt ?? IOSCopy.handleNext(1))
                .font(.system(size: 18, weight: .semibold))
            Button(IOSCopy.stickyKeepOnce) { model.confirmSticky(keepOnce: true) }.buttonStyle(BloomButtonStyle())
            Button(IOSCopy.stickyKeepAll) { model.confirmSticky(keepOnce: false) }.buttonStyle(PlainCardButtonStyle())
        }
        .padding(20)
        .presentationDetents([.medium])
    }

    private var overLimitSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(IOSCopy.tooLongTitle).font(.system(size: 21, weight: .bold))
            if let line = model.session.gate.overLimitLine {
                Text(line)
            }
            Text(IOSCopy.tooLongBody).font(.system(size: 14))
            Text(IOSCopy.tooLongCopy).font(.system(size: 13)).foregroundStyle(IOSTheme.muted)
            Button(model.session.gate.overLimitPrompt.primaryTitle) {
                if model.session.gate.overLimitPrompt.primaryExports {
                    let images = model.session.assembly.exportWithinLimits(
                        dedupeStickyBars: model.session.assembly.dedupeStickyBars,
                        maxHeight: model.session.maxHeight,
                        maxPixels: model.session.maxPixels
                    ).compactMap { $0.cgImage() }
                    model.showOverLimit = false
                    if !images.isEmpty {
                        onExportSegments(images)
                    }
                } else {
                    model.showOverLimit = false
                    model.showChoices = true
                }
            }
            .buttonStyle(BloomButtonStyle())
            if let caption = model.session.gate.overLimitPrompt.segmentExportCaption {
                Text(caption).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
            }
            Button(IOSCopy.keepDedupe) { model.showOverLimit = false }.buttonStyle(PlainCardButtonStyle())
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }
}

struct BloomButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16.5, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(IOSTheme.bloom.opacity(configuration.isPressed ? 0.8 : 1))
            .foregroundStyle(IOSTheme.bloomInk)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct PlainCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16.5, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(IOSTheme.card)
            .foregroundStyle(IOSTheme.charcoal)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(IOSTheme.hairline))
    }
}
