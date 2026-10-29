import Compression
import CoreFoundation
import Foundation

/// An in-memory ZIP reader; no entry is extracted to the filesystem.
public struct ZipArchive: Sendable {
    public struct Entry: Equatable, Sendable {
        public let path: String
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let method: UInt16
        public let crc32: UInt32
        public let isDirectory: Bool
        public let isEncrypted: Bool
        fileprivate let localHeaderOffset: UInt64
    }

    public struct Limits: Equatable, Sendable {
        public var maximumEntryCount: Int
        public var maximumEntrySize: UInt64
        /// Callers must account for this budget across reads, including repeated reads.
        public var maximumTotalSize: UInt64

        public init(
            maximumEntryCount: Int = 10_000, maximumEntrySize: UInt64 = 256 * 1024 * 1024,
            maximumTotalSize: UInt64 = 1024 * 1024 * 1024
        ) {
            self.maximumEntryCount = maximumEntryCount
            self.maximumEntrySize = maximumEntrySize
            self.maximumTotalSize = maximumTotalSize
        }

        public static let `default` = Limits()
    }

    public enum ReadError: Error, Equatable, Sendable {
        case notAZipArchive, corrupted, encrypted
        case unsupportedCompression(UInt16)
        case tooManyEntries, entryTooLarge
        case checksumMismatch
    }

    public let entries: [Entry]
    /// Before each read, callers must compare the declared size with their remaining total budget.
    /// Subtract accepted sizes from `maximumTotalSize` to avoid overflowing a running sum.
    public let limits: Limits
    private let bytes: ZipBytes
    private let directoryOffset: Int

    /// Parses only the central directory; entry data is validated and expanded on demand.
    public init(data: Data, limits: Limits = .default) throws {
        let bytes = ZipBytes(data: data)
        let directory = try Self.directory(in: bytes)
        guard limits.maximumEntryCount >= 0, directory.count <= UInt64(limits.maximumEntryCount) else {
            throw ReadError.tooManyEntries
        }
        guard directory.count <= UInt64(directory.size / 46) else { throw ReadError.corrupted }
        var entries: [Entry] = []
        var cursor = directory.offset
        let end = directory.offset + directory.size
        for _ in 0..<Int(directory.count) {
            guard cursor <= end, end - cursor >= 46, try bytes.u32(cursor) == 0x0201_4B50 else {
                throw ReadError.corrupted
            }
            let nameLength = Int(try bytes.u16(cursor + 28))
            let extraLength = Int(try bytes.u16(cursor + 30))
            let commentLength = Int(try bytes.u16(cursor + 32))
            let length = 46 + nameLength + extraLength + commentLength
            guard length <= end - cursor else { throw ReadError.corrupted }
            let rawName = try bytes.slice(cursor + 46, nameLength)
            let extras = try Self.extraFields(bytes.slice(cursor + 46 + nameLength, extraLength))
            let flags = try bytes.u16(cursor + 8)
            let path = try Self.decodePath(rawName, flags: flags, extras: extras)
            var compressed = UInt64(try bytes.u32(cursor + 20))
            var uncompressed = UInt64(try bytes.u32(cursor + 24))
            var offset = UInt64(try bytes.u32(cursor + 42))
            var disk = UInt32(try bytes.u16(cursor + 34))
            if compressed == UInt32.max || uncompressed == UInt32.max || offset == UInt32.max || disk == UInt16.max {
                guard let extra = extras[1] else { throw ReadError.corrupted }
                let extended = ZipBytes(data: extra)
                var position = 0
                if uncompressed == UInt32.max {
                    uncompressed = try extended.u64(position)
                    position += 8
                }
                if compressed == UInt32.max {
                    compressed = try extended.u64(position)
                    position += 8
                }
                if offset == UInt32.max {
                    offset = try extended.u64(position)
                    position += 8
                }
                if disk == UInt16.max { disk = try extended.u32(position) }
            }
            guard disk == 0 else { throw ReadError.corrupted }
            let attributes = try bytes.u32(cursor + 38)
            entries.append(
                Entry(
                    path: path, compressedSize: compressed, uncompressedSize: uncompressed,
                    method: try bytes.u16(cursor + 10), crc32: try bytes.u32(cursor + 16),
                    isDirectory: path.hasSuffix("/") || attributes & 0x10 != 0
                        || (attributes >> 16) & 0xF000 == 0x4000,
                    isEncrypted: flags & 0x41 != 0, localHeaderOffset: offset))
            cursor += length
        }
        // A central directory may end with an optional digital signature record.
        if cursor < end {
            guard end - cursor >= 6, try bytes.u32(cursor) == 0x0505_4B50,
                Int(try bytes.u16(cursor + 4)) == end - cursor - 6
            else { throw ReadError.corrupted }
        }
        self.bytes = bytes
        self.directoryOffset = directory.offset
        self.entries = entries
        self.limits = limits
    }

