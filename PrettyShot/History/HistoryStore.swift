import AppKit
import Combine
import Foundation
import PrettyShotCore

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
    /// A stitch sidecar on disk can put the sticky bars back into this image.
    var hasStickyRestore: Bool = false

    var modeLabel: String {
        if edited { return "已编辑" }
        if mode == .scrolling { return "长图 · \(pixelHeight) px" }
        return mode.chipTitle
    }

    init(
        id: UUID,
        createdAt: Date,
        fileName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Double,
        mode: CaptureMode,
        edited: Bool,
        hasStickyRestore: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.fileName = fileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.mode = mode
        self.edited = edited
        self.hasStickyRestore = hasStickyRestore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        fileName = try container.decode(String.self, forKey: .fileName)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        scale = try container.decode(Double.self, forKey: .scale)
        mode = try container.decode(CaptureMode.self, forKey: .mode)
        edited = try container.decode(Bool.self, forKey: .edited)
        hasStickyRestore = try container.decodeIfPresent(Bool.self, forKey: .hasStickyRestore) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(pixelWidth, forKey: .pixelWidth)
        try container.encode(pixelHeight, forKey: .pixelHeight)
        try container.encode(scale, forKey: .scale)
        try container.encode(mode, forKey: .mode)
        try container.encode(edited, forKey: .edited)
        try container.encode(hasStickyRestore, forKey: .hasStickyRestore)
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, fileName, pixelWidth, pixelHeight, scale, mode, edited, hasStickyRestore
    }
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
    nonisolated static let defaultLimit = 200

    /// Newest first.
    @Published private(set) var items: [HistoryItem] = []

    let directory: URL
    private let limit: Int
    private let thumbnails = NSCache<NSString, NSImage>()
    /// At most one decoded stitch. A second load replaces it; delete, prune, and save drop it.
    private var stitchCache: CachedStitch?
    /// One in-flight disk read per item, shared by concurrent overlay loads.
    private var stitchLoads: [UUID: Task<ScrollAssembly?, Never>] = [:]
    /// Bumped when an id is deleted or pruned so a read that is already running cannot cache it again.
    private var stitchEpoch: [UUID: Int] = [:]
    private var stitchLoadToken: [UUID: UUID] = [:]

    private struct CachedStitch {
        var id: UUID
        var assembly: ScrollAssembly
        var epoch: Int
    }

    nonisolated static var defaultDirectory: URL {
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
        try? FileManager.default.removeItem(at: stitchDirectory(for: item))
        thumbnails.removeObject(forKey: item.id.uuidString as NSString)
        dropStitchMemory(id: item.id)
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        for item in items {
            try? FileManager.default.removeItem(at: url(for: item))
            try? FileManager.default.removeItem(at: stitchDirectory(for: item))
            dropStitchMemory(id: item.id)
        }
        thumbnails.removeAllObjects()
        stitchCache = nil
        stitchLoads.values.forEach { $0.cancel() }
        stitchLoads.removeAll()
        stitchLoadToken.removeAll()
        items.removeAll()
        persist()
    }

    func stitchDirectory(for item: HistoryItem) -> URL {
        directory.appendingPathComponent("\(item.id.uuidString).stitch", isDirectory: true)
    }

    /// Writes segment pixels beside the history PNG. The store does not keep the assembly in memory.
    func saveStitch(_ assembly: ScrollAssembly, for item: HistoryItem) throws {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let folder = stitchDirectory(for: items[index])
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = try StitchArchive.write(assembly, to: folder)
        try StitchArchive.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        items[index].hasStickyRestore = assembly.dedupeStickyBars
            && assembly.hasStickyRepeats
            && assembly.pendingSticky?.isUnresolved != true
        // The sidecar is on disk. Keeping the pixels here would pin every long capture until quit.
        dropStitchMemory(id: item.id)
        thumbnails.removeObject(forKey: item.id.uuidString as NSString)
        persist()
    }

    func cachedStitch(for item: HistoryItem) -> ScrollAssembly? {
        guard let stitchCache, stitchCache.id == item.id else { return nil }
        return stitchCache.assembly
    }

    /// Loads a previously saved assembly. Returns nil when this item has no sidecar.
    func loadStitch(for item: HistoryItem) -> ScrollAssembly? {
        let epoch = stitchEpoch[item.id] ?? 0
        if let stitchCache, stitchCache.id == item.id, stitchCache.epoch == epoch {
            return stitchCache.assembly
        }
        guard let assembly = StitchArchive.load(from: stitchDirectory(for: item)) else { return nil }
        rememberStitch(assembly, id: item.id, epoch: epoch)
        return stitchEpoch[item.id] ?? 0 == epoch ? assembly : nil
    }

    /// One disk read, off the main thread. Concurrent callers share the same task.
    /// The decoded assembly is cached only while this id is still the newest one and has not been deleted.
    func loadStitchForOverlay(_ item: HistoryItem) async -> ScrollAssembly? {
        let id = item.id
        let epoch = stitchEpoch[id] ?? 0
        if let stitchCache, stitchCache.id == id, stitchCache.epoch == epoch {
            return stitchCache.assembly
        }
        if let existing = stitchLoads[id] {
            let assembly = await existing.value
            guard stitchEpoch[id] ?? 0 == epoch else { return nil }
            return assembly
        }
        let folder = stitchDirectory(for: item)
        let token = UUID()
        let task = Task.detached(priority: .userInitiated) { () -> ScrollAssembly? in
            StitchArchive.load(from: folder)
        }
        stitchLoads[id] = task
        stitchLoadToken[id] = token
        let assembly = await task.value
        if stitchLoadToken[id] == token {
            stitchLoads[id] = nil
            stitchLoadToken[id] = nil
        }
        guard stitchEpoch[id] ?? 0 == epoch else { return nil }
        if let assembly {
            rememberStitch(assembly, id: id, epoch: epoch)
        }
        return assembly
    }

    /// Forgets a decoded stitch and invalidates any read of this id that has not finished yet.
    private func dropStitchMemory(id: UUID) {
        stitchEpoch[id, default: 0] += 1
        if stitchCache?.id == id { stitchCache = nil }
        stitchLoads[id]?.cancel()
        stitchLoads[id] = nil
        stitchLoadToken[id] = nil
    }

    private func rememberStitch(_ assembly: ScrollAssembly, id: UUID, epoch: Int) {
        guard stitchEpoch[id] ?? 0 == epoch else { return }
        stitchCache = CachedStitch(id: id, assembly: assembly, epoch: epoch)
    }

    func thumbnail(for item: HistoryItem, maxPixelSize: Int = 480) async -> NSImage? {
        let key = item.id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let fileURL = url(for: item)
        let cgImage = await Task.detached(priority: .utility) {
            ImageCodec.thumbnail(at: fileURL, maxPixelSize: maxPixelSize)
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
            try? FileManager.default.removeItem(at: stitchDirectory(for: item))
            dropStitchMemory(id: item.id)
        }
        items.removeSubrange(limit...)
    }
}

