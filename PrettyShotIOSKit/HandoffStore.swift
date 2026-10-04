import Foundation

/// What the share extension is trying to hand to the app.
enum HandoffKind: String, Codable, Equatable {
    case singleImage
    case stitch
    case pdf
}

struct MissingShot: Codable, Equatable {
    /// 1-based position in the share, in capture order. 「第 3 张」 is 3.
    var ordinal: Int
}

struct HandoffTicket: Codable, Equatable, Identifiable {
    var id: String
    var kind: HandoffKind
    var fileNames: [String]
    var createdAt: Date
    var missingShots: [MissingShot]

    init(id: String, kind: HandoffKind, fileNames: [String], createdAt: Date, missingShots: [MissingShot] = []) {
        self.id = id
        self.kind = kind
        self.fileNames = fileNames
        self.createdAt = createdAt
        self.missingShots = missingShots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(HandoffKind.self, forKey: .kind)
        fileNames = try container.decode([String].self, forKey: .fileNames)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        missingShots = try container.decodeIfPresent([MissingShot].self, forKey: .missingShots) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(fileNames, forKey: .fileNames)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(missingShots, forKey: .missingShots)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, fileNames, createdAt, missingShots
    }
}

enum HandoffError: Error, Equatable {
    case transferUnavailable
    case unreadable
    case missingTicket
}

enum HandoffMode: String, Equatable {
    case inline
    case appGroup = "app-group"
}

/// Swap point between the App Group container and the free-signing fallback.
/// The extension and the app talk only through this protocol.
protocol HandoffStore: AnyObject {
    /// True when another process (the containing app) can read what `stage` wrote.
    var canTransferToApp: Bool { get }
    var persistsAcrossProcesses: Bool { get }
    func stage(copying files: [URL], kind: HandoffKind, missingShots: [MissingShot]) throws -> HandoffTicket
    func pendingTickets() throws -> [HandoffTicket]
    func files(for ticketID: String) throws -> [URL]
    func discard(ticketID: String) throws
}

extension HandoffStore {
    func stage(copying files: [URL], kind: HandoffKind) throws -> HandoffTicket {
        try stage(copying: files, kind: kind, missingShots: [])
    }

    /// Removes a ticket only after the app has read the files. An interrupted open must not call this.
    func confirmReceipt(ticketID: String) throws {
        try discard(ticketID: ticketID)
    }
}

enum HandoffCancellation {
    /// User aborted the handoff. Deletes the staged copies only. Callers must not delete the photo-library original.
    static func abort(ticketID: String?, store: HandoffStore) {
        guard let ticketID else { return }
        try? store.discard(ticketID: ticketID)
    }
}

/// Result of putting files into the inbox. Nothing is removed until `confirmReceipt`.
enum HandoffReceipt: Equatable {
    /// Copied into the store. The app has not confirmed yet.
    case waitingForApp(HandoffTicket)
    /// Open was interrupted or the app cannot take the file. The ticket is still in the store.
    case interrupted(HandoffTicket)
    /// Nothing was staged. The source files were not deleted.
    case failed(HandoffError)
}

enum HandoffTransfer {
    /// Copies `files` as-is. Does not decode bitmaps and does not delete the sources.
    static func persist(
        copying files: [URL],
        kind: HandoffKind,
        store: HandoffStore,
        missingShots: [MissingShot] = [],
        fileManager: FileManager = .default
    ) -> HandoffReceipt {
        if files.isEmpty || files.contains(where: { !fileManager.fileExists(atPath: $0.path) }) {
            return .failed(.unreadable)
        }
        do {
            let ticket = try store.stage(copying: files, kind: kind, missingShots: missingShots)
            return .waitingForApp(ticket)
        } catch let error as HandoffError {
            return .failed(error)
        } catch {
            return .failed(.unreadable)
        }
    }

