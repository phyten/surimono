import Foundation
import PDFKit

/// Repairs navigation in an unencrypted PDF with classic cross-reference tables.
/// An incremental update leaves page content, fonts, images, annotation appearances and metadata untouched.
enum ReadingPDFNavigationWriter {
    struct Destination: Equatable, Sendable {
        let page: Int
        let mode: String
        let arguments: [CGFloat?]

        init(page: Int, mode: String, arguments: [CGFloat?]) {
            self.page = page
            self.mode = mode
            self.arguments = arguments
        }

        init(page: Int, point: CGPoint, zoom: CGFloat) {
            self.init(
                page: page, mode: "XYZ",
                arguments: [point.x, point.y, zoom].map { $0 == kPDFDestinationUnspecifiedValue ? nil : $0 })
        }

        /// Translates only positions in page space. Null coordinates and the XYZ zoom retain their PDF meaning.
        func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
            var moved = arguments
            func shift(_ index: Int, by offset: CGFloat) {
                if let value = arguments[index] { moved[index] = value + offset }
            }
            switch mode {
            case "XYZ":
                shift(0, by: dx)
                shift(1, by: dy)
            case "FitH", "FitBH":
                shift(0, by: dy)
            case "FitV", "FitBV":
                shift(0, by: dx)
            case "FitR":
                shift(0, by: dx)
                shift(1, by: dy)
                shift(2, by: dx)
                shift(3, by: dy)
            default: break  // Fit and FitB have no coordinates.
            }
            return Self(page: page, mode: mode, arguments: moved)
        }

