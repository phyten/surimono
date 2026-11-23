import Foundation

/// Source files whose extension also belongs to a kind of file that is not text: `.ts` is TypeScript and an MPEG
/// transport stream (the type macOS gives it), and a `.plist` can be XML or binary. The beginning of the file tells
/// which one it is, so a video is never laid out as text.
public enum BinaryLookalike {
    /// How much of the file `isBinary` needs.
    public static let headLength = 1024

    public static let fileExtensions: Set<String> = ["ts", "plist"]

    /// Whether a file with this extension, beginning with `head`, is the binary kind and not text.
    public static func isBinary(_ head: Data, fileExtension: String) -> Bool {
        let bytes = [UInt8](head.prefix(headLength))
        switch fileExtension.lowercased() {
        case "ts":
            // Text has no control bytes, whatever its encoding, unless a byte order mark says it is UTF-16 or
            // UTF-32. The packets alone do not decide: TypeScript can have a "G" where a packet would start.
            guard !hasUnicodeSignature(bytes) else { return false }
            let control = bytes.contains { $0 < 0x09 || (0x0E...0x1A).contains($0) }
            return bytes.contains(0) || (isTransportStream(bytes) && control)
        case "plist": return bytes.starts(with: Array("bplist".utf8))
        default: return false
        }
    }

    /// The file URL's own beginning, read without loading the file. A file that cannot be read is not called binary;
    /// opening it reports the real error.
    public static func isBinary(at url: URL) -> Bool {
        let suffix = url.pathExtension.lowercased()
        guard fileExtensions.contains(suffix), let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headLength) else { return false }
        return isBinary(head, fileExtension: suffix)
    }

    // A transport stream is packets of 188 bytes (192 with a timestamp in front, 204 with error correction behind),
    // each starting with 0x47.
    private static func isTransportStream(_ bytes: [UInt8]) -> Bool {
        for (start, size) in [(0, 188), (4, 192), (0, 204)] where bytes.count > start + size {
            if bytes[start] == 0x47, bytes[start + size] == 0x47 { return true }
        }
        return false
    }

    // UTF-16 and UTF-32 text is full of zero bytes.
    private static func hasUnicodeSignature(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0, 0, 0xFE, 0xFF])
    }
}
