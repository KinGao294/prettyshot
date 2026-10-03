import CoreGraphics
import Foundation

/// Counts bytes this thread's stitch buffers have reserved. Capture-stop tests install one
/// so parallel tests do not share a high-water mark. `peak` includes spare tile capacity.
final class AllocationLedger {
    private let lock = NSLock()
    private var live = 0
    private var peak = 0

    func add(_ delta: Int) {
        lock.lock()
        live += delta
        if live > peak { peak = live }
        lock.unlock()
    }

    var peakBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    var liveBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return live
    }

    /// The next stop-path measurement starts from whatever is still alive.
    func rebasePeak() {
        lock.lock()
        peak = live
        lock.unlock()
    }
}

enum PixelMetrics {
    private static let key = "PrettyShotPixelLedger"

    static var threadLedger: AllocationLedger? {
        get { Thread.current.threadDictionary[key] as? AllocationLedger }
        set { Thread.current.threadDictionary[key] = newValue }
    }
}

/// One block of whole rows. Appending fills the spare rows; the long image is a list of these,
/// so growing the capture does not copy the rows already kept.
final class TileBuffer {
    let ledger: AllocationLedger?
    let rowBytes: Int
    let rowCapacity: Int
    var rows: Int
    private var storage: UnsafeMutableRawPointer
    let byteCapacity: Int

    init(rowBytes: Int, rowCapacity: Int, ledger: AllocationLedger?) {
        self.ledger = ledger
        self.rowBytes = rowBytes
        self.rowCapacity = max(1, rowCapacity)
        self.rows = 0
        self.byteCapacity = rowBytes * self.rowCapacity
        storage = UnsafeMutableRawPointer.allocate(byteCount: byteCapacity, alignment: 16)
        ledger?.add(byteCapacity)
    }

    deinit {
        storage.deallocate()
        ledger?.add(-byteCapacity)
    }

    var spareRows: Int { rowCapacity - rows }

    func withRow<T>(_ local: Int, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        let pointer = storage.advanced(by: local * rowBytes).assumingMemoryBound(to: UInt8.self)
        return body(UnsafeBufferPointer(start: pointer, count: rowBytes))
    }

    func write(from source: TileBuffer, sourceLocal: Int, destLocal: Int, count: Int) {
        guard count > 0 else { return }
        storage.advanced(by: destLocal * rowBytes).copyMemory(
            from: source.storage.advanced(by: sourceLocal * rowBytes),
            byteCount: count * rowBytes
        )
    }

    func write(from bytes: UnsafeRawPointer, destLocal: Int, count: Int) {
        guard count > 0 else { return }
        storage.advanced(by: destLocal * rowBytes).copyMemory(from: bytes, byteCount: count * rowBytes)
    }

    /// Moves the live rows toward the spare at the end, opening `count` rows at local 0.
    func shiftRowsUp(by count: Int) {
        guard count > 0, rows > 0 else { return }
        var y = rows - 1
        while y >= 0 {
            let dest = storage.advanced(by: (y + count) * rowBytes)
            dest.copyMemory(from: storage.advanced(by: y * rowBytes), byteCount: rowBytes)
            y -= 1
        }
    }

    /// Keeps the left rows and returns a new tile holding the right rows.
    func split(atLocalRow local: Int) -> TileBuffer {
        let rightRows = rows - local
        let right = TileBuffer(rowBytes: rowBytes, rowCapacity: max(rightRows, 1), ledger: ledger)
        if rightRows > 0 {
            right.write(from: self, sourceLocal: local, destLocal: 0, count: rightRows)
            right.rows = rightRows
        }
        rows = local
        return right
    }

    func copyBytes(to dest: UnsafeMutableRawPointer, localRow: Int, byteOffset: Int, count: Int) {
        dest.copyMemory(from: storage.advanced(by: localRow * rowBytes + byteOffset), byteCount: count)
    }
}

/// Row-major RGBA8. Long captures are a sequence of row tiles so a new strip does not duplicate
/// the image already stitched. `cgImage()` reads those tiles through a direct data provider.
final class ImageStorage {
    static let tileRows = 512