        static func argumentCount(for mode: String) -> Int? {
            switch mode {
            case "Fit", "FitB": 0
            case "FitH", "FitV", "FitBH", "FitBV": 1
            case "XYZ": 3
            case "FitR": 4
            default: nil
            }
        }
    }

    struct Link: Equatable, Sendable {
        let page: Int
        let annotation: Int
        let destination: Destination
    }

    struct NewLink: Sendable {
        let page: Int
        let bounds: CGRect
        let destination: Destination
        // Index in the original annotation array. Nil appends after any annotations copied from a PDF slice.
        var beforeAnnotation: Int? = nil
    }

    struct Bookmark: Equatable, Sendable {
        let title: String
        let destination: Destination?
        let isOpen: Bool
        let children: [Bookmark]
    }

    /// The flow compositor hands off the closed Quartz PDF before opening it for display.
    @concurrent
    static func adding(_ links: [NewLink], to data: Data) async throws -> Data {
        try repair(data, links: [], bookmarks: nil, adding: links)
    }

    /// Pages and annotations are zero-based. A nil outline leaves the catalog's original outline intact.
    static func repair(
        _ data: Data, links: [Link], bookmarks: [Bookmark]?, removingAnnotations: [Int: Set<Int>] = [:],
        adding: [NewLink] = []
    )
        throws -> Data
    {
        try Task.checkCancellation()
        guard !links.isEmpty || bookmarks != nil || !removingAnnotations.isEmpty || !adding.isEmpty else { return data }
        return try data.withUnsafeBytes { buffer in
            var file = try File(bytes: buffer.bindMemory(to: UInt8.self))
            return try file.repair(
                data, links: links, bookmarks: bookmarks, removingAnnotations: removingAnnotations, adding: adding)
        }
    }

    struct AnnotationLocation {
        let page: Int
        let bounds: CGRect
    }

    /// Fill missing indirect /Dest objects before PDFKit serializes the page boxes and
    /// loses their identities. Every annotation dictionary and every defined target stays intact.
    static func restoringMissingDestinations(
        in data: Data, locate: ([Ref: [AnnotationLocation]]) throws -> [Ref: Destination]
    ) throws -> Data? {
        return try data.withUnsafeBytes { buffer in
            var file = try File(bytes: buffer.bindMemory(to: UInt8.self))
            guard file.offsets.values.contains(0) else { return nil }
            try file.readPageTree()
            var marksByDestination: [Ref: [AnnotationLocation]] = [:]
            for (page, ref) in file.pages.enumerated() {
                try Task.checkCancellation()
                let dictionary = try file.dictionary(ref)
                guard dictionary.fields["Annots"] != nil else { continue }
                for annotation in try file.references("Annots", in: dictionary) {
                    try Task.checkCancellation()
                    let dict = try file.dictionary(annotation)
                    guard var dest = try? file.field("Dest", of: dict), let id = try? dest.ref(),
                        file.offsets[id] != nil
                    else { continue }
                    var subtype = try file.field("Subtype", of: dict)
                    guard try subtype.name() == "Link" else { continue }
                    var rect = try file.field("Rect", of: dict)
                    marksByDestination[id, default: []].append(.init(page: page, bounds: try rect.rectangle()))
                }
            }
            for (id, target) in try locate(marksByDestination) where file.offsets[id] == 0 {
                try Task.checkCancellation()
                file.revisions[id] = Data(try file.operand(target).utf8)
            }
            guard !file.revisions.isEmpty else { return nil }
            return try file.repair(data, links: [], bookmarks: nil, removingAnnotations: [:], adding: [])
        }
    }

    private enum Failure: LocalizedError {
        case unsupported
        case crossReferenceStream
        case encryptedOrHybrid
        case missingAnnotation(page: Int, index: Int)

        var errorDescription: String? {
            switch self {
            case .unsupported: "Unsupported PDF structure for navigation repair."
            case .crossReferenceStream: "Cannot repair navigation in a PDF with a cross-reference stream."
            case .encryptedOrHybrid: "Cannot repair navigation in an encrypted or hybrid-reference PDF."
            case .missingAnnotation(let page, let index): "Cannot find link annotation \(index) on page \(page)."
            }
        }
    }

    struct Ref: Hashable {
        let id: Int
        let generation: Int
        var operand: String { "\(id) \(generation) R" }
    }

    private struct DictionaryObject {
        let range: Range<Int>
        let fields: [String: (key: Int, value: Range<Int>)]

        func editing(
            _ keys: Set<String>, adding entries: String, inherited: [String: Range<Int>] = [:],
            in bytes: UnsafeBufferPointer<UInt8>
        )
            -> Data
        {
            var data = Data()
            var start = range.lowerBound
            for field in keys.compactMap({ fields[$0] }).sorted(by: { $0.key < $1.key }) {
                data.append(contentsOf: bytes[start..<field.key])
                start = field.value.upperBound
            }
            data.append(contentsOf: bytes[start..<(range.upperBound - 2)])
            for (name, value) in inherited.sorted(by: { $0.key < $1.key }) {
                data.append(contentsOf: "\n/\(name) ".utf8)
                data.append(contentsOf: bytes[value])
            }
            data.append(contentsOf: "\n\(entries)\n>>".utf8)
            return data
        }
    }

    // Only the trailer, page tree, annotation arrays and link dictionaries are opened at xref offsets.
    // A string or stream in page content cannot be mistaken for a catalog key or an object header.
    private struct Cursor {
        let bytes: UnsafeBufferPointer<UInt8>
        var i: Int

        static func white(_ c: UInt8) -> Bool {
            c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32
        }
        static func delimiter(_ c: UInt8) -> Bool {
            white(c) || [37, 40, 41, 47, 60, 62, 91, 93, 123, 125].contains(c)
        }
        var byte: UInt8? { i < bytes.count ? bytes[i] : nil }

        mutating func spaces() {
            while let c = byte {
                if Self.white(c) {
                    i += 1
                } else if c == 37 {
                    while let b = byte, b != 10, b != 13 { i += 1 }
                } else {
                    break
                }
            }
        }

        mutating func take(_ c: UInt8) -> Bool {
            guard byte == c else { return false }
            i += 1
            return true
        }

        mutating func word() throws -> String {
            spaces()
            let start = i
            while let c = byte, !Self.delimiter(c) { i += 1 }
            guard start < i, i - start <= 64 else { throw Failure.unsupported }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        mutating func integer() throws -> Int {
            let token = try word()
            guard token.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(token) else {
                throw Failure.unsupported
            }
            return n
        }

        mutating func ref() throws -> Ref {
            let id = try integer()
            let generation = try integer()
            guard id > 0, generation < 65535, try word() == "R" else { throw Failure.unsupported }
            return Ref(id: id, generation: generation)
        }

        mutating func name() throws -> String {
            spaces()
            guard take(47) else { throw Failure.unsupported }
            var name: [UInt8] = []
            while let c = byte, !Self.delimiter(c) {
                i += 1
                if c == 35 {
                    guard i + 2 <= bytes.count,
                        let value = UInt8(String(decoding: bytes[i..<i + 2], as: UTF8.self), radix: 16)
                    else { throw Failure.unsupported }
                    name.append(value)
                    i += 2
                } else {
                    name.append(c)
                }
                guard name.count <= 1024 else { throw Failure.unsupported }
            }
            return String(decoding: name, as: UTF8.self)
        }

        mutating func dict(depth: Int = 0) throws -> DictionaryObject {
            spaces()
            let start = i
            guard depth <= 64, take(60), take(60) else { throw Failure.unsupported }
            var fields: [String: (key: Int, value: Range<Int>)] = [:]
            while true {
                spaces()
                if take(62) {
                    guard take(62) else { throw Failure.unsupported }
                    return DictionaryObject(range: start..<i, fields: fields)
                }
                let key = i
                let field = try name()
                spaces()
                let begin = i
                try skipValue(depth: depth + 1)
                guard fields[field] == nil else { throw Failure.unsupported }
                fields[field] = (key, begin..<i)
            }
        }

        mutating func skipValue(depth: Int) throws {
            spaces()
            guard depth <= 64, let c = byte else { throw Failure.unsupported }
            switch c {
            case 47: _ = try name()
            case 60 where i + 1 < bytes.count && bytes[i + 1] == 60:
                _ = try dict(depth: depth)
            case 60:
                i += 1
                while let b = byte, b != 62 { i += 1 }
                guard take(62) else { throw Failure.unsupported }
            case 91:
                i += 1
                spaces()
                while !take(93) {
                    try skipValue(depth: depth + 1)
                    spaces()
                }
            case 40:
                i += 1
                var nested = 1
                while nested > 0 {
                    guard let b = byte else { throw Failure.unsupported }
                    i += 1
                    switch b {
                    case 92:
                        guard byte != nil else { throw Failure.unsupported }
                        i += 1
                    case 40: nested += 1
                    case 41: nested -= 1
                    default: break
                    }
                }
            default:
                var look = self
                if (try? look.ref()) != nil {
                    self = look
                    return
                }
                let token = try word()
                guard ["true", "false", "null"].contains(token) || Double(token)?.isFinite == true else {
                    throw Failure.unsupported
                }
            }
        }

        mutating func rectangle() throws -> CGRect {
            guard take(91) else { throw Failure.unsupported }
            func coordinate(_ token: String) throws -> CGFloat {
                guard let n = Double(token), n.isFinite else { throw Failure.unsupported }
                return CGFloat(n)
            }
            let x = try coordinate(word())
            let y = try coordinate(word())
            let right = try coordinate(word())
            let top = try coordinate(word())
            spaces()
            guard take(93), right > x, top > y else { throw Failure.unsupported }
            return CGRect(x: x, y: y, width: right - x, height: top - y)
        }

        mutating func references() throws -> [Ref] {
            spaces()
            guard take(91) else { throw Failure.unsupported }
            var refs: [Ref] = []
            spaces()
            while !take(93) {
                if refs.count.isMultiple(of: 128) { try Task.checkCancellation() }
                refs.append(try ref())
                spaces()
            }
            return refs
        }
    }

    private struct File {
        let bytes: UnsafeBufferPointer<UInt8>
        let previous: Int
        let trailer: DictionaryObject
        let inherited: [String: Range<Int>]
        let root: Ref
        let offsets: [Ref: Int]
        var next: Int
        var revisions: [Ref: Data] = [:]
        var pages: [Ref] = []

        init(bytes: UnsafeBufferPointer<UInt8>) throws {
            self.bytes = bytes
            // Read startxref from the end, never by searching backwards through compressed data.
            var end = bytes.count
            func trim() { while end > 0, Cursor.white(bytes[end - 1]) { end -= 1 } }
            func suffix(_ literal: String) throws {
                let n = literal.utf8.count
                guard end >= n, bytes[end - n..<end].elementsEqual(literal.utf8) else {
                    throw Failure.unsupported
                }
                end -= n
            }
            trim()
            try suffix("%%EOF")
            trim()
            let digits = end
            while end > 0, (48...57).contains(bytes[end - 1]) { end -= 1 }
            guard digits > end, digits - end < 16,
                let offset = Int(String(decoding: bytes[end..<digits], as: UTF8.self)), offset < end
            else { throw Failure.unsupported }
            trim()
            try suffix("startxref")
            previous = offset
            var current = offset
            var visited = Set<Int>()
            var seen = Set<Int>()
            var found: [Ref: Int] = [:]
            var latest: DictionaryObject?
            var effective: [String: Range<Int>] = [:]
            while true {
                guard visited.count < 64, visited.insert(current).inserted else { throw Failure.unsupported }
                let section = try Self.readSection(bytes, at: current, found: &found, seen: &seen)
                guard section.fields["Encrypt"] == nil, section.fields["XRefStm"] == nil else {
                    throw Failure.encryptedOrHybrid
                }
                if latest == nil { latest = section }
                for key in ["Root", "Info", "ID"] where effective[key] == nil {
                    effective[key] = section.fields[key]?.value
                }
                guard let earlier = section.fields["Prev"]?.value else { break }
                var cursor = Cursor(bytes: bytes, i: earlier.lowerBound)
                let previous = try cursor.integer()
                guard cursor.i == earlier.upperBound, previous < current else { throw Failure.unsupported }
                current = previous
            }
            guard let latest, let rootValue = effective["Root"], let sizeValue = latest.fields["Size"]?.value else {
                throw Failure.unsupported
            }
            offsets = found
            trailer = latest
            inherited = effective.filter { latest.fields[$0.key] == nil }
            var rootCursor = Cursor(bytes: bytes, i: rootValue.lowerBound)
            root = try rootCursor.ref()
            var sizeCursor = Cursor(bytes: bytes, i: sizeValue.lowerBound)
            next = try sizeCursor.integer()
            guard sizeCursor.i == sizeValue.upperBound, next > (seen.max() ?? 0), next < Int(Int32.max) else {
                throw Failure.unsupported
            }
        }

        // Walk newest first. A free entry in a later revision masks every older generation.
        private static func readSection(
            _ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, found: inout [Ref: Int], seen: inout Set<Int>
        ) throws -> DictionaryObject {
            var c = Cursor(bytes: bytes, i: offset)
            guard try c.word() == "xref" else { throw Failure.crossReferenceStream }
            var inSection = Set<Int>()
            while true {
                var look = c
                if try look.word() == "trailer" {
                    c = look
                    break
                }
                let start = try c.integer()
                let count = try c.integer()
                guard count <= bytes.count / 5, start <= Int.max - count else { throw Failure.unsupported }
                for id in start..<start + count {
                    if id.isMultiple(of: 128) { try Task.checkCancellation() }
                    let pos = try c.integer()
                    let gen = try c.integer()
                    let flag = try c.word()
                    guard inSection.insert(id).inserted, gen <= 65535 else { throw Failure.unsupported }
                    let newest = seen.insert(id).inserted
                    switch flag {
                    case "n":
                        guard pos < offset, id > 0, gen < 65535 else { throw Failure.unsupported }
                        if newest { found[Ref(id: id, generation: gen)] = pos }
                    case "f": break
                    default: throw Failure.unsupported
                    }
                }
            }
            return try c.dict()
        }

        func object(_ ref: Ref) throws -> Cursor {
            guard let pos = offsets[ref] else { throw Failure.unsupported }
            var c = Cursor(bytes: bytes, i: pos)
            guard try c.integer() == ref.id, try c.integer() == ref.generation, try c.word() == "obj"
            else { throw Failure.unsupported }
            c.spaces()
            return c
        }

        func dictionary(_ ref: Ref) throws -> DictionaryObject {
            var c = try object(ref)
            let dict = try c.dict()
            guard try c.word() == "endobj" else { throw Failure.unsupported }
            return dict
        }

        func field(_ key: String, of dict: DictionaryObject) throws -> Cursor {
            guard let start = dict.fields[key]?.value.lowerBound else { throw Failure.unsupported }
            return Cursor(bytes: bytes, i: start)
        }

        func references(_ key: String, in dict: DictionaryObject) throws -> [Ref] {
            var c = try field(key, of: dict)
            if c.byte == 91 { return try c.references() }
            var indirect = try object(c.ref())
            let refs = try indirect.references()
            guard try indirect.word() == "endobj" else { throw Failure.unsupported }
            return refs
        }

        mutating func collectPages(_ ref: Ref, visited: inout Set<Ref>, depth: Int) throws {
            try Task.checkCancellation()
            guard depth <= 64, visited.insert(ref).inserted else { throw Failure.unsupported }
            let dict = try dictionary(ref)
            var type = try field("Type", of: dict)
            switch try type.name() {
            case "Pages":
                for child in try references("Kids", in: dict) {
                    try collectPages(child, visited: &visited, depth: depth + 1)
                }
            case "Page": pages.append(ref)
            default: throw Failure.unsupported
            }
        }

        mutating func readPageTree() throws {
            let catalog = try dictionary(root)
            var type = try field("Type", of: catalog)
            guard try type.name() == "Catalog" else { throw Failure.unsupported }
            var tree = try field("Pages", of: catalog)
            var visited = Set<Ref>()
            try collectPages(tree.ref(), visited: &visited, depth: 0)
        }

        func operand(_ destination: Destination) throws -> String {
            guard pages.indices.contains(destination.page),
                Destination.argumentCount(for: destination.mode) == destination.arguments.count,
                destination.mode != "FitR" || !destination.arguments.contains(nil)
            else { throw Failure.unsupported }
            let operands = try destination.arguments.map { value in
                guard let value else { return "null" }
                return try decimal(value)
            }
            return "[" + ([pages[destination.page].operand, "/" + destination.mode] + operands).joined(separator: " ")
                + "]"
        }

        // PDF real numbers have no exponent. Expand Swift's round-trippable decimal digits.
        private func decimal(_ value: CGFloat) throws -> String {
            guard value.isFinite else { throw Failure.unsupported }
            let parts = String(Double(value)).split(separator: "e")
            guard parts.count == 2 else { return String(parts[0]) }
            let sign = value.sign == .minus ? "-" : ""
            let mantissa = parts[0].dropFirst(sign.count).split(separator: ".")
            guard let exponent = Int(parts[1]) else { throw Failure.unsupported }
            let digits = mantissa.joined()
            let places = mantissa[0].count + exponent
            if places <= 0 {
                return sign + "0." + String(repeating: "0", count: -places) + digits
            }
            if places >= digits.count {
                return sign + digits + String(repeating: "0", count: places - digits.count)
            }
            let split = digits.index(digits.startIndex, offsetBy: places)
            return sign + digits[..<split] + "." + digits[split...]
        }

        mutating func allocate() throws -> Ref {
            try Task.checkCancellation()
            guard next < Int(Int32.max) else { throw Failure.unsupported }
            defer { next += 1 }
            return Ref(id: next, generation: 0)
        }

        mutating func buildOutline(_ items: [Bookmark], parent: Ref, isOpen: Bool, depth: Int) throws
            -> (fields: String, visibleChildren: Int)
        {
            guard depth <= 64 else { throw Failure.unsupported }
            let refs = try items.map { _ in try allocate() }
            var visibleChildren = items.count
            for (index, item) in items.enumerated() {
                let ref = refs[index]
                var title = "<FEFF"
                for unit in item.title.utf16 { title += String(format: "%04X", unit) }
                title += ">"
                var entries = "/Title \(title) /Parent \(parent.operand)"
                if let target = item.destination { entries += " /Dest \(try operand(target))" }
                if index > 0 { entries += " /Prev \(refs[index-1].operand)" }
                if index + 1 < refs.count { entries += " /Next \(refs[index+1].operand)" }
                if !item.children.isEmpty {
                    let branch = try buildOutline(item.children, parent: ref, isOpen: item.isOpen, depth: depth + 1)
                    entries += " " + branch.fields
                    if item.isOpen { visibleChildren += branch.visibleChildren }
                }
                revisions[ref] = Data("<< \(entries) >>".utf8)
            }
            guard let first = refs.first, let last = refs.last else { throw Failure.unsupported }
            let count = isOpen ? visibleChildren : -visibleChildren
            return ("/First \(first.operand) /Last \(last.operand) /Count \(count)", visibleChildren)
        }

        mutating func repair(
            _ base: Data, links: [Link], bookmarks: [Bookmark]?, removingAnnotations: [Int: Set<Int>], adding: [NewLink]
        )
            throws -> Data
        {
            if pages.isEmpty { try readPageTree() }
            let catalog = try dictionary(root)
            for (source, group) in Dictionary(grouping: links, by: \.page) {
                guard pages.indices.contains(source) else { throw Failure.unsupported }
                let annotations = try references("Annots", in: dictionary(pages[source]))
                for link in group {
                    try Task.checkCancellation()
                    guard annotations.indices.contains(link.annotation) else {
                        throw Failure.missingAnnotation(page: source + 1, index: link.annotation)
                    }
                    let ref = annotations[link.annotation]
                    let dict = try dictionary(ref)
                    var subtype = try field("Subtype", of: dict)
                    guard try subtype.name() == "Link", revisions[ref] == nil else {
                        throw Failure.unsupported
                    }
                    revisions[ref] = dict.editing(
                        ["A", "Dest"], adding: "/Dest \(try operand(link.destination))", in: bytes)
                }
            }
            let additions = Dictionary(grouping: adding, by: \.page)
            for source in Set(removingAnnotations.keys).union(additions.keys) {
                let removed = removingAnnotations[source] ?? []
                try Task.checkCancellation()
                guard pages.indices.contains(source) else { throw Failure.unsupported }
                let ref = pages[source]
                let dict = try dictionary(ref)
                let annotations = dict.fields["Annots"] == nil ? [] : try references("Annots", in: dict)
                guard removed.allSatisfy(annotations.indices.contains) else { throw Failure.unsupported }
                var inserted: [Int: [String]] = [:]
                for link in additions[source] ?? [] {
                    try Task.checkCancellation()
                    let ref = try allocate()
                    let r = link.bounds
                    let rect = try [r.minX, r.minY, r.maxX, r.maxY].map(decimal).joined(separator: " ")
                    revisions[ref] = Data(
                        "<< /Type /Annot /Subtype /Link /Rect [\(rect)] /Border [0 0 0] /Dest \(try operand(link.destination)) >>"
                            .utf8)
                    let index = link.beforeAnnotation ?? annotations.count
                    guard (0...annotations.count).contains(index) else { throw Failure.unsupported }
                    inserted[index, default: []].append(ref.operand)
                }
                var kept: [String] = []
                for (index, annotation) in annotations.enumerated() {
                    if let links = inserted[index] { kept.append(contentsOf: links) }
                    if !removed.contains(index) { kept.append(annotation.operand) }
                }
                if let last = inserted[annotations.count] { kept.append(contentsOf: last) }
                revisions[ref] = dict.editing(["Annots"], adding: "/Annots [\(kept.joined(separator: " "))]", in: bytes)
            }
            if let bookmarks {
                var entry = ""
                if !bookmarks.isEmpty {
                    let outline = try allocate()
                    let children = try buildOutline(bookmarks, parent: outline, isOpen: true, depth: 0)
                    revisions[outline] = Data("<< /Type /Outlines \(children.fields) >>".utf8)
                    entry = "/Outlines \(outline.operand)"
                }
                revisions[root] = catalog.editing(["Outlines"], adding: entry, in: bytes)
            }
            var result = base
            result.append(10)
            var entries: [(Ref, Int)] = []
            for ref in revisions.keys.sorted(by: { $0.id < $1.id }) {
                try Task.checkCancellation()
                entries.append((ref, result.count))
                result.append(contentsOf: "\(ref.id) \(ref.generation) obj\n".utf8)
                result.append(revisions[ref]!)
                result.append(contentsOf: "\nendobj\n".utf8)
            }
            let xref = result.count
            guard xref < 10_000_000_000 else { throw Failure.unsupported }
            result.append(contentsOf: "xref\n".utf8)
            for (ref, offset) in entries {
                try Task.checkCancellation()
                result.append(contentsOf: "\(ref.id) 1\n".utf8)
                result.append(
                    contentsOf: String(format: "%010lld %05d n \n", Int64(offset), ref.generation).utf8)
            }
            result.append(contentsOf: "trailer\n".utf8)
            result.append(
                trailer.editing(
                    ["Size", "Prev"], adding: "/Size \(next) /Prev \(previous)", inherited: inherited, in: bytes))
            result.append(contentsOf: "\nstartxref\n\(xref)\n%%EOF\n".utf8)
            return result
        }
    }
}