/// How many times a stitch sidecar was decoded. Overlay tests assert a cold load happens once, off the main thread.
enum StitchLoadMetrics {
    private static let lock = NSLock()
    private static var reads = 0
    private static var readOnMain = false

    static var diskReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    static var lastReadWasMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readOnMain
    }

    /// Test hook. Runs on the reader thread before the sidecar is decoded, so a delete can land mid-read.
    private static var beforeRead: (() -> Void)?

    static func setBeforeRead(_ hook: (() -> Void)?) {
        lock.lock()
        beforeRead = hook
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        reads = 0
        readOnMain = false
        beforeRead = nil
        lock.unlock()
    }

    static func record(onMain: Bool) {
        let hook: (() -> Void)?
        lock.lock()
        hook = beforeRead
        lock.unlock()
        hook?()
        lock.lock()
        reads += 1
        readOnMain = onMain
        lock.unlock()
    }
}

/// Segment pixels for one history item. Only the current screenshot stays decoded in the UI.
private enum StitchArchive {
    struct Manifest: Codable {
        var dedupeStickyBars: Bool
        var pending: Pending?
        var segments: [Segment]
        var seams: [Seam]
    }

    struct Pending: Codable {
        var headerRows: Int
        var footerRows: Int
        var seamCount: Int
        var keepOnce: Bool?
    }

    struct Segment: Codable {
        var image: String
        var confidentSeamYs: [Int]
        var repeats: [Repeat]
    }

    struct Repeat: Codable {
        var seamY: Int
        var header: String?
        var footer: String?
    }

    struct Seam: Codable {
        var kind: String
        var overlap: Int?
        var suggestedOverlap: Int?
    }

