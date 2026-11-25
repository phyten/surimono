import Foundation
import cmark_gfm

/// Classify visible characters but write from the original text node. Decoding into the
/// output would turn an escaped angle bracket into markup, or decode a nested escape twice.
struct VerticalTextSource {
    let text: String
    private let source: String
    private var offsets: [(end: Int, delta: Int)] = []

    init(_ source: String) {
        self.source = source
        guard source.utf8.contains(38) else {
            text = source
            return
        }
        var decoded = ""
        var last = source.startIndex
        let reference = #/&(?:\x23[xX][A-Fa-f0-9]+|\x23[0-9]+|[A-Za-z][A-Za-z0-9]*);?/#.matchingSemantics(
            .unicodeScalar)
        for match in source.matches(of: reference) {
            decoded += source[last..<match.range.lowerBound]
            let spelling = match.output
            // An ambiguous legacy name or a multi-scalar entity stays indivisible.
            // WebKit still sees the original spelling, including any omitted semicolon.
            decoded += Self.character(spelling) ?? "\u{fffc}"
            last = match.range.upperBound
            let end = decoded.utf8.count
            offsets.append((end, source.utf8.distance(from: source.startIndex, to: last) - end))
        }
        decoded += source[last...]
        text = decoded
    }

    private static func character(_ spelling: Substring) -> String? {
        let body = spelling.dropFirst()
        guard body.utf8.count < 64 else { return nil }
        if body.last != ";", body.first != "#", !["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"].contains(body) {
            return nil
        }
        var buffer = cmark_strbuf()
        cmark_strbuf_init(cmark_get_default_mem_allocator(), &buffer, 0)
        defer { cmark_strbuf_free(&buffer) }
        var bytes = Array(body.utf8)
        if bytes.last != 59 { bytes.append(59) }
        let length = bytes.withUnsafeBufferPointer { houdini_unescape_ent(&buffer, $0.baseAddress, Int32($0.count)) }
        guard length == bytes.count else { return nil }
        let value = String(decoding: UnsafeBufferPointer(start: buffer.ptr, count: Int(buffer.size)), as: UTF8.self)
        return value.unicodeScalars.count == 1 ? value : nil
    }

    func original(_ part: Substring) -> String {
        guard !offsets.isEmpty else { return String(part) }
        func index(_ position: String.Index) -> String.Index {
            let offset = text.utf8.distance(from: text.startIndex, to: position)
            var lo = 0
            var hi = offsets.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if offsets[mid].end <= offset { lo = mid + 1 } else { hi = mid }
            }
            let delta = lo == 0 ? 0 : offsets[lo - 1].delta
            return source.utf8.index(source.startIndex, offsetBy: offset + delta)
        }
        return String(source[index(part.startIndex)..<index(part.endIndex)])
    }
}
