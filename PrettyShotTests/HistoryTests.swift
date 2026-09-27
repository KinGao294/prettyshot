import XCTest
@testable import PrettyShot

@MainActor
final class HistoryTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PrettyShotTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testIndexRoundTrip() throws {
        let item = HistoryItem(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_790_000_000), fileName: "a.png",
                               pixelWidth: 10, pixelHeight: 20, scale: 2, mode: .window, edited: true)
        let index = HistoryIndex(items: [item])
        let decoded = try HistoryIndex.decode(HistoryIndex.encode(index))
        XCTAssertEqual(decoded, index)
        XCTAssertEqual(decoded.version, HistoryIndex.currentVersion)
    }

    func testAddPersistsNewestFirstAndReloads() throws {
        let store = HistoryStore(directory: directory, limit: 10)
        let first = try store.add(image: TestImages.make(width: 10, height: 10), scale: 2, mode: .region)
        let second = try store.add(image: TestImages.make(width: 20, height: 10), scale: 1, mode: .fullscreen)
        XCTAssertEqual(store.items.map(\.id), [second.id, first.id])
        XCTAssertEqual(store.latest?.pixelWidth, 20)
        XCTAssertNotNil(store.image(for: first))

        let reloaded = HistoryStore(directory: directory, limit: 10)
        XCTAssertEqual(reloaded.items.map(\.id), [second.id, first.id])
        XCTAssertEqual(reloaded.items.last?.mode, .region)
    }

    func testLimitPrunesOldestFiles() throws {
        let store = HistoryStore(directory: directory, limit: 2)
        let oldest = try store.add(image: TestImages.make(width: 4, height: 4), scale: 1, mode: .region)
        try store.add(image: TestImages.make(width: 4, height: 4), scale: 1, mode: .region)
        try store.add(image: TestImages.make(width: 4, height: 4), scale: 1, mode: .region)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertFalse(store.items.contains(oldest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: oldest).path))
    }

    func testDeleteReplaceAndClear() throws {
        let store = HistoryStore(directory: directory, limit: 10)
        let a = try store.add(image: TestImages.make(width: 4, height: 4), scale: 1, mode: .region)
        let b = try store.add(image: TestImages.make(width: 4, height: 4), scale: 1, mode: .region, edited: true)

        let replaced = try store.replaceImage(of: b.id, with: TestImages.make(width: 8, height: 6))
        XCTAssertEqual(replaced?.pixelWidth, 8)
        XCTAssertEqual(store.image(for: b)?.height, 6)

        store.delete(a)
        XCTAssertEqual(store.items.map(\.id), [b.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: a).path))

        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(HistoryStore(directory: directory).items.isEmpty)
    }

    func testMissingFilesAreDroppedOnLoad() throws {
        let store = HistoryStore(directory: directory, limit: 10)
        let item = try store.add(image: TestImages.make(width: 4, height: 4), scale: 1, mode: .region)
        try FileManager.default.removeItem(at: store.url(for: item))
        XCTAssertTrue(HistoryStore(directory: directory).items.isEmpty)
    }
}
