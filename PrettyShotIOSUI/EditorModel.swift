import CoreGraphics
import Foundation
import ImageIO
import PrettyShotCore
import UIKit

enum ExportAttempt {
    case image(CGImage, previewResolution: Bool)
    case handoff
}

enum ShotEncoder {
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Holds the original bytes plus one downscaled preview. The preview is released before a full-size export.
/// Touch it on the main thread.
final class EditorModel: ObservableObject {
    @Published var style = BackgroundStyle.default
    @Published var tool: EditorTool = .background
    @Published var removeStatusBar = true
    @Published var arrows: [ArrowMark] = []
    @Published var redactions: [PixelRedaction] = []
    @Published var preview: UIImage?
    @Published var toastTitle: String?
    @Published var toastDetail: String?
    @Published var usingPreviewResolution = false
    @Published var pixelWidth = 0
    @Published var pixelHeight = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var encoded = Data()
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    var cropMatch: StatusBarCrop? {
        StatusBarCropTable.match(width: pixelWidth, height: pixelHeight)
    }

    var showsDownsampleChip: Bool {
        let longSide = max(pixelWidth, pixelHeight)
        return longSide > ExtensionMemoryBudget.previewMaxLongSide
    }

    func load(_ data: Data) {
        encoded = data
        if let size = ImagePrep.pixelSize(data) {
            pixelWidth = size.width
            pixelHeight = size.height
        }
        refreshPreview()
    }

    func refreshPreview() {
        guard !encoded.isEmpty else {
            preview = nil
            return
        }
        guard let image = ImagePrep.downsample(encoded, maxLongSide: ExtensionMemoryBudget.previewMaxLongSide) else {
            preview = nil
            return
        }
        preview = UIImage(cgImage: image)
    }

    func export(canTransferToApp: Bool) -> ExportAttempt? {
        let pixels = pixelWidth * pixelHeight
        guard pixels > 0, !encoded.isEmpty else { return nil }
        switch ExtensionMemoryBudget.plan(pixelCount: pixels, canTransferToApp: canTransferToApp) {
        case .handoffToApp:
            return .handoff
        case .fullResolutionInline:
            preview = nil
            let longSide = max(pixelWidth, pixelHeight)
            guard let full = ImagePrep.downsample(encoded, maxLongSide: longSide) else { return nil }
            let rendered = render(full)
            refreshPreview()
            return rendered.map { .image($0, previewResolution: false) }
        case .previewResolutionInline:
            guard let current = preview?.cgImage else { return nil }
            usingPreviewResolution = true
            return render(current).map { .image($0, previewResolution: true) }
        }
    }

    func exportPreviewResolution() -> CGImage? {
        guard let current = preview?.cgImage else { return nil }
        usingPreviewResolution = true
        return render(current)
    }

    func addArrow(start: CGPoint, end: CGPoint, in viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let arrow = ArrowMark(
            start: CGPoint(x: start.x / viewSize.width, y: start.y / viewSize.height),
            end: CGPoint(x: end.x / viewSize.width, y: end.y / viewSize.height)
        )
        guard arrow.isMeaningful else { return }
        pushUndo()
        arrows.append(arrow)
    }

    func addRedaction(rect: CGRect, in viewSize: CGSize) {
        guard viewSize.width > 1, viewSize.height > 1 else { return }
        let normalized = CGRect(
            x: rect.minX / viewSize.width,
            y: rect.minY / viewSize.height,
            width: rect.width / viewSize.width,
            height: rect.height / viewSize.height
        )
        let pixels = CGRect(
            x: normalized.minX * CGFloat(pixelWidth),
            y: normalized.minY * CGFloat(pixelHeight),
            width: normalized.width * CGFloat(pixelWidth),
            height: normalized.height * CGFloat(pixelHeight)
        )
        let mark = PixelRedaction(rect: pixels.integral)
        guard mark.isMeaningfulRedaction else { return }
        pushUndo()
        redactions.append(mark)
    }

