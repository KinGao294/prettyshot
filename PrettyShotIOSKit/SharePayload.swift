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

struct GatheredShareFiles {
    var loaded: [(ordinal: Int, url: URL)]
    var missingOrdinals: [Int]

    var loadedCount: Int { loaded.count }
}

enum ShareFileGather {
    /// `copies` is one entry per image or PDF, in share order. A nil URL is a shot that did not load.
    static func gather(_ copies: [(ordinal: Int, url: URL?)]) -> GatheredShareFiles {
        var loaded: [(ordinal: Int, url: URL)] = []
        var missing: [Int] = []
        for copy in copies {
            if let url = copy.url {
                loaded.append((copy.ordinal, url))
            } else {
                missing.append(copy.ordinal)
            }
        }
        return GatheredShareFiles(loaded: loaded, missingOrdinals: missing)
    }
}

/// Every shot that failed to load. A new pick replaces the previous list instead of leaking it.
struct MissingShotSession: Equatable {
    var ordinals: [Int]
    var expectedTotal: Int

    /// `previous` is discarded. Failures from the last stitch do not carry into this pick.
    static func beginNewPick(replacing _: MissingShotSession, failedOrdinals: [Int], loadedCount: Int) -> MissingShotSession {
        remember(failedOrdinals: failedOrdinals, loadedCount: loadedCount)
    }

    static func remember(failedOrdinals: [Int], loadedCount: Int) -> MissingShotSession {
        let ordinals = failedOrdinals.sorted()
        return MissingShotSession(ordinals: ordinals, expectedTotal: loadedCount + ordinals.count)
    }

    /// Drops the earliest missing ordinal. The banner stays while any remain.
    func addingBackOne() -> (session: MissingShotSession, restored: Int?) {
        guard let restored = ordinals.first else { return (self, nil) }
        return addingBack(ordinal: restored)
    }

    /// Drops one copy of the ordinal the user actually put back.
    func addingBack(ordinal: Int) -> (session: MissingShotSession, restored: Int?) {
        guard let index = ordinals.firstIndex(of: ordinal) else { return (self, nil) }
        var next = ordinals
        next.remove(at: index)
        return (MissingShotSession(ordinals: next, expectedTotal: expectedTotal), ordinal)
    }
}

struct OrderedShot: Equatable {
    var id: String
    var capturedAt: Date?
    /// Position in the original share list. Capture time never decides order.
    var globalOrdinal: Int? = nil
}

enum ShotOrdering {
    /// Inserts after every image with a smaller original ordinal. Never sorts by capture time.
    /// Ids that are not ordinals, and shots with no `globalOrdinal`, fall back to the missing slot.
    static func inserting(_ shot: OrderedShot, into shots: [OrderedShot], missingOrdinal: Int) -> [OrderedShot] {
        func resolved(_ item: OrderedShot) -> Int? {
            if let globalOrdinal = item.globalOrdinal { return globalOrdinal }
            return Int(item.id)
        }
        let known = shots.contains { resolved($0) != nil } || resolved(shot) != nil
        var next = shots
        if !known {
            let index = min(max(missingOrdinal - 1, 0), next.count)
            next.insert(shot, at: index)
            return next
        }
        let incoming = resolved(shot) ?? missingOrdinal
        var index = 0
        for (position, existing) in shots.enumerated() {
            if let value = resolved(existing), value < incoming {
                index = position + 1
            }
        }
        next.insert(shot, at: index)
        return next
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
