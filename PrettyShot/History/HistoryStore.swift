import AppKit
import Foundation

struct HistoryItem: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let fileName: String
    var pixelWidth: Int
    var pixelHeight: Int
    /// Pixels per point of the source display (2 on Retina).
    let scale: Double
    let mode: CaptureMode
    /// True for results exported from the editor (annotated / beautified).
    var edited: Bool

    var modeLabel: String { edited ? "已编辑" : mode.chipTitle }
}

/// On-disk index format (`index.json`). Versioned so future releases can migrate.
struct HistoryIndex: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = HistoryIndex.currentVersion
    var items: [HistoryItem]

    static func encode(_ index: HistoryIndex) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(index)
    }

    static func decode(_ data: Data) throws -> HistoryIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HistoryIndex.self, from: data)
    }
}

/// Local-only history (no cloud in v0.1): PNGs + index.json under Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    static let defaultLimit = 200

    /// Newest first.
    @Published private(set) var items: [HistoryItem] = []

    let directory: URL
    private let limit: Int
    private let thumbnails = NSCache<NSString, NSImage>()

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PrettyShot/History", isDirectory: true)
    }

    init(directory: URL = HistoryStore.defaultDirectory, limit: Int = HistoryStore.defaultLimit) {
        self.directory = directory
        self.limit = limit
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    var latest: HistoryItem? { items.first }

    func url(for item: HistoryItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    func image(for item: HistoryItem) -> CGImage? {
        ImageCodec.loadImage(at: url(for: item))
    }

    @discardableResult
    func add(image: CGImage, scale: CGFloat, mode: CaptureMode, edited: Bool = false) throws -> HistoryItem {
        let id = UUID()
        let item = HistoryItem(
            id: id,
            createdAt: Date(),
            fileName: "\(id.uuidString).png",
            pixelWidth: image.width,
            pixelHeight: image.height,
            scale: Double(scale),
            mode: mode,
            edited: edited
        )
        try ImageCodec.writePNG(image, to: url(for: item))
        items.insert(item, at: 0)
        prune()
        persist()
        return item
    }

    /// Overwrites the pixels of an existing entry (used when the editor re-exports the same session).
    @discardableResult
    func replaceImage(of id: UUID, with image: CGImage) throws -> HistoryItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        try ImageCodec.writePNG(image, to: url(for: items[index]))
        items[index].pixelWidth = image.width
        items[index].pixelHeight = image.height
        thumbnails.removeObject(forKey: id.uuidString as NSString)
        persist()
        return items[index]
    }

    func delete(_ item: HistoryItem) {
        try? FileManager.default.removeItem(at: url(for: item))
        thumbnails.removeObject(forKey: item.id.uuidString as NSString)
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        for item in items {
            try? FileManager.default.removeItem(at: url(for: item))
        }
        thumbnails.removeAllObjects()
        items.removeAll()
        persist()
    }

    func thumbnail(for item: HistoryItem, maxPixelSize: Int = 480) async -> NSImage? {
        let key = item.id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let url = url(for: item)
        let cgImage = await Task.detached(priority: .utility) {
            ImageCodec.thumbnail(at: url, maxPixelSize: maxPixelSize)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnails.setObject(image, forKey: key)
        return image
    }

    // MARK: - Persistence

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? HistoryIndex.decode(data) else { return }
        // Drop entries whose PNG disappeared (user cleaned the folder manually).
        items = index.items.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func persist() {
        do {
            let data = try HistoryIndex.encode(HistoryIndex(items: items))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("PrettyShot: failed to write history index: \(error)")
        }
    }

    private func prune() {
        guard items.count > limit else { return }
        for item in items[limit...] {
            try? FileManager.default.removeItem(at: url(for: item))
        }
        items.removeSubrange(limit...)
    }
}
