import CoreGraphics
import Foundation
import PrettyShotCore

/// Export is full-resolution PNG, or the original file is handed to the app.
/// A downscaled bitmap is never an export.
enum ExportFidelity: Equatable {
    case fullResolutionPNG
    case handOffOriginal
    case reselectInApp
}

enum ExportFidelityRouter {
    static func decide(pixelWidth: Int, pixelHeight: Int, canTransferToApp: Bool) -> ExportFidelity {
        switch ExtensionMemoryBudget.plan(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            canTransferToApp: canTransferToApp
        ) {
        case .fullResolutionInline:
            return .fullResolutionPNG
        case .handoffToApp:
            return .handOffOriginal
        case .reselectInApp:
            return .reselectInApp
        }
    }
}

struct LoadedStitchSources: Equatable {
    var images: [CGImage]
    /// 1-based positions in the input that did not decode.
    var missingOrdinals: [Int]

    static func == (lhs: LoadedStitchSources, rhs: LoadedStitchSources) -> Bool {
        lhs.missingOrdinals == rhs.missingOrdinals
            && lhs.images.count == rhs.images.count
            && zip(lhs.images, rhs.images).allSatisfy { $0.width == $1.width && $0.height == $1.height }
    }
}

/// Decodes stitch sources at the size stored in the file. No long-side cap.
/// A blob that does not decode is reported, not dropped.
enum StitchSourceLoader {
    static func images(from blobs: [Data]) -> [CGImage] {
        load(blobs).images
    }

    static func load(_ blobs: [Data]) -> LoadedStitchSources {
        var images: [CGImage] = []
        var missing: [Int] = []
        for (index, blob) in blobs.enumerated() {
            if let image = ImagePrep.fullImage(blob) {
                images.append(image)
            } else {
                missing.append(index + 1)
            }
        }
        return LoadedStitchSources(images: images, missingOrdinals: missing)
    }
}

/// In-app multi-pick. Unreadable shots stay visible as a missing-shot state.
/// Fewer than two readable images is an error, not a shorter stitch with no explanation.
enum InAppStitchLoader {
    enum Outcome: Equatable {
        case ready
        case missing(ordinals: [Int])
        case failed
    }

    static func outcome(readableCount: Int, failedOrdinals: [Int]) -> Outcome {
        let missing = failedOrdinals.sorted()
        if readableCount >= 2, missing.isEmpty {
            return .ready
        }
        if readableCount >= 2 {
            return .missing(ordinals: missing)
        }
        return .failed
    }
}

/// 「分开导出」 uses the same beautify pass as a merged export, then the caller saves the result.
enum SegmentBeautifier {
    static func beautify(_ image: CGImage, style: BackgroundStyle = .default, scale: CGFloat = 1) -> CGImage? {
        BeautifyRenderer.render(BeautifyInput(
            base: image,
            crop: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)),
            background: style,
            scale: scale
        ))
    }
}

/// 「预览已降采样」 is an extension-only chip, and only when this image is over the extension budget.
enum PreviewDownsampleChip {
    static func shows(inExtension: Bool, pixelWidth: Int, pixelHeight: Int, canTransferToApp: Bool) -> Bool {
        guard inExtension, pixelWidth > 0, pixelHeight > 0 else { return false }
        guard max(pixelWidth, pixelHeight) > ExtensionMemoryBudget.previewMaxLongSide else { return false }
        return ExtensionMemoryBudget.plan(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            canTransferToApp: canTransferToApp
        ) != .fullResolutionInline
    }
}

/// Original file on disk. Editing reads a preview from it; handoff copies this URL.
struct ShareImageCarrier {
    let fileURL: URL
    let pixelWidth: Int
    let pixelHeight: Int

    /// File URL only. A full-size decode is not retained.
    var fullDecodedCopiesHeld: Int { 0 }

    init(fileURL: URL) throws {
        guard let size = ImagePrep.pixelSize(fileURL) else { throw HandoffError.unreadable }
        self.fileURL = fileURL
        self.pixelWidth = size.width
        self.pixelHeight = size.height
    }

    func preview(maxLongSide: Int = ExtensionMemoryBudget.previewMaxLongSide) -> CGImage? {
        ImagePrep.downsample(fileURL, maxLongSide: maxLongSide)
    }
}