    func deleteLastMark() {
        pushUndo()
        if tool == .redact, !redactions.isEmpty {
            redactions.removeLast()
        } else if !arrows.isEmpty {
            arrows.removeLast()
        }
    }

    func setRemoveStatusBar(_ value: Bool) {
        guard cropMatch != nil, value != removeStatusBar else { return }
        pushUndo()
        removeStatusBar = value
    }

    func writeEncodedToTemporaryFile() -> URL? {
        guard !encoded.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).dat")
        do {
            try encoded.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        apply(next)
    }

    func showToast(_ title: String, detail: String) {
        toastTitle = title
        toastDetail = detail
    }

    private func render(_ base: CGImage) -> CGImage? {
        let geometryScale = CGFloat(base.width) / CGFloat(max(pixelWidth, 1))
        let baked = Redactor.apply(redactions, to: base, scale: cropMatch?.scale ?? 1, geometryScale: geometryScale)
        let crop = activeCrop(width: baked.width, height: baked.height).integral
        guard crop.width >= 1, crop.height >= 1 else { return nil }
        let input = BeautifyInput(
            base: baked,
            crop: crop,
            background: style,
            scale: (cropMatch?.scale ?? 1) * geometryScale,
            baseSize: CGSize(width: baked.width, height: baked.height)
        )
        return BeautifyRenderer.render(input) { context in
            self.strokeArrows(in: context, image: baked)
        }
    }

    private func activeCrop(width: Int, height: Int) -> CGRect {
        let scaleX = CGFloat(width) / CGFloat(max(pixelWidth, 1))
        let scaleY = CGFloat(height) / CGFloat(max(pixelHeight, 1))
        if removeStatusBar, let match = cropMatch, let rect = match.cropRect(width: pixelWidth, height: pixelHeight) {
            return CGRect(
                x: rect.minX * scaleX,
                y: rect.minY * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY
            )
        }
        return CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    }

    private func strokeArrows(in context: CGContext, image: CGImage) {
        context.saveGState()
        context.setStrokeColor(CGColor(srgbRed: 232 / 255, green: 160 / 255, blue: 168 / 255, alpha: 1))
        context.setFillColor(CGColor(srgbRed: 232 / 255, green: 160 / 255, blue: 168 / 255, alpha: 1))
        let width = max(2, 7 * (cropMatch?.scale ?? 1) * CGFloat(image.width) / CGFloat(max(pixelWidth, 1)))
        context.setLineWidth(width)
        context.setLineCap(.round)
        for arrow in arrows where arrow.isMeaningful {
            let start = CGPoint(x: arrow.start.x * CGFloat(image.width), y: arrow.start.y * CGFloat(image.height))
            let end = CGPoint(x: arrow.end.x * CGFloat(image.width), y: arrow.end.y * CGFloat(image.height))
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head = width * 2.2
            context.saveGState()
            context.translateBy(x: end.x, y: end.y)
            context.rotate(by: angle)
            context.move(to: .zero)
            context.addLine(to: CGPoint(x: -head, y: head * 0.45))
            context.addLine(to: CGPoint(x: -head, y: -head * 0.45))
            context.closePath()
            context.fillPath()
            context.restoreGState()
        }
        context.restoreGState()
    }

    private struct Snapshot {
        var arrows: [ArrowMark]
        var redactions: [PixelRedaction]
        var removeStatusBar: Bool
    }

    private func snapshot() -> Snapshot {
        Snapshot(arrows: arrows, redactions: redactions, removeStatusBar: removeStatusBar)
    }

    private func pushUndo() {
        undoStack.append(snapshot())
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    private func apply(_ snapshot: Snapshot) {
        arrows = snapshot.arrows
        redactions = snapshot.redactions
        removeStatusBar = snapshot.removeStatusBar
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}

enum EditorTool: String, CaseIterable, Identifiable {
    case background
    case style
    case crop
    case arrow
    case redact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .background: return IOSCopy.toolBackground
        case .style: return IOSCopy.toolStyle
        case .crop: return IOSCopy.toolCrop
        case .arrow: return IOSCopy.toolArrow
        case .redact: return IOSCopy.toolRedact
        }
    }
}