    let width: Int
    var height: Int = 0
    var tiles: [TileBuffer] = []
    var rowBytes: Int { width * 4 }

    init(width: Int) {
        self.width = width
    }

    func clone() -> ImageStorage {
        let copy = ImageStorage(width: width)
        var row = 0
        while row < height {
            let count = min(Self.tileRows, height - row)
            copy.appendRows(from: self, sourceRow: row, count: count)
            row += count
        }
        return copy
    }

    func withRow<T>(_ y: Int, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        let (index, local) = location(of: y)
        return tiles[index].withRow(local, body)
    }

    func copiedArray() -> [UInt8] {
        guard height > 0, width > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let count = out.count
        out.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            copyBytes(at: 0, count: count, into: base)
        }
        return out
    }

    func bytesEqual(to other: ImageStorage) -> Bool {
        guard width == other.width, height == other.height else { return false }
        if height == 0 { return true }
        var row = 0
        while row < height {
            let same = withRow(row) { left in
                other.withRow(row) { right in
                    left.elementsEqual(right)
                }
            }
            if !same { return false }
            row += 1
        }
        return true
    }

    func append(from source: ImageStorage) {
        var row = 0
        while row < source.height {
            let count = min(Self.tileRows, source.height - row)
            appendRows(from: source, sourceRow: row, count: count)
            row += count
        }
    }

    func appendRows(from source: ImageStorage, sourceRow: Int, count: Int, exact: Bool = false) {
        var left = count
        var sourceCursor = sourceRow
        while left > 0 {
            let tile = ensureWritableTile(reserving: left, exact: exact)
            let (sourceIndex, sourceLocal) = source.location(of: sourceCursor)
            let n = min(left, tile.spareRows, source.tiles[sourceIndex].rows - sourceLocal)
            if n == 0 { break }
            let destLocal = tile.rows
            tile.write(from: source.tiles[sourceIndex], sourceLocal: sourceLocal, destLocal: destLocal, count: n)
            tile.rows += n
            left -= n
            sourceCursor += n
            height += n
        }
    }

    func append(bytes: UnsafeRawPointer, rows: Int) {
        var left = rows
        var source = bytes
        while left > 0 {
            let tile = ensureWritableTile()
            let n = min(left, tile.spareRows)
            if n == 0 { break }
            tile.write(from: source, destLocal: tile.rows, count: n)
            tile.rows += n
            left -= n
            source = source.advanced(by: n * rowBytes)
            height += n
        }
    }

    /// Inserts `source` so its first row lands at `row`. Existing rows at and below `row` shift down.
    /// Spare rows in the neighbouring chunk are filled before a new chunk is opened, and a new chunk
    /// is only as large as `tileRows` so the next insert can fill it instead of allocating again.
    func insert(_ source: ImageStorage, atRow row: Int) {
        guard source.height > 0 else { return }
        if row >= height {
            append(from: source)
            return
        }
        var boundary = ensureBoundary(atRow: row)
        var sourceRow = 0
        var left = source.height
        if boundary > 0 {
            let room = tiles[boundary - 1].spareRows
            let n = min(left, room)
            if n > 0 {
                write(from: source, sourceRow: sourceRow, into: tiles[boundary - 1], destLocal: tiles[boundary - 1].rows, count: n)
                tiles[boundary - 1].rows += n
                left -= n
                sourceRow += n
                height += n
            }
        }
        while left > 0 {
            if boundary < tiles.count, tiles[boundary].spareRows >= left {
                let tile = tiles[boundary]
                tile.shiftRowsUp(by: left)
                write(from: source, sourceRow: sourceRow, into: tile, destLocal: 0, count: left)
                tile.rows += left
                height += left
                return
            }
            let n = min(left, Self.tileRows)
            let tile = TileBuffer(rowBytes: rowBytes, rowCapacity: Self.tileRows, ledger: PixelMetrics.threadLedger)
            write(from: source, sourceRow: sourceRow, into: tile, destLocal: 0, count: n)
            tile.rows = n
            tiles.insert(tile, at: boundary)
            boundary += 1
            left -= n
            sourceRow += n
            height += n
        }
    }

    /// Drops rows from the bottom. The rows that stay are not copied.
    func removeLastRows(_ count: Int) {
        var left = min(max(0, count), height)
        while left > 0, let last = tiles.last {
            if last.rows <= left {
                left -= last.rows
                height -= last.rows
                tiles.removeLast()
            } else {
                last.rows -= left
                height -= left
                left = 0
            }
        }
    }

    private func write(from source: ImageStorage, sourceRow: Int, into tile: TileBuffer, destLocal: Int, count: Int) {
        var left = count
        var sourceCursor = sourceRow
        var dest = destLocal
        while left > 0 {
            let (index, local) = source.location(of: sourceCursor)
            let n = min(left, source.tiles[index].rows - local)
            if n == 0 { break }
            tile.write(from: source.tiles[index], sourceLocal: local, destLocal: dest, count: n)
            left -= n
            sourceCursor += n
            dest += n
        }
    }

    func overwrite(from source: ImageStorage, atRow row: Int) {
        var left = source.height
        var sourceRow = 0
        var destRow = row
        while left > 0 {
            let (si, sl) = source.location(of: sourceRow)
            let (di, dl) = location(of: destRow)
            let n = min(left, source.tiles[si].rows - sl, tiles[di].rows - dl)
            if n == 0 { break }
            tiles[di].write(from: source.tiles[si], sourceLocal: sl, destLocal: dl, count: n)
            left -= n
            sourceRow += n
            destRow += n
        }
    }

    func copyBytes(at position: Int, count: Int, into dest: UnsafeMutableRawPointer) -> Int {
        var remaining = count
        var pos = position
        var out = dest
        let total = height * rowBytes
        if pos >= total || remaining <= 0 { return 0 }
        if pos + remaining > total { remaining = total - pos }
        let requested = remaining
        while remaining > 0 {
            let row = pos / rowBytes
            let offset = pos % rowBytes
            let (index, local) = location(of: row)
            let available = rowBytes - offset
            let n = min(remaining, available)
            tiles[index].copyBytes(to: out, localRow: local, byteOffset: offset, count: n)
            remaining -= n
            pos += n
            out = out.advanced(by: n)
        }
        return requested
    }

    private func ensureWritableTile(reserving rows: Int = 1, exact: Bool = false) -> TileBuffer {
        if let last = tiles.last, last.spareRows > 0 { return last }
        let cap = exact ? min(Self.tileRows, max(rows, 1)) : Self.tileRows
        let tile = TileBuffer(rowBytes: rowBytes, rowCapacity: cap, ledger: PixelMetrics.threadLedger)
        tiles.append(tile)
        return tile
    }

    private func ensureBoundary(atRow row: Int) -> Int {
        var cursor = 0
        for index in tiles.indices {
            let end = cursor + tiles[index].rows
            if row == cursor { return index }
            if row < end {
                let right = tiles[index].split(atLocalRow: row - cursor)
                tiles.insert(right, at: index + 1)
                return index + 1
            }
            cursor = end
        }
        return tiles.count
    }

    private func location(of row: Int) -> (tile: Int, local: Int) {
        var cursor = 0
        for index in tiles.indices {
            let rows = tiles[index].rows
            if row < cursor + rows {
                return (index, row - cursor)
            }
            cursor += rows
        }
        return (max(tiles.count - 1, 0), 0)
    }
}