    /// Records the open attempt. Failure leaves the ticket pending so the extension can retry.
    static func resolveOpen(succeeded: Bool, ticket: HandoffTicket, store: HandoffStore) -> HandoffReceipt {
        let stillThere = (try? store.pendingTickets().contains { $0.id == ticket.id }) ?? false
        guard stillThere else { return .failed(.missingTicket) }
        return succeeded ? .waitingForApp(ticket) : .interrupted(ticket)
    }
}

/// What the share extension shows after it tries to open the containing app.
enum ExtensionLaunchOutcome: Equatable {
    /// The app opened. The ticket stays until the app confirms.
    case opened
    /// Files are already staged. Frame 63b. Closing does not discard them.
    case stagedNeedsManualOpen(count: Int)
    /// Nothing usable was staged. Frame 63 (S10d).
    case stagingFailed
}

enum PickerLaunchOutcome: Equatable {
    case opened
    /// S10f stored nothing. Stay there and ask the user to open the app. Do not switch to S10d.
    case stayAndAskToOpenApp
    /// Frame 13. Opening the app failed. Stay on the read-failed page.
    case stayOnReadFailedPage
}

enum ExtensionLaunchRouter {
    static func afterHandoffOpen(succeeded: Bool, ticket: HandoffTicket, store: HandoffStore) -> ExtensionLaunchOutcome {
        switch HandoffTransfer.resolveOpen(succeeded: succeeded, ticket: ticket, store: store) {
        case .waitingForApp:
            return .opened
        case .interrupted(let staged):
            return .stagedNeedsManualOpen(count: staged.fileNames.count)
        case .failed:
            return .stagingFailed
        }
    }

    static func afterPickerOpen(succeeded: Bool, fromReadFailedPage: Bool = false) -> PickerLaunchOutcome {
        if succeeded { return .opened }
        if fromReadFailedPage { return .stayOnReadFailedPage }
        return .stayAndAskToOpenApp
    }

    /// Frame 63 「重试」. Drop the previous ticket before staging another, so two copies do not stack.
    static func prepareRetry(previousTicketID: String?, store: HandoffStore) {
        HandoffCancellation.abort(ticketID: previousTicketID, store: store)
    }
}

/// S12. The multi-image page failed to open the app before anything was staged.
enum S12OpenResult: Equatable {
    case stayOnMultiPage(hint: String)
    /// Files are already staged, so this is frame 63b, not S12.
    case notThisPage
    /// Multi-image page cannot hand the files off. Go back to S10f.
    case reselectOnS10f
}

enum S12Launch {
    static func afterOpenFailed(stagedFileCount: Int) -> S12OpenResult {
        if stagedFileCount > 0 {
            return .notThisPage
        }
        return .reselectOnS10f
    }
}

/// A1b. Every staged batch is one list, in share order (oldest first). The count is the files, not the missing shots.
enum PendingShareResume {
    static func ordered(_ pending: [HandoffTicket]) -> [HandoffTicket] {
        pending.sorted { $0.createdAt < $1.createdAt }
    }

    static func ticket(_ pending: [HandoffTicket]) -> HandoffTicket? {
        ordered(pending).last
    }

    static func stagedFileCount(_ pending: [HandoffTicket]) -> Int {
        ordered(pending).reduce(0) { count, ticket in
            ticket.kind == .pdf ? count : count + ticket.fileNames.count
        }
    }

    static func fileURLs(_ pending: [HandoffTicket], store: HandoffStore) throws -> [URL] {
        var urls: [URL] = []
        for ticket in ordered(pending) where ticket.kind != .pdf {
            urls.append(contentsOf: try store.files(for: ticket.id))
        }
        return urls
    }

    /// 1-based positions of image files across every share. `pending` must already use global missing ordinals
    /// (the list `pendingTickets()` returns). PDF tickets are not in the list and do not shift later cards.
    static func globalFileOrdinals(_ pending: [HandoffTicket]) -> [Int] {
        var offset = 0
        var ordinals: [Int] = []
        for ticket in ordered(pending) {
            if ticket.kind == .pdf { continue }
            let span = ticket.fileNames.count + ticket.missingShots.count
            let localMissing = Set(ticket.missingShots.map { $0.ordinal - offset })
            if span > 0 {
                for position in 1...span where !localMissing.contains(position) {
                    ordinals.append(offset + position)
                }
            }
            offset += span
        }
        return ordinals
    }

