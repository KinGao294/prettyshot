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
    @Published var note = ""
    @Published var flattened: CGImage?

    func ingest(_ images: [CGImage]) {
        var stitcher = ScrollStitcher()
        var skipped = 0
        for image in images {
            guard let frame = RGBAImage.fromCGImage(image) else {
                skipped += 1
                continue
            }
            if case .ignored = stitcher.ingest(frame) {
                skipped += 1
            }
        }
        session = StitchSession(assembly: stitcher.takeAssembly())
        note = skipped > 0 ? IOSCopy.stitchSizeMismatch : IOSCopy.stitchPreviewNote
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
            overlap = session.assembly.seams.indices.contains(selectedSeam) ? session.assembly.seams[selectedSeam].editorOverlap : 0
            showChoices = true
        case .sticky:
            showSticky = true
        case .duplicates:
            break
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
}

/// Frame 38 L4, plus the sheets behind 39–43 / 51–54.
struct StitchScreen: View {
    @ObservedObject var model: StitchModel
    var onBack: () -> Void
    var onBeautify: (CGImage) -> Void
    var onExportSegments: ([CGImage]) -> Void

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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let preview = model.preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    }
                    Text(model.note)
                        .font(.system(size: 12))
                        .foregroundStyle(IOSTheme.muted)
                    Toggle(IOSCopy.keepOnce, isOn: Binding(
                        get: { model.session.assembly.dedupeStickyBars },
                        set: { model.setDedupe($0) }
                    ))
                    Text(IOSCopy.keepOnceDetail).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
                    Text(IOSCopy.exclusionStub).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
                    Text(IOSCopy.duplicateWiringNote).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
                    ForEach(model.session.assembly.duplicateCandidates) { candidate in
                        duplicateCard(candidate)
                    }
                    if let bar = model.session.gate.bottomBar {
                        Text(bar)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(IOSTheme.charcoal)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(IOSTheme.warn.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(16)
            }
            Button(model.session.gate.primaryTitle) {
                model.primaryTapped()
                if let image = model.flattened {
                    onBeautify(image)
                }
            }
            .font(.system(size: 16.5, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(model.session.gate.canAdvance ? IOSTheme.bloom : IOSTheme.rail)
            .foregroundStyle(IOSTheme.bloomInk)
            .padding(16)
        }
        .background(IOSTheme.paper)
        .sheet(isPresented: $model.showChoices) { choiceSheet }
        .sheet(isPresented: $model.showSticky) { stickySheet }
        .sheet(isPresented: $model.showOverLimit) { overLimitSheet }
    }

    private func duplicateCard(_ candidate: DuplicateSegmentCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(IOSCopy.duplicateMark).font(.system(size: 12, weight: .semibold)).foregroundStyle(IOSTheme.warn)
            Text(IOSCopy.duplicateQuestion).font(.system(size: 15, weight: .semibold))
            Text(IOSCopy.duplicateDetail).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
            if candidate.isUnresolved {
                Button(IOSCopy.duplicateKeepOnce) { model.chooseDuplicate(candidate.id, choice: .keepOnce) }
                    .buttonStyle(BloomButtonStyle())
                Button(IOSCopy.duplicateKeepBoth) { model.chooseDuplicate(candidate.id, choice: .keepBoth) }
                    .buttonStyle(PlainCardButtonStyle())
            } else {
                Button(IOSCopy.duplicateRestore) { model.restoreDuplicate(candidate.id) }
                    .buttonStyle(PlainCardButtonStyle())
            }
        }
        .padding(12)
        .background(IOSTheme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var choiceSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(IOSCopy.seamMissTitle(seamIndex: model.selectedSeam)).font(.system(size: 21, weight: .bold))
            Text(IOSCopy.failBody).font(.system(size: 15))
            Stepper(value: $model.overlap, in: 0...4000) {
                Text("\(model.overlap) pt")
            }
            Button(IOSCopy.alignDone, action: model.align).buttonStyle(BloomButtonStyle())
            Button(IOSCopy.reDetect, action: model.restoreAuto).buttonStyle(PlainCardButtonStyle())
            Button(IOSCopy.joinAsIs, action: model.join).buttonStyle(PlainCardButtonStyle())
            Button(IOSCopy.laterSeam) { model.showChoices = false }.buttonStyle(PlainCardButtonStyle())
            Text(IOSCopy.alignDragHint).font(.system(size: 12)).foregroundStyle(IOSTheme.muted)
        }
        .padding(20)
        .presentationDetents([.medium, .large])
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