    public func contents(of entry: Entry) throws -> Data {
        guard entries.contains(entry) else { throw ReadError.corrupted }
        guard !entry.isEncrypted else { throw ReadError.encrypted }
        guard entry.uncompressedSize <= limits.maximumEntrySize,
            let expectedSize = Int(exactly: entry.uncompressedSize)
        else { throw ReadError.entryTooLarge }
        guard entry.method == 0 || entry.method == 8 else { throw ReadError.unsupportedCompression(entry.method) }
        guard let offset = Int(exactly: entry.localHeaderOffset), offset <= directoryOffset,
            directoryOffset - offset >= 30, try bytes.u32(offset) == 0x0403_4B50
        else { throw ReadError.corrupted }
        let headerSize = 30 + Int(try bytes.u16(offset + 26)) + Int(try bytes.u16(offset + 28))
        guard headerSize <= directoryOffset - offset else { throw ReadError.corrupted }
        let start = offset + headerSize
        guard let compressedSize = Int(exactly: entry.compressedSize), compressedSize <= directoryOffset - start else {
            throw ReadError.corrupted
        }
        let output: Data
        if entry.method == 0 {
            guard compressedSize <= expectedSize else { throw ReadError.entryTooLarge }
            guard compressedSize == expectedSize else { throw ReadError.corrupted }
            output = try bytes.slice(start, compressedSize)
        } else {
            output = try inflate(start: start, count: compressedSize, expectedSize: expectedSize)
        }
        guard ZipCRC32.checksum(output) == entry.crc32 else { throw ReadError.checksumMismatch }
        return output
    }

    private func inflate(start: Int, count: Int, expectedSize: Int) throws -> Data {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buffer.deallocate() }
        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: buffer, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else {
            throw ReadError.corrupted
        }
        defer { compression_stream_destroy(&stream) }
        return try bytes.data.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { throw ReadError.corrupted }
            stream.src_ptr = source.advanced(by: start)
            stream.src_size = count
            var output = Data()
            while true {
                let remaining = expectedSize - output.count
                // Probe at most one byte beyond the declaration, without allocating the declared size up front.
                let capacity = remaining >= 64 * 1024 ? 64 * 1024 : remaining + 1
                stream.dst_ptr = buffer
                stream.dst_size = capacity
                let previousInput = stream.src_size
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = capacity - stream.dst_size
                guard produced <= remaining else { throw ReadError.entryTooLarge }
                guard status != COMPRESSION_STATUS_ERROR else { throw ReadError.corrupted }
                output.append(buffer, count: produced)
                if status == COMPRESSION_STATUS_END {
                    guard output.count == expectedSize, stream.src_size == 0 else { throw ReadError.corrupted }
                    return output
                }
                guard status == COMPRESSION_STATUS_OK, produced > 0 || stream.src_size < previousInput else {
                    throw ReadError.corrupted
                }
            }
        }
    }

    private struct Directory {
        let count: UInt64
        let offset: Int
        let size: Int
    }

    private static func directory(in bytes: ZipBytes) throws -> Directory {
        guard bytes.data.count >= 22 else { throw ReadError.notAZipArchive }
        var endOffset: Int?
        for offset in stride(from: bytes.data.count - 22, through: max(0, bytes.data.count - 65_557), by: -1) {
            if try bytes.u32(offset) == 0x0605_4B50,
                Int(try bytes.u16(offset + 20)) == bytes.data.count - offset - 22
            {
                endOffset = offset
                break
            }
        }
        guard let end = endOffset else { throw ReadError.notAZipArchive }
        guard try bytes.u16(end + 4) == 0, try bytes.u16(end + 6) == 0 else { throw ReadError.corrupted }
        var count = UInt64(try bytes.u16(end + 10))
        guard UInt64(try bytes.u16(end + 8)) == count else { throw ReadError.corrupted }
        var size = UInt64(try bytes.u32(end + 12))
        var offset = UInt64(try bytes.u32(end + 16))
        var boundary = end
        let hasLocator = try end >= 20 && bytes.u32(end - 20) == 0x0706_4B50
        if hasLocator {
            let locator = end - 20
            guard try bytes.u32(locator + 4) == 0, try bytes.u32(locator + 16) == 1,
                let record = Int(exactly: try bytes.u64(locator + 8)), record <= locator, locator - record >= 56,
                try bytes.u32(record) == 0x0606_4B50
            else { throw ReadError.corrupted }
            let recordSize = try bytes.u64(record + 4)
            guard recordSize >= 44, recordSize == UInt64(locator - record - 12),
                try bytes.u32(record + 16) == 0, try bytes.u32(record + 20) == 0
            else { throw ReadError.corrupted }
            count = try bytes.u64(record + 32)
            guard try bytes.u64(record + 24) == count else { throw ReadError.corrupted }
            size = try bytes.u64(record + 40)
            offset = try bytes.u64(record + 48)
            boundary = record
        } else if count == UInt16.max || size == UInt32.max || offset == UInt32.max {
            throw ReadError.corrupted
        }
        guard let start = Int(exactly: offset), let length = Int(exactly: size), start <= boundary,
            length <= boundary - start
        else { throw ReadError.corrupted }
        return Directory(count: count, offset: start, size: length)
    }

    private static func extraFields(_ data: Data) throws -> [UInt16: Data] {
        let bytes = ZipBytes(data: data)
        var fields: [UInt16: Data] = [:]
        var cursor = 0
        while cursor < data.count {
            guard data.count - cursor >= 4 else { throw ReadError.corrupted }
            let id = try bytes.u16(cursor)
            let size = Int(try bytes.u16(cursor + 2))
            guard fields[id] == nil else { throw ReadError.corrupted }
            fields[id] = try bytes.slice(cursor + 4, size)
            cursor += 4 + size
        }
        return fields
    }

    private static func decodePath(_ raw: Data, flags: UInt16, extras: [UInt16: Data]) throws -> String {
        var name: String?
        if let unicode = extras[0x7075], unicode.count >= 5, unicode.first == 1 {
            let bytes = ZipBytes(data: unicode)
            if try bytes.u32(1) == ZipCRC32.checksum(raw) {
                name = String(data: try bytes.slice(5, unicode.count - 5), encoding: .utf8)
            }
        }
        if name == nil {
            name = String(data: raw, encoding: .utf8)
            if name == nil && flags & 0x800 == 0 {
                let japanese = String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
                let cp437 = String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(
                        CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
                // CP437 is available through CoreFoundation; Latin-1 is only a last-resort fallback.
                name =
                    String(data: raw, encoding: japanese) ?? String(data: raw, encoding: cp437)
                    ?? String(data: raw, encoding: .isoLatin1)
            }
        }
        guard var path = name, !path.contains("\0") else { throw ReadError.corrupted }
        path = path.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("/") || path.hasPrefix("./") {
            path.removeFirst(path.hasPrefix("./") ? 2 : 1)
        }
        return path
    }
}