    /// Missing ordinals stored on disk are local to each share. Readers see one continuous list.
    /// A PDF share does not move the next image's ordinal.
    static func withGlobalMissingOrdinals(_ tickets: [HandoffTicket]) -> [HandoffTicket] {
        var offset = 0
        var result: [HandoffTicket] = []
        for ticket in tickets {
            var copy = ticket
            if ticket.kind == .pdf {
                result.append(copy)
                continue
            }
            copy.missingShots = ticket.missingShots.map { MissingShot(ordinal: $0.ordinal + offset) }
            result.append(copy)
            offset += ticket.fileNames.count + ticket.missingShots.count
        }
        return result
    }
}

/// Reads every image first, then confirms. A later delete still returns the bytes already read.
/// What the app opens for `prettyshot://<host>`.
enum HandoffLaunch {
    static let handoffHost = "handoff"

    /// The extension's frame 11 handed over one large image: open it straight in the editor (A4).
    /// Only the newest ticket counts, and only a single image. Stitch batches stay on the A1b banner.
    static func ticketToOpen(host: String?, pending: [HandoffTicket]) -> HandoffTicket? {
        guard host?.lowercased() == handoffHost,
              let newest = PendingShareResume.ticket(pending),
              newest.kind == .singleImage else { return nil }
        return newest
    }
}

enum ReceiptConfirmation {
    static func imageData(of tickets: [HandoffTicket], store: HandoffStore) throws -> [Data] {
        let ordered = PendingShareResume.ordered(tickets)
        var data: [Data] = []
        for ticket in ordered where ticket.kind != .pdf {
            let urls = try store.files(for: ticket.id)
            for url in urls {
                data.append(try Data(contentsOf: url))
            }
        }
        for ticket in ordered where ticket.kind != .pdf {
            do {
                try store.confirmReceipt(ticketID: ticket.id)
            } catch {
                return data
            }
        }
        return data
    }
}

enum HandoffStoreFactory {
    static let appGroupID = "group.app.prettyshot.ios"
    static let infoKey = "PrettyShotHandoffMode"

    static var compiledMode: HandoffMode {
        #if PRETTYSHOT_HANDOFF_APP_GROUP
        return .appGroup
        #elseif PRETTYSHOT_HANDOFF_INLINE
        return .inline
        #else
        return .inline
        #endif
    }

    static var hasExplicitHandoffFlag: Bool {
        #if PRETTYSHOT_HANDOFF_APP_GROUP || PRETTYSHOT_HANDOFF_INLINE
        return true
        #else
        return false
        #endif
    }

    static func mode(in bundle: Bundle) -> HandoffMode {
        let raw = bundle.object(forInfoDictionaryKey: infoKey) as? String
        return HandoffMode(rawValue: raw ?? "") ?? .inline
    }

    /// Production store. A missing App Group container falls back to inline instead of crashing.
    static func live(
        bundle: Bundle = .main,
        containerLookup: (String) -> URL? = { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    ) -> HandoffStore {
        make(mode: mode(in: bundle), containerURL: containerLookup(appGroupID))
    }

    static func make(mode: HandoffMode, containerURL: URL?) -> HandoffStore {
        if mode == .appGroup, let containerURL {
            return DirectoryHandoffStore(root: containerURL.appendingPathComponent("Handoff", isDirectory: true))
        }
        return InlineHandoffStore.inbox()
    }
}

/// Writes tickets under a directory. The App Group store is this pointed at the shared container.
final class DirectoryHandoffStore: HandoffStore {
    let root: URL
    var canTransferToApp: Bool { true }
    var persistsAcrossProcesses: Bool { true }
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func stage(copying files: [URL], kind: HandoffKind, missingShots: [MissingShot]) throws -> HandoffTicket {
        if files.isEmpty { throw HandoffError.unreadable }
        let id = UUID().uuidString
        let folder = root.appendingPathComponent(id, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            var names: [String] = []
            for (index, file) in files.enumerated() {
                guard fileManager.fileExists(atPath: file.path) else { throw HandoffError.unreadable }
                let safe = Self.safeName(file.lastPathComponent, index: index)
                let destination = folder.appendingPathComponent(safe)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: file, to: destination)
                names.append(safe)
            }
            let ticket = HandoffTicket(id: id, kind: kind, fileNames: names, createdAt: Date(), missingShots: missingShots)
            let data = try JSONEncoder().encode(ticket)
            try data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
            return ticket
        } catch {
            if fileManager.fileExists(atPath: folder.path) {
                try? fileManager.removeItem(at: folder)
            }
            if let error = error as? HandoffError { throw error }
            throw HandoffError.unreadable
        }
    }

