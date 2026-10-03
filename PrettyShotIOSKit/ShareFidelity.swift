import CoreGraphics
import Foundation

/// Export is full-resolution PNG, or the original file is handed to the app.
/// A downscaled bitmap is never an export.
enum ExportFidelity: Equatable {
    case fullResolutionPNG
    case handOffOriginal
    case reselectInApp
}

enum ExportFidelityRouter {
    static func decide(pixelCount: Int, canTransferToApp: Bool) -> ExportFidelity {
        switch ExtensionMemoryBudget.plan(pixelCount: pixelCount, canTransferToApp: canTransferToApp) {
        case .fullResolutionInline:
            return .fullResolutionPNG
        case .handoffToApp:
            return .handOffOriginal
        case .reselectInApp:
            return .reselectInApp
        }
    }
}

/// Decodes stitch sources at the size stored in the file. No long-side cap.
enum StitchSourceLoader {
    static func images(from blobs: [Data]) -> [CGImage] {
        blobs.compactMap { ImagePrep.fullImage($0) }
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