/// The images of an archive in display order, and what was left out.
public struct ZipImageSelection: Equatable, Sendable {
    public let images: [ZipArchive.Entry]
    public let excludedPaths: [String]

    public init(archive: ZipArchive) {
        var images: [ZipArchive.Entry] = []
        var excluded: [String] = []
        for entry in archive.entries.sorted(by: { NaturalOrder.arePathsInIncreasingOrder($0.path, $1.path) }) {
            guard !entry.isDirectory else { continue }
            let components = entry.path.split(separator: "/")
            let hidden = components.contains { $0.hasPrefix(".") }
            if components.isEmpty || hidden || components.first == "__MACOSX"
                || DocumentFormat(fileExtension: (entry.path as NSString).pathExtension) != .image
            {
                excluded.append(entry.path)
            } else {
                images.append(entry)
            }
        }
        self.images = images
        self.excludedPaths = excluded
    }
}

private struct ZipBytes: Sendable {
    let data: Data

    func slice(_ offset: Int, _ count: Int) throws -> Data {
        try check(offset, count)
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }

    func u16(_ offset: Int) throws -> UInt16 { try integer(offset) }
    func u32(_ offset: Int) throws -> UInt32 { try integer(offset) }
    func u64(_ offset: Int) throws -> UInt64 { try integer(offset) }

    private func integer<T: FixedWidthInteger & UnsignedInteger>(_ offset: Int) throws -> T {
        let count = MemoryLayout<T>.size
        try check(offset, count)
        var value: T = 0
        for index in 0..<count { value |= T(data[data.startIndex + offset + index]) << (index * 8) }
        return value
    }

    private func check(_ offset: Int, _ count: Int) throws {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw ZipArchive.ReadError.corrupted
        }
    }
}

private enum ZipCRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xEDB8_8320) }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data { value = (value >> 8) ^ table[Int((value ^ UInt32(byte)) & 0xFF)] }
        return value ^ UInt32.max
    }
}