    static func encode(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    static func decode(_ data: Data) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: data)
    }

    static func write(_ assembly: ScrollAssembly, to folder: URL) throws -> Manifest {
        var segments: [Segment] = []
        for (index, segment) in assembly.segments.enumerated() {
            let imageName = "segment-\(index).png"
            guard let image = segment.image.cgImage() else { continue }
            try ImageCodec.writePNG(image, to: folder.appendingPathComponent(imageName))
            var repeats: [Repeat] = []
            for (repeatIndex, rep) in segment.stickyRepeats.enumerated() {
                var headerName: String?
                var footerName: String?
                if rep.header.height > 0, let header = rep.header.cgImage() {
                    headerName = "segment-\(index)-repeat-\(repeatIndex)-header.png"
                    try ImageCodec.writePNG(header, to: folder.appendingPathComponent(headerName!))
                }
                if rep.footer.height > 0, let footer = rep.footer.cgImage() {
                    footerName = "segment-\(index)-repeat-\(repeatIndex)-footer.png"
                    try ImageCodec.writePNG(footer, to: folder.appendingPathComponent(footerName!))
                }
                repeats.append(Repeat(seamY: rep.seamY, header: headerName, footer: footerName))
            }
            segments.append(Segment(image: imageName, confidentSeamYs: segment.confidentSeamYs, repeats: repeats))
        }
        let seams = assembly.seams.map { seam -> Seam in
            switch seam.kind {
            case .needsAlignment:
                return Seam(kind: "needsAlignment", overlap: nil, suggestedOverlap: seam.suggestedOverlap)
            case .aligned(let overlap):
                return Seam(kind: "aligned", overlap: overlap, suggestedOverlap: seam.suggestedOverlap)
            case .joinedAsIs:
                return Seam(kind: "joinedAsIs", overlap: nil, suggestedOverlap: seam.suggestedOverlap)
            }
        }
        let pending = assembly.pendingSticky.map {
            Pending(headerRows: $0.headerRows, footerRows: $0.footerRows, seamCount: $0.seamCount, keepOnce: $0.keepOnce)
        }
        return Manifest(dedupeStickyBars: assembly.dedupeStickyBars, pending: pending, segments: segments, seams: seams)
    }

    static func load(from folder: URL) -> ScrollAssembly? {
        StitchLoadMetrics.record(onMain: Thread.isMainThread)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? decode(data) else { return nil }
        return try? read(manifest, from: folder)
    }

    static func read(_ manifest: Manifest, from folder: URL) throws -> ScrollAssembly {
        var segments: [ScrollSegment] = []
        for record in manifest.segments {
            guard let image = loadRGBA(folder.appendingPathComponent(record.image)) else { continue }
            var repeats: [StickyRepeat] = []
            for rep in record.repeats {
                let header = rep.header.flatMap { loadRGBA(folder.appendingPathComponent($0)) } ?? RGBAImage(width: image.width, height: 0, pixels: [])
                let footer = rep.footer.flatMap { loadRGBA(folder.appendingPathComponent($0)) } ?? RGBAImage(width: image.width, height: 0, pixels: [])
                repeats.append(StickyRepeat(seamY: rep.seamY, header: header, footer: footer))
            }
            segments.append(ScrollSegment(image: image, confidentSeamYs: record.confidentSeamYs, stickyRepeats: repeats))
        }
        let seams = manifest.seams.map { seam -> ScrollSeam in
            let kind: ScrollSeam.Kind
            switch seam.kind {
            case "aligned":
                kind = .aligned(overlap: seam.overlap ?? 0)
            case "joinedAsIs":
                kind = .joinedAsIs
            default:
                kind = .needsAlignment
            }
            return ScrollSeam(kind: kind, suggestedOverlap: seam.suggestedOverlap)
        }
        let pending = manifest.pending.map {
            PendingStickyConfirmation(headerRows: $0.headerRows, footerRows: $0.footerRows, seamCount: $0.seamCount, keepOnce: $0.keepOnce)
        }
        return ScrollAssembly(segments: segments, seams: seams, dedupeStickyBars: manifest.dedupeStickyBars, pendingSticky: pending)
    }

    private static func loadRGBA(_ url: URL) -> RGBAImage? {
        guard let image = ImageCodec.loadImage(at: url) else { return nil }
        return RGBAImage.fromCGImage(image)
    }
}
