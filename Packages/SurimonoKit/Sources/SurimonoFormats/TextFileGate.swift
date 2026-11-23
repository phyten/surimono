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

    /// What the gate says about the beginning of some bytes.
    public enum Verdict: Equatable, Sendable {
        /// Not a kind the gate looks at, or text that nothing names a language for: the caller goes by the name and
        /// type as it always did.
        case notConcerned
        /// Opens as plain text, in this language as far as the beginning tells.
        case text(SourceLanguage?)
        /// Looked at, and not text. Never laid out as text, wherever the bytes came from.
        case binary
    }

    /// What the gate says about a file.
    public enum FileVerdict: Equatable, Sendable {
        case decided(Verdict)
        /// There is no file there. The name alone decides, and opening reports the error.
        case missing
        /// The file may not be read yet, as before a sandboxed app is given access. Nothing is known: it is a
        /// candidate to be decided once it can be read.
        case undecided
        /// A pipe, a device or a folder, a file outside the folder it had to lie in, or one that fails to be read.
        case refused
    }

    public struct Refusal: Error, Equatable, Sendable {
        public init() {}
    }

    private enum Kind { case transportStream, propertyList, untyped }

    /// Extensions `SourceLanguage` reads as TypeScript that macOS gives to MPEG video.
    private static let streamExtensions: Set<String> = ["ts", "mts"]

    /// A type that says nothing about the content.
    private static func isGeneric(_ type: UTType?) -> Bool {
        guard let type else { return true }
        return type == .data || type == .item || type == .content || type == .unixExecutable || type.isDynamic
    }

    /// The name is the one the file really has, and `type` the one the system gave it when that is known. A file of
    /// a type that means something else (a movie, an archive) is none of the gate's kinds whatever is inside it.
    private static func kind(fileName: String, type: UTType?) -> Kind? {
        let suffix = (fileName as NSString).pathExtension.lowercased()
        let named = suffix.isEmpty ? nil : UTType(filenameExtension: suffix)
        let actual = type ?? named
        if streamExtensions.contains(suffix) || actual?.conforms(to: .mpeg2TransportStream) == true {
            return .transportStream
        }
        if suffix == "plist" || actual?.conforms(to: .propertyList) == true { return .propertyList }
        guard isGeneric(actual), DocumentFormat(fileExtension: suffix) == nil else { return nil }
        // An extension the system knows as something this app reads (an image format) is not untyped either.
        if let named, !isGeneric(named), DocumentFormat(contentType: named) != nil { return nil }
        return isGeneric(named) ? .untyped : nil
    }

    /// Whether the gate looks at files of this name and type at all. For the others nothing is read.
    public static func concerns(fileName: String, type: UTType? = nil) -> Bool {
        kind(fileName: fileName, type: type) != nil
    }

    /// The verdict for the beginning of a file. `isWhole` tells that `head` is all of it, which matters for a text
    /// in UTF-16 that ends in the middle of a character and for a stream of a packet or two.
    public static func verdict(fileName: String, type: UTType? = nil, head: Data, isWhole: Bool) -> Verdict {
        guard let kind = kind(fileName: fileName, type: type) else { return .notConcerned }
        let bytes = [UInt8](head.prefix(headLength))
        let text = isText(bytes, isWhole: isWhole)
        func language() -> SourceLanguage? {
            SourceLanguage.detect(fileName: fileName, text: { TextDecoding.decode(Data(bytes)).text })
        }
        switch kind {
        case .transportStream:
            // Source text can line a "G" up where packets would start; a stream is never also clean UTF-8.
            let stream = hasPacketStructure(bytes, isWhole: isWhole) && !isCleanUTF8(bytes, isWhole: isWhole)
            return text && !stream ? .text(language()) : .binary
        case .propertyList:
            return text && !isBinaryPropertyList(bytes) ? .text(language()) : .binary
        case .untyped:
            // A fixed name such as "Dockerfile" is no more a promise of text than an extension is.
            guard text else { return .binary }
            return language().map { .text($0) } ?? .notConcerned
        }
    }

    /// The verdict for bytes that are all there: a reload, a binder's own read, what Shortcuts hands over.
    public static func verdict(fileName: String, type: UTType? = nil, data: Data) -> Verdict {
        verdict(fileName: fileName, type: type, head: data.prefix(headLength), isWhole: data.count <= headLength)
    }

    /// Whether bytes that are about to be shown under this name were looked at and are not text.
    public static func refuses(fileName: String, type: UTType? = nil, data: Data) -> Bool {
        verdict(fileName: fileName, type: type, data: data) == .binary
    }

    // MARK: Files

    /// The verdict for a file, reading at most `headLength` bytes of it. With `root`, a file that opens outside
    /// that folder (through a link) is refused. A file of no kind the gate looks at is not opened at all.
    public static func inspect(_ url: URL, within root: String? = nil) -> FileVerdict {
        inspection(of: url, within: root).verdict
    }

    /// The verdict together with the size of the file that was looked at, for what must turn a text over a limit
    /// away before anything loads it. The size is nil when the file was not opened.
    public static func inspection(of url: URL, within root: String? = nil) -> (verdict: FileVerdict, size: Int?) {
        guard url.isFileURL else { return (.decided(.notConcerned), nil) }
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard concerns(fileName: url.lastPathComponent, type: type) else { return (.decided(.notConcerned), nil) }
        let descriptor: Int32
        do {
            descriptor = try ConfinedFile.open(url)
        } catch let error as POSIXError {
            switch error.code {
            case .ENOENT, .ENOTDIR: return (.missing, nil)
            case .EACCES, .EPERM: return (.undecided, nil)
            default: return (.refused, nil)
            }
        } catch {
            return (.refused, nil)
        }
        defer { Darwin.close(descriptor) }
        guard
            let opened = try? inspect(
                descriptor: descriptor, fileName: url.lastPathComponent, type: type, within: root)
        else { return (.refused, nil) }
        return (.decided(opened.verdict), opened.size)
    }

    /// The verdict for the file a descriptor is open on, with its size and the bytes that were read for it. Every
    /// reading of a file comes through here, so the test that no more than the beginning is read holds for all.
    package static func inspect(
        descriptor: Int32, fileName: String, type: UTType? = nil, within root: String? = nil
    ) throws -> (verdict: Verdict, size: Int, head: Data) {
        let size = try check(descriptor, within: root)
        let head = try readHead(descriptor)
        return (verdict(fileName: fileName, type: type, head: head, isWhole: size <= head.count), size, head)
    }

    /// The whole of a file of a kind the gate looks at, read through one descriptor: what is checked (a regular
    /// file, its size, its beginning) and what is read are the same open file, so nothing can be put in its place in
    /// between, and a video or a text over the limit is turned away before it is loaded. Throws `Refusal` for a
    /// file that is not text.
    public static func read(_ url: URL, within root: String? = nil, maximumSize: Int) throws -> Data {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let descriptor = try ConfinedFile.open(url)
        defer { Darwin.close(descriptor) }
        let opened = try inspect(descriptor: descriptor, fileName: url.lastPathComponent, type: type, within: root)
        guard opened.size <= maximumSize else { throw CocoaError(.fileReadTooLarge) }
        guard opened.verdict != .binary else { throw Refusal() }
        // The file can grow after it was measured; the limit holds while reading too.
        let rest = try ConfinedFile.readBytes(
            descriptor, size: max(0, opened.size - opened.head.count), maximumSize: maximumSize - opened.head.count)
        return opened.head + rest
    }

    // The descriptor, not the path, is what is checked and read: the path could name something else by now.
    private static func check(_ descriptor: Int32, within root: String?) throws -> Int {
        if let root {
            let opened = try ConfinedFile.openedPath(descriptor)
            guard opened.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
                throw CocoaError(.fileReadNoPermission)
            }
        }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw ConfinedFile.posixError() }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { throw CocoaError(.fileReadNoPermission) }
        return Int(info.st_size)
    }

    // An error is an error: bytes that could not be read are not an empty text.
    private static func readHead(_ descriptor: Int32) throws -> Data {
        var head = [UInt8](repeating: 0, count: headLength)
        var count = 0
        while count < headLength {
            let read = head.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress.map { $0 + count }, headLength - count)
            }
            if read < 0 {
                if errno == EINTR { continue }
                throw ConfinedFile.posixError()
            }
            if read == 0 { break }
            count += read
        }
        return Data(head.prefix(count))
    }

    // MARK: What text looks like

    private static func allowed(_ value: UInt32) -> Bool {
        value >= 0x20 || [0x09, 0x0A, 0x0C, 0x0D, 0x1B].contains(value)
    }

    /// Text has no control characters but tabs, line breaks, form feeds and escapes. The encoding is told as
    /// `TextDecoding` tells it. With a byte order mark the bytes must also be that encoding and nothing else: a
    /// character cut off by the end of the file, an unpaired surrogate or a value outside Unicode is not text. A
    /// sample that stops at `headLength` may stop inside a character, and that is not held against it.
    ///
    /// UTF-16 without a byte order mark is refused, because `TextDecoding` does not read it either: it would be
    /// laid out as UTF-8 with a null character after every letter.
    static func isText(_ bytes: [UInt8], isWhole: Bool) -> Bool {
        guard let mark = TextDecoding.byteOrderMark(of: bytes) else { return bytes.allSatisfy { allowed(UInt32($0)) } }
        var content = Array(bytes.dropFirst(mark.length))
        if mark.encoding == .utf8 { return isCleanUTF8(content, isWhole: isWhole) }
        let width = mark.encoding == .utf16LittleEndian || mark.encoding == .utf16BigEndian ? 2 : 4
        let little = mark.encoding == .utf16LittleEndian || mark.encoding == .utf32LittleEndian
        if content.count % width != 0 {
            guard !isWhole else { return false }
            content.removeLast(content.count % width)
        }
        var units: [UInt32] = []
        units.reserveCapacity(content.count / width)
        for index in stride(from: 0, to: content.count, by: width) {
            var value: UInt32 = 0
            for offset in 0..<width {
                value = value << 8 | UInt32(content[index + (little ? width - 1 - offset : offset)])
            }
            units.append(value)
        }
        if width == 4 { return units.allSatisfy { Unicode.Scalar($0) != nil && allowed($0) } }
        var words = units.map { UInt16(truncatingIfNeeded: $0) }
        // The sample may stop between the two halves of a character.
        if !isWhole, let last = words.last, (0xD800...0xDBFF).contains(last) { words.removeLast() }
        return decodes(words, as: UTF16.self)
    }

    /// Whether every character decodes, strictly, and none is a control character.
    private static func decodes<Codec: UnicodeCodec>(_ units: [Codec.CodeUnit], as codec: Codec.Type) -> Bool {
        var decoder = Codec()
        var iterator = units.makeIterator()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): if !allowed(scalar.value) { return false }
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    /// Whether the bytes are UTF-8 with no control characters, with a byte order mark or without. A sample that is
    /// not the whole file may stop inside a character.
    static func isCleanUTF8(_ bytes: [UInt8], isWhole: Bool) -> Bool {
        var content = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? Array(bytes.dropFirst(3)) : bytes
        if !isWhole {
            // Up to three bytes at the end can be the beginning of a character whose rest was not read.
            var tail = 0
            while tail < 3, tail < content.count, content[content.count - 1 - tail] & 0xC0 == 0x80 { tail += 1 }
            if tail < content.count {
                // Only bytes that can begin a character are held back: 0xFF, or 0xC0, never become one however
                // the file goes on.
                let lead = content[content.count - 1 - tail]
                let length =
                    (0xF0...0xF4).contains(lead)
                    ? 4
                    : (0xE0...0xEF).contains(lead)
                        ? 3
                        : (0xC2...0xDF).contains(lead) ? 2 : 1
                if length > tail + 1 { content.removeLast(tail + 1) }
            }
        }
        return decodes(content, as: UTF8.self)
    }

    // A transport stream is packets of 188 bytes (192 with a timestamp in front, 204 with error correction behind),
    // and may begin anywhere, even after other bytes. A packet starts with 0x47, has its error bit clear and says
    // whether it carries a payload, an adaptation field or both ("neither" is not allowed); an adaptation field
    // has a length that fits the packet. Five such packets in a
    // row anywhere in the sample make a stream. So does a file that is nothing but whole packets, however few.
    static func hasPacketStructure(_ bytes: [UInt8], isWhole: Bool) -> Bool {
        func isPacket(at index: Int) -> Bool {
            guard index + 3 < bytes.count, bytes[index] == 0x47, bytes[index + 1] & 0x80 == 0 else { return false }
            // The adaptation field says how long it is, and has to fit the packet: all of what follows the header
            // when there is no payload, and less when there is. Source text that begins like a header does not
            // go on like one.
            switch bytes[index + 3] & 0x30 {
            case 0x10: return true
            case 0x20: return index + 4 >= bytes.count || bytes[index + 4] == 183
            case 0x30: return index + 4 >= bytes.count || bytes[index + 4] <= 182
            default: return false
            }
        }
        for (size, lead) in [(188, 0), (192, 4), (204, 0)] {
            for phase in 0..<min(size, bytes.count) {
                var run = 0
                var index = phase
                while index + 3 < bytes.count {
                    run = isPacket(at: index) ? run + 1 : 0
                    if run >= 5 { return true }
                    index += size
                }
            }
            if isWhole, !bytes.isEmpty, bytes.count % size == 0,
                stride(from: lead, to: bytes.count, by: size).allSatisfy(isPacket)
            {
                return true
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