/// One viewport-sized frame (or a strip of one), RGBA8, row 0 at the top.
public struct RGBAImage: Equatable {
    public var width: Int
    public var height: Int
    private var storage: ImageStorage

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        storage = ImageStorage(width: max(width, 0))
        guard width > 0, height > 0, !pixels.isEmpty else { return }
        let rows = min(height, pixels.count / (width * 4))
        self.height = rows
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            storage.append(bytes: base, rows: rows)
        }
    }

    init(width: Int, height: Int, storage: ImageStorage) {
        self.width = width
        self.height = height
        self.storage = storage
    }

    /// Logical RGBA byte count (`width * height * 4`), not spare tile capacity.
    public var byteCount: Int { width * height * 4 }

    public var pixels: [UInt8] {
        get { storage.copiedArray() }
        set {
            if isKnownUniquelyReferenced(&storage), newValue.count == byteCount, width > 0 {
                newValue.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    let replacement = ImageStorage(width: width)
                    replacement.append(bytes: base, rows: height)
                    storage = replacement
                }
            } else {
                self = RGBAImage(width: width, height: height, pixels: newValue)
            }
        }
    }

    public static func == (lhs: RGBAImage, rhs: RGBAImage) -> Bool {
        if lhs.width != rhs.width || lhs.height != rhs.height { return false }
        if lhs.storage === rhs.storage { return true }
        return lhs.storage.bytesEqual(to: rhs.storage)
    }

    func withRow<T>(_ y: Int, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        storage.withRow(y, body)
    }

    public func crop(rows: Range<Int>) -> RGBAImage {
        let lower = max(0, rows.lowerBound)
        let upper = min(height, rows.upperBound)
        guard width > 0, upper > lower else {
            return RGBAImage(width: width, height: 0, pixels: [])
        }
        if lower == 0, upper == height { return self }
        let sliced = ImageStorage(width: width)
        sliced.appendRows(from: storage, sourceRow: lower, count: upper - lower, exact: true)
        return RGBAImage(width: width, height: upper - lower, storage: sliced)
    }

    public static func verticalJoin(_ parts: [RGBAImage]) -> RGBAImage? {
        let pieces = parts.filter { $0.height > 0 && $0.width > 0 }
        guard let width = pieces.first?.width, pieces.allSatisfy({ $0.width == width }) else { return nil }
        if pieces.count == 1 { return pieces[0] }
        let storage = ImageStorage(width: width)
        for piece in pieces {
            storage.append(from: piece.storage)
        }
        return RGBAImage(width: width, height: storage.height, storage: storage)
    }

    /// Top-down RGBA → CGImage. The provider reads the row tiles; it does not copy them.
    public func cgImage() -> CGImage? {
        guard width > 0, height > 0, storage.height == height,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let byteSize = width * height * 4
        let retained = Unmanaged.passRetained(storage)
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: nil,
            releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                let storage = Unmanaged<ImageStorage>.fromOpaque(info).takeUnretainedValue()
                return storage.copyBytes(at: Int(position), count: count, into: buffer)
            },
            releaseInfo: { info in
                guard let info else { return }
                Unmanaged<ImageStorage>.fromOpaque(info).release()
            }
        )
        guard let provider = CGDataProvider(directInfo: retained.toOpaque(), size: off_t(byteSize), callbacks: &callbacks) else {
            retained.release()
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Draws `image` into a top-down RGBA buffer (row 0 is the top).
    public static func fromCGImage(_ image: CGImage) -> RGBAImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 16)
        defer { scratch.deallocate() }
        guard let context = CGContext(
            data: scratch,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // This bitmap context stores row 0 at the top. A CTM flip or a later row swap
        // turns the image upside down (confirmed by testCGImageRoundTripKeepsTopRowAtTheTop).
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let storage = ImageStorage(width: width)
        storage.append(bytes: scratch, rows: height)
        return RGBAImage(width: width, height: height, storage: storage)
    }

    mutating func insertRows(_ rows: RGBAImage, at row: Int) {
        guard rows.height > 0, rows.width == width else { return }
        ensureUnique()
        storage.insert(rows.storage, atRow: row)
        height = storage.height
    }

    mutating func overwriteRows(_ range: Range<Int>, with rows: RGBAImage) {
        guard rows.width == width, rows.height == range.count, range.lowerBound >= 0 else { return }
        ensureUnique()
        storage.overwrite(from: rows.storage, atRow: range.lowerBound)
    }

    /// Removes rows from the bottom without copying the prefix that stays.
    mutating func removeLastRows(_ count: Int) {
        guard count > 0 else { return }
        ensureUnique()
        storage.removeLastRows(count)
        height = storage.height
    }

    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.clone()
        }
    }
}
