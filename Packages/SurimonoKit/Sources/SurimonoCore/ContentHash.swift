import CryptoKit
import Foundation

/// A SHA-256 digest used as the key for per-document settings.
public struct ContentHash: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    /// 64 lowercase hexadecimal characters.
    public let hex: String

    public init?(hex: String) {
        guard hex.utf8.count == 64,
            hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        self.hex = hex.lowercased()
    }

    private init(digest: SHA256.Digest) {
        hex = digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func of(_ data: Data) -> ContentHash {
        ContentHash(digest: SHA256.hash(data: data))
    }

    /// Reads the file in fixed-size chunks so that large PDFs or ZIPs are not held in memory twice.
    public static func ofFile(at url: URL) throws -> ContentHash {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return ContentHash(digest: hasher.finalize())
    }

    /// Order-independent key for a multiset of images, preserving duplicates.
    /// Persistent format: SHA256(UTF8("surimono-set-v1\n") + UTF8(String(count)) + UTF8("\n")
    /// + raw 32-byte digests sorted bytewise ascending and concatenated).
    /// The count includes duplicates and is decimal without padding.
    public static func imageSet(_ hashes: [ContentHash]) -> ContentHash {
        var hasher = SHA256()
        hasher.update(data: Data("surimono-set-v1\n\(hashes.count)\n".utf8))
        for hash in hashes.sorted() {
            let nibbles = hash.hex.utf8.map { $0 <= 57 ? $0 - 48 : $0 - 87 }
            let bytes = stride(from: 0, to: nibbles.count, by: 2).map {
                (nibbles[$0] << 4) | nibbles[$0 + 1]
            }
            hasher.update(data: Data(bytes))
        }
        return ContentHash(digest: hasher.finalize())
    }

    /// The first 6 hex characters, for display ("sha256 1ae2a7…").
    public var abbreviated: String { String(hex.prefix(6)) }

    public var description: String { hex }

    public static func < (lhs: ContentHash, rhs: ContentHash) -> Bool {
        lhs.hex < rhs.hex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let hash = ContentHash(hex: value) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected a SHA-256 digest of 64 hexadecimal characters.")
        }
        self = hash
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}
