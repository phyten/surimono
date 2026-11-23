import Darwin
import Foundation
import UniformTypeIdentifiers

/// The one place that decides whether a file whose name does not settle it may be opened as text: `.ts` (TypeScript,
/// and what macOS calls an MPEG transport stream), `.plist` (XML or binary), and names macOS has no type for
/// (`Dockerfile`, `.env`, a script that only its `#!` line names). It goes by the beginning of the file, read from
/// the opened descriptor without waiting, so a video is never loaded to be told from text and a pipe never holds a
/// window up. Every way a file comes in asks here, so they all accept the same files.
public enum TextFileGate {
    /// How much of a file the decision reads.
    public static let headLength = 4096

    public enum Decision: Equatable, Sendable {
        /// The name has a format of its own or says nothing this gate knows; the caller goes by the name as before.
        case unrelated
        /// Opens as plain text, in this language as far as the beginning of the file tells.
        case text(SourceLanguage?)
        /// Not text, or not a regular file: never laid out as text.
        case refused
    }

    private enum Kind { case transportStream, propertyList, untyped }

    /// Extensions `SourceLanguage` reads as TypeScript that macOS gives to MPEG video.
    private static let streamExtensions: Set<String> = ["ts", "mts"]

    private static func kind(of fileName: String) -> Kind? {
        let suffix = (fileName as NSString).pathExtension.lowercased()
        if streamExtensions.contains(suffix) { return .transportStream }
        if suffix == "plist" { return .propertyList }
        if DocumentFormat(fileExtension: suffix) != nil { return nil }
        if let type = UTType(filenameExtension: suffix), DocumentFormat(contentType: type) != nil { return nil }
        return .untyped
    }

    /// The decision for the beginning of a file.
    public static func decide(fileName: String, head: Data) -> Decision {
        guard let kind = kind(of: fileName) else { return .unrelated }
        let bytes = [UInt8](head.prefix(headLength))
        let text = isPlausibleText(bytes)
        func language() -> SourceLanguage? {
            SourceLanguage.detect(fileName: fileName, text: { TextDecoding.decode(Data(bytes)).text })
        }
        switch kind {
        case .transportStream:
            return text && !isTransportStream(bytes) ? .text(language()) : .refused
        case .propertyList:
            return text && !isBinaryPropertyList(bytes) ? .text(language()) : .refused
        case .untyped:
            // A fixed name such as "Dockerfile" is no more a promise of text than an extension is.
            guard text, let language = language() else { return .unrelated }
            return .text(language)
        }
    }

    /// Whether bytes that are about to be shown under this name must not be: a reload, a binder's own read, what
    /// Shortcuts hands over. The same decision as for the file, on the bytes that are really used.
    public static func refuses(fileName: String, data: Data) -> Bool {
        decide(fileName: fileName, head: data.prefix(headLength)) == .refused
    }

    /// The decision for a file, reading at most `headLength` bytes of it. With `root`, a file that opens outside
    /// that folder (through a link) is refused. A file that cannot be opened is `.unrelated`: opening it reports
    /// the real error.
    public static func decide(_ url: URL, within root: String? = nil) -> Decision {
        let name = url.lastPathComponent
        guard url.isFileURL, let kind = kind(of: name) else { return .unrelated }
        let refusal: Decision = kind == .untyped ? .unrelated : .refused
        guard let descriptor = try? ConfinedFile.open(url) else { return .unrelated }
        defer { Darwin.close(descriptor) }
        if let root {
            guard let opened = try? ConfinedFile.openedPath(descriptor),
                opened.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            else { return refusal }
        }
        // The descriptor, not the path, is what is checked and read: the path could name something else by now.
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return refusal }
        var head = [UInt8](repeating: 0, count: headLength)
        var count = 0
        while count < headLength {
            let read = head.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress.map { $0 + count }, headLength - count)
            }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { break }
            count += read
        }
        return decide(fileName: name, head: Data(head.prefix(count)))
    }

    // Text has no control bytes but tabs, line breaks, form feeds and escapes, in any encoding that is not UTF-16
    // or UTF-32; those are told by their byte order mark and then held to the same rule, character by character.
    static func isPlausibleText(_ bytes: [UInt8]) -> Bool {
        func allowed(_ value: UInt32) -> Bool { value >= 0x20 || [0x09, 0x0A, 0x0C, 0x0D, 0x1B].contains(value) }
        func units(_ width: Int, from start: Int, littleEndian: Bool) -> Bool {
            var index = start
            while index + width <= bytes.count {
                var value: UInt32 = 0
                for offset in 0..<width {
                    let byte = UInt32(bytes[index + (littleEndian ? width - 1 - offset : offset)])
                    value = value << 8 | byte
                }
                guard allowed(value) else { return false }
                index += width
            }
            return true
        }
        if bytes.starts(with: [0xFF, 0xFE, 0, 0]) { return units(4, from: 4, littleEndian: true) }
        if bytes.starts(with: [0, 0, 0xFE, 0xFF]) { return units(4, from: 4, littleEndian: false) }
        if bytes.starts(with: [0xFF, 0xFE]) { return units(2, from: 2, littleEndian: true) }
        if bytes.starts(with: [0xFE, 0xFF]) { return units(2, from: 2, littleEndian: false) }
        return bytes.allSatisfy { allowed(UInt32($0)) }
    }

    // A transport stream is packets of 188 bytes (192 with a timestamp in front, 204 with error correction behind),
    // each starting with 0x47, and may begin anywhere inside a packet. Five in a row are asked for: source text can
    // have a "G" where one packet would start, not where five would. A beginning too short to hold five is left to
    // the test for text.
    static func isTransportStream(_ bytes: [UInt8]) -> Bool {
        let wanted = 5
        for size in [188, 192, 204] {
            for start in 0..<size where start + (wanted - 1) * size < bytes.count {
                if (0..<wanted).allSatisfy({ bytes[start + $0 * size] == 0x47 }) { return true }
            }
        }
        return false
    }

    // "bplist" and a two-digit version ("bplist00"). An old-style text property list may begin with a key such as
    // `bplistCache`, which is not a version.
    static func isBinaryPropertyList(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 8 && bytes.starts(with: Array("bplist".utf8))
            && bytes[6...7].allSatisfy { (0x30...0x39).contains($0) }
    }
}
