import Foundation

/// What the share extension is trying to hand to the app.
enum HandoffKind: String, Codable, Equatable {
    case singleImage
    case stitch
    case pdf
}

struct HandoffTicket: Codable, Equatable, Identifiable {
    var id: String
    var kind: HandoffKind
    var fileNames: [String]
    var createdAt: Date
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
    func stage(copying files: [URL], kind: HandoffKind) throws -> HandoffTicket
    func pendingTickets() throws -> [HandoffTicket]
    func files(for ticketID: String) throws -> [URL]
    func discard(ticketID: String) throws
}

extension HandoffStore {
    /// Removes a ticket only after the app has read the files. An interrupted open must not call this.
    func confirmReceipt(ticketID: String) throws {
        try discard(ticketID: ticketID)
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
    static func persist(copying files: [URL], kind: HandoffKind, store: HandoffStore, fileManager: FileManager = .default) -> HandoffReceipt {
        if files.isEmpty || files.contains(where: { !fileManager.fileExists(atPath: $0.path) }) {
            return .failed(.unreadable)
        }
        do {
            let ticket = try store.stage(copying: files, kind: kind)
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

    func stage(copying files: [URL], kind: HandoffKind) throws -> HandoffTicket {
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
            let ticket = HandoffTicket(id: id, kind: kind, fileNames: names, createdAt: Date())
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
        return tickets.sorted { $0.createdAt < $1.createdAt }
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

    func stage(copying files: [URL], kind: HandoffKind) throws -> HandoffTicket {
        try directory.stage(copying: files, kind: kind)
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