    func pendingTickets() throws -> [HandoffTicket] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let folders = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        var tickets: [HandoffTicket] = []
        for folder in folders {
            let manifest = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifest),
                  let ticket = try? JSONDecoder().decode(HandoffTicket.self, from: data) else { continue }
            tickets.append(ticket)
        }
        let sorted = tickets.sorted { $0.createdAt < $1.createdAt }
        return PendingShareResume.withGlobalMissingOrdinals(sorted)
    }

    func files(for ticketID: String) throws -> [URL] {
        let ticket = try ticket(ticketID)
        return ticket.fileNames.map { root.appendingPathComponent(ticketID).appendingPathComponent($0) }
    }

    func discard(ticketID: String) throws {
        let folder = root.appendingPathComponent(ticketID, isDirectory: true)
        guard fileManager.fileExists(atPath: folder.path) else { return }
        try fileManager.removeItem(at: folder)
    }

    private func ticket(_ id: String) throws -> HandoffTicket {
        let manifest = root.appendingPathComponent(id).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let ticket = try? JSONDecoder().decode(HandoffTicket.self, from: data) else {
            throw HandoffError.missingTicket
        }
        return ticket
    }

    private static func safeName(_ raw: String, index: Int) -> String {
        let base = (raw as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "-")
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." || cleaned == "manifest.json" {
            return String(format: "%03d.dat", index)
        }
        return String(format: "%03d-%@", index, cleaned)
    }
}

/// In-process only. A second instance, including the containing app, sees nothing.
/// This is the free Personal Team path: the extension finishes save/copy itself.
final class InlineHandoffStore: HandoffStore {
    var canTransferToApp: Bool { false }
    var persistsAcrossProcesses: Bool { false }
    var root: URL { directory.root }
    private let directory: DirectoryHandoffStore

    /// Unique directory. Another instance, including the containing app, sees nothing.
    convenience init(fileManager: FileManager = .default) {
        let root = fileManager.temporaryDirectory.appendingPathComponent("PrettyShotInline-\(UUID().uuidString)", isDirectory: true)
        self.init(root: root, fileManager: fileManager)
    }

    /// Stable inbox for this process. A later `inbox()` still sees tickets the app has not confirmed.
    static func inbox(fileManager: FileManager = .default) -> InlineHandoffStore {
        let root = fileManager.temporaryDirectory.appendingPathComponent("PrettyShotInlineInbox", isDirectory: true)
        return InlineHandoffStore(root: root, fileManager: fileManager)
    }

    init(root: URL, fileManager: FileManager = .default) {
        directory = DirectoryHandoffStore(root: root, fileManager: fileManager)
    }

    func stage(copying files: [URL], kind: HandoffKind, missingShots: [MissingShot]) throws -> HandoffTicket {
        try directory.stage(copying: files, kind: kind, missingShots: missingShots)
    }

    func pendingTickets() throws -> [HandoffTicket] {
        try directory.pendingTickets()
    }

    func files(for ticketID: String) throws -> [URL] {
        try directory.files(for: ticketID)
    }

    func discard(ticketID: String) throws {
        try directory.discard(ticketID: ticketID)
    }
}
