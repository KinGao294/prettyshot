import Foundation

/// One item the share sheet handed over, described only by its type identifiers.
struct ShareAttachment: Equatable {
    var typeIdentifiers: [String]
}

struct ShareClassification: Equatable {
    enum Route: Equatable {
        case empty
        case unreadable
        /// One image. `ignored` counts non-image, non-PDF attachments that were skipped.
        case singleImage(ignored: Int)
        /// Several images, or at least one PDF. Stitching happens in the app, never in the extension.
        case stitch(images: Int, pdfs: Int, ignored: Int)
    }

    var route: Route

    var imageCount: Int {
        switch route {
        case .empty, .unreadable: return 0
        case .singleImage: return 1
        case .stitch(let images, _, _): return images
        }
    }
}

/// Share-sheet routing. Single image stays in the extension; several images or a PDF go to stitch.
enum SharePayloadParser {
    static func classify(_ attachments: [ShareAttachment]) -> ShareClassification {
        if attachments.isEmpty {
            return ShareClassification(route: .empty)
        }
        var images = 0
        var pdfs = 0
        var ignored = 0
        for attachment in attachments {
            switch kind(attachment.typeIdentifiers) {
            case .image: images += 1
            case .pdf: pdfs += 1
            case .other: ignored += 1
            }
        }
        if images + pdfs == 0 {
            return ShareClassification(route: .unreadable)
        }
        if pdfs == 0, images == 1 {
            return ShareClassification(route: .singleImage(ignored: ignored))
        }
        return ShareClassification(route: .stitch(images: images, pdfs: pdfs, ignored: ignored))
    }

    static func kind(_ typeIdentifiers: [String]) -> Kind {
        if typeIdentifiers.contains(where: isPDF) { return .pdf }
        if typeIdentifiers.contains(where: isImage) { return .image }
        return .other
    }

    enum Kind {
        case image
        case pdf
        case other
    }

    static func isImage(_ uti: String) -> Bool {
        imageUTIs.contains(uti) || uti.hasPrefix("public.image.")
    }

    static func isPDF(_ uti: String) -> Bool {
        uti == "com.adobe.pdf" || uti == "public.pdf"
    }

    private static let imageUTIs: Set<String> = [
        "public.image",
        "public.jpeg",
        "public.png",
        "public.heic",
        "public.heif",
        "public.tiff",
        "public.webp",
        "com.compuserve.gif",
        "public.jpeg-2000",
    ]
}
