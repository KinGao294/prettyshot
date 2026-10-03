import CoreGraphics
import Foundation

/// What happens to pixels when the extension saves or hands off.
/// A downscale is only `previewChosen`, after the user taps that button.
enum ExportFidelity: Equatable {
    /// Lossless PNG of the full-resolution render. No JPEG, no downscale.
    case fullResolutionPNG
    /// Too big to decode twice. Ask before handing off the file or saving a preview.
    case askBeforeDownscale
    /// The user explicitly chose 「按预览尺寸保存」.
    case previewChosen
}

enum ExportFidelityRouter {
    static func decide(pixelCount: Int, canTransferToApp: Bool, userChosePreview: Bool) -> ExportFidelity {
        if userChosePreview { return .previewChosen }
        switch ExtensionMemoryBudget.plan(pixelCount: pixelCount, canTransferToApp: canTransferToApp) {
        case .fullResolutionInline:
            return .fullResolutionPNG
        case .handoffToApp, .previewResolutionInline:
            return .askBeforeDownscale
        }
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
