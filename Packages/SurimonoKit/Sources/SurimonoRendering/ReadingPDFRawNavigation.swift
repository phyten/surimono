import CoreGraphics
import Foundation

/// PDFKit exposes an internal destination as a point and a zoom even for Fit destinations.
/// Quartz resolves indirect objects but preserves the original destination operands and nulls.
struct ReadingPDFRawNavigation: Sendable {
    enum Action: Sendable, Equatable {
        case none
        case other
        case unresolved(String)
        case pdfKitXYZ(pageNumber: Int, point: CGPoint)
        case releasedPage
        case missingPage(mode: String, arguments: [CGFloat?])
        case internalDestination(ReadingPDFNavigationWriter.Destination)
        case namedDestination(ReadingPDFNavigationWriter.Destination)

        var target: ReadingPDFNavigationWriter.Destination? {
            switch self {
            case .internalDestination(let target), .namedDestination(let target): target
            default: nil
            }
        }

        func matchesPDFKitXYZ(_ target: ReadingPDFNavigationWriter.Destination) -> Bool {
            guard case .pdfKitXYZ(let page, let point) = self, page == target.page + 1, target.mode == "XYZ",
                target.arguments[2] == nil, let x = target.arguments[0], let y = target.arguments[1]
            else { return false }
            return ReadingPDFRawNavigation.sameStoredPosition(point.x, x)
                && ReadingPDFRawNavigation.sameStoredPosition(point.y, y)
        }

        var summary: String {
            switch self {
            case .internalDestination(let target), .namedDestination(let target):
                let args = target.arguments.map { $0.map { String(format: "%.8g", Double($0)) } ?? "null" }
                return "\(target.mode)(\(args.joined(separator: ",")))→p\(target.page + 1)"
            case .pdfKitXYZ(let number, let point):
                return "/A/D [/#23\(number) /XYZ \(point.x) \(point.y)] (4 elements)"
            case .none: return "none"
            case .other: return "other"
            case .missingPage(let mode, _): return "\(mode)→missing"
            case .unresolved(let why): return why
            case .releasedPage: return "page=nil"
            }
        }

        var isInternal: Bool {
            switch self {
            case .internalDestination, .namedDestination, .unresolved, .pdfKitXYZ, .missingPage, .releasedPage: true
            case .none, .other: false
            }
        }
    }

    struct Link: Sendable, Equatable {
        let page: Int
        let annotation: Int
        let bounds: CGRect
        let action: Action
    }

    struct Entry: Sendable, Equatable {
        let level: Int
        let title: String?
        let isOpen: Bool
        let action: Action
    }

    let pageCount: Int
    let annotationCounts: [Int]
    // Number of leading PDFKit copies when the complete page consists of two matching blocks.
    let pdfKitCopyCounts: [Int: Int]
    let links: [Link]
    let outline: [Entry]
    let hasValidOutlineCounts: Bool

    private enum Failure: Error {
        case document, page, annotation, nameTree, outline
    }

    @concurrent
    static func read(_ data: Data) async throws -> Self {
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider)
        else {
            throw Failure.document
        }
        return try await capture(pdf)
    }

    static func capture(
        _ pdf: CGPDFDocument, includesOutline: Bool = true, isolation: isolated (any Actor)? = #isolation
    )
        async throws -> Self
    {
        try Task.checkCancellation()
        guard let catalog = pdf.catalog, pdf.isUnlocked else { throw Failure.document }
        // Dictionary, array and string references are unretained and belong to this document.
        defer { withExtendedLifetime(pdf) {} }
        var visited = 0
        func checkpoint(isolation: isolated (any Actor)? = #isolation) async throws {
            try Task.checkCancellation()
            visited += 1
            if visited.isMultiple(of: 128) { await Task.yield() }
        }
        var pages: [CGPDFDictionaryRef: Int] = [:]
        let pageCount = pdf.numberOfPages
        for index in 0..<pageCount {
            try await checkpoint()
            guard let page = pdf.page(at: index + 1)?.dictionary,
                pages.updateValue(index, forKey: page) == nil
            else {
                throw Failure.page
            }
        }

        // Match name-tree keys as byte strings. Decoding PDF text would merge distinct keys.
        var names: [Data: CGPDFObjectRef] = [:]
        var nodes = dictionary(catalog, "Names").flatMap { dictionary($0, "Dests") }.map { [$0] } ?? []
        var seenNames = Set<CGPDFDictionaryRef>()
        while let node = nodes.popLast() {
            try await checkpoint()
            guard seenNames.insert(node).inserted else { throw Failure.nameTree }
            if let pairs = array(node, "Names") {
                let count = CGPDFArrayGetCount(pairs)
                guard count.isMultiple(of: 2) else { throw Failure.nameTree }
                for i in stride(from: 0, to: count, by: 2) {
                    try await checkpoint()
                    var key: CGPDFStringRef?
                    var value: CGPDFObjectRef?
                    guard CGPDFArrayGetString(pairs, i, &key), let key,
                        CGPDFArrayGetObject(pairs, i + 1, &value), let value,
                        names.updateValue(value, forKey: bytes(key)) == nil
                    else { throw Failure.nameTree }
                }
            }
            if let kids = array(node, "Kids") {
                for i in 0..<CGPDFArrayGetCount(kids) {
                    try await checkpoint()
                    var child: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(kids, i, &child), let child else { throw Failure.nameTree }
                    nodes.append(child)
                }
            }
        }
        let legacy = dictionary(catalog, "Dests")
        func action(_ dict: CGPDFDictionaryRef, isLink: Bool) -> Action {
            let target: CGPDFObjectRef
            if let dest = object(dict, "Dest") {
                target = dest
            } else if let a = dictionary(dict, "A") {
                guard let subtype = name(a, "S") else { return .unresolved("missing A/S") }
                guard subtype == "GoTo" else { return .other }
                guard let dest = object(a, "D") else { return .unresolved("missing GoTo/D") }
                target = dest
            } else {
                return object(dict, "A") == nil ? .none : .unresolved("invalid A")
            }
            let type = CGPDFObjectGetType(target)
            let isNamed = type == .name || type == .string
            var resolved: CGPDFObjectRef?
            switch type {
            case .name:
                var key: UnsafePointer<CChar>?
                if CGPDFObjectGetValue(target, .name, &key), let key, let legacy {
                    _ = CGPDFDictionaryGetObject(legacy, key, &resolved)
                }
            case .string:
                var key: CGPDFStringRef?
                if CGPDFObjectGetValue(target, .string, &key), let key { resolved = names[bytes(key)] }
            default: resolved = target
            }
            // Named destinations can hold an explicit array or a dictionary containing /D.
            var wrapper: CGPDFDictionaryRef?
            if isNamed, let candidate = resolved, CGPDFObjectGetValue(candidate, .dictionary, &wrapper), let wrapper {
                resolved = object(wrapper, "D")
            }
            func invalid(_ reason: String) -> Action {
                let source = object(dict, "Dest") == nil ? "/A/D" : "/Dest"
                var raw = Self.describe(target, pages: pages)
                if let resolved, resolved != target {
                    raw += " → " + Self.describe(resolved, pages: pages)
                }
                return .unresolved("\(reason): \(source) \(raw)")
            }
            var dest: CGPDFArrayRef?
            guard let resolved, CGPDFObjectGetValue(resolved, .array, &dest), let dest, CGPDFArrayGetCount(dest) >= 2
            else {
                return invalid("missing destination array or name")
            }
            var targetPage: CGPDFDictionaryRef?
            var kind: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(dest, 1, &kind), let kind else { return invalid("missing view mode") }
            let mode = String(cString: kind)
            if mode == "XYZ", CGPDFArrayGetCount(dest) == 4, isLink, type == .array, object(dict, "Dest") == nil,
                let abbreviated = Self.pdfKitXYZ(in: dest)
            {
                return abbreviated
            }
            guard let count = ReadingPDFNavigationWriter.Destination.argumentCount(for: mode),
                CGPDFArrayGetCount(dest) == 2 + count
            else { return invalid("unknown view or operand count") }
            var arguments: [CGFloat?] = []
            for i in 0..<count {
                var operand: CGPDFObjectRef?
                var number: CGPDFReal = 0
                guard CGPDFArrayGetObject(dest, i + 2, &operand), let operand else {
                    return invalid("missing operand \(i)")
                }
                if CGPDFObjectGetType(operand) == .null && mode != "FitR" {
                    arguments.append(nil)
                } else if CGPDFArrayGetNumber(dest, i + 2, &number), number.isFinite {
                    arguments.append(number)
                } else {
                    return invalid("invalid operand \(i)")
                }
            }
            guard CGPDFArrayGetDictionary(dest, 0, &targetPage), let targetPage, let index = pages[targetPage] else {
                return .missingPage(mode: mode, arguments: arguments)
            }
            let record = ReadingPDFNavigationWriter.Destination(page: index, mode: mode, arguments: arguments)
            return isNamed ? .namedDestination(record) : .internalDestination(record)
        }

        var links: [Link] = []
        var annotationCounts = Array(repeating: 0, count: pageCount)
        var copyCounts: [Int: Int] = [:]
        for p in 0..<pageCount {
            try await checkpoint()
            guard let page = pdf.page(at: p + 1)?.dictionary else { throw Failure.page }
            guard let annots = array(page, "Annots") else { continue }
            let count = CGPDFArrayGetCount(annots)
            annotationCounts[p] = count
            let start = links.count
            for i in 0..<count {
                try await checkpoint()
                var ref: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annots, i, &ref), let ref else { throw Failure.annotation }
                guard name(ref, "Subtype") == "Link" else { continue }
                guard let rect = array(ref, "Rect"), CGPDFArrayGetCount(rect) == 4 else {
                    throw Failure.annotation
                }
                let coords = try (0..<4).map { index in
                    var n: CGPDFReal = 0
                    guard CGPDFArrayGetNumber(rect, index, &n), n.isFinite else { throw Failure.annotation }
                    return n
                }
                let bounds = CGRect(
                    x: coords[0], y: coords[1], width: coords[2] - coords[0], height: coords[3] - coords[1])
                links.append(
                    Link(page: p, annotation: i, bounds: bounds.standardized, action: action(ref, isLink: true)))
            }
            if count > 0, count.isMultiple(of: 2), links.count - start == count,
                case .pdfKitXYZ = links[start].action,
                try Self.hasPDFKitCopies(in: annots, links: links[start...])
            {
                copyCounts[p] = count / 2
            }
        }

        struct Branch {
            var next: CGPDFDictionaryRef?
            let count: Int?
            var visibleChildren = 0
        }
        func branch(_ dict: CGPDFDictionaryRef) -> Branch {
            var count = 0
            let hasCount = CGPDFDictionaryGetInteger(dict, "Count", &count)
            return Branch(next: dictionary(dict, "First"), count: hasCount ? count : nil)
        }
        var outline: [Entry] = []
        var countsValid = true
        var stack = includesOutline ? dictionary(catalog, "Outlines").map { [branch($0)] } ?? [] : []
        var seenOutline = Set<CGPDFDictionaryRef>()
        while let top = stack.last {
            try await checkpoint()
            if let node = top.next {
                guard seenOutline.insert(node).inserted else { throw Failure.outline }
                stack[stack.count - 1].next = dictionary(node, "Next")
                let child = branch(node)
                var title: CGPDFStringRef?
                _ = CGPDFDictionaryGetString(node, "Title", &title)
                outline.append(
                    Entry(
                        level: stack.count, title: title.flatMap { CGPDFStringCopyTextString($0) as String? },
                        isOpen: child.next != nil && (child.count ?? 0) > 0, action: action(node, isLink: false)))
                stack.append(child)
            } else {
                stack.removeLast()
                // /Count is the number visible if this node is opened. Closed children
                // contribute one item to their parent; their own descendants remain hidden.
                if let count = top.count {
                    if count.magnitude != UInt(top.visibleChildren) || (stack.isEmpty && count < 0) {
                        countsValid = false
                    }
                } else if !stack.isEmpty && top.visibleChildren != 0 {
                    countsValid = false
                }
                if !stack.isEmpty {
                    stack[stack.count - 1].visibleChildren +=
                        1 + ((top.count ?? 0) > 0 ? top.visibleChildren : 0)
                }
            }
        }
        return Self(
            pageCount: pageCount, annotationCounts: annotationCounts, pdfKitCopyCounts: copyCounts, links: links,
            outline: outline, hasValidOutlineCounts: countsValid)
    }

    static func sameStoredPosition(_ expected: CGFloat, _ stored: CGFloat) -> Bool {
        abs(expected - stored) <= min(0.001, 4 * expected.ulp)
    }

    // Editing annotations on a native page copy can prepend a block to the source /Annots.
    // Each generated shell must match both the private action and the real /Dest on its counterpart.
    private static func hasPDFKitCopies(in array: CGPDFArrayRef, links: ArraySlice<Link>) throws -> Bool {
        let half = links.count / 2
        for (copy, original) in zip(links.prefix(half), links.suffix(half)) {
            try Task.checkCancellation()
            let a = copy.bounds
            let b = original.bounds
            guard sameStoredPosition(a.minX, b.minX),
                sameStoredPosition(a.maxX, b.maxX),
                sameStoredPosition(a.minY, b.minY),
                sameStoredPosition(a.maxY, b.maxY),
                case .internalDestination(let target) = original.action, copy.action.matchesPDFKitXYZ(target)
            else { return false }
            var shell: CGPDFDictionaryRef?
            var source: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(array, copy.annotation, &shell), let shell,
                CGPDFArrayGetDictionary(array, original.annotation, &source), let source,
                let action = dictionary(source, "A"), CGPDFDictionaryGetCount(action) == 2, name(action, "S") == "GoTo",
                let dest = Self.array(action, "D"), CGPDFArrayGetCount(dest) == 4,
                pdfKitXYZ(in: dest)?.matchesPDFKitXYZ(target) == true
            else { return false }
            // A distinct annotation may have its own appearance, events or metadata. The native
            // shell is a plain printable, borderless link with only a modification date.
            var flags = 0
            var width: CGPDFReal = 0
            guard CGPDFDictionaryGetCount(shell) == 7, object(shell, "M").map(CGPDFObjectGetType) == .string,
                name(shell, "H") == "I", CGPDFDictionaryGetInteger(shell, "F", &flags), flags == 4,
                let border = dictionary(shell, "BS"), CGPDFDictionaryGetCount(border) == 1,
                CGPDFDictionaryGetNumber(border, "W", &width), width == 0,
                let goTo = dictionary(shell, "A"), CGPDFDictionaryGetCount(goTo) == 2
            else { return false }
        }
        return true
    }

    // PDFKit can synthesize [/#23N /XYZ x y] for a live GoTo. Only the owning document can
    // confirm N, and this four-element representation never qualifies as a saved destination.
    private static func pdfKitXYZ(in array: CGPDFArrayRef) -> Action? {
        var mode: UnsafePointer<CChar>?
        var marker: UnsafePointer<CChar>?
        var x: CGPDFReal = 0
        var y: CGPDFReal = 0
        guard CGPDFArrayGetName(array, 1, &mode), let mode, String(cString: mode) == "XYZ",
            CGPDFArrayGetName(array, 0, &marker), let marker,
            CGPDFArrayGetNumber(array, 2, &x), x.isFinite, CGPDFArrayGetNumber(array, 3, &y), y.isFinite
        else { return nil }
        let name = String(cString: marker)
        guard name.hasPrefix("#23"), let number = Int(name.dropFirst(3)), number > 0, name == "#23\(number)"
        else { return nil }
        return .pdfKitXYZ(pageNumber: number, point: CGPoint(x: x, y: y))
    }

    // Describe only the first few operands. A page dictionary can point back to the entire page tree.
    private static func describe(_ object: CGPDFObjectRef, pages: [CGPDFDictionaryRef: Int]) -> String {
        func token(_ value: CGPDFObjectRef) -> String {
            switch CGPDFObjectGetType(value) {
            case .null: return "null"
            case .name:
                var name: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(value, .name, &name), let name else { return "name" }
                return "/" + String(cString: name).prefix(64)
            case .string:
                var string: CGPDFStringRef?
                guard CGPDFObjectGetValue(value, .string, &string), let string, let ptr = CGPDFStringGetBytePtr(string)
                else { return "string" }
                let size = CGPDFStringGetLength(string)
                let hex = (0..<min(size, 32)).map { String(format: "%02X", ptr[$0]) }.joined()
                return "<" + hex + (size > 32 ? "…>" : ">")
            case .dictionary:
                var dict: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(value, .dictionary, &dict), let dict, let page = pages[dict] {
                    return "p\(page + 1)"
                }
                return "dict"
            case .integer:
                var n: CGPDFInteger = 0
                return CGPDFObjectGetValue(value, .integer, &n) ? String(n) : "integer"
            case .real:
                var n: CGPDFReal = 0
                return CGPDFObjectGetValue(value, .real, &n) ? String(Double(n)) : "real"
            case .boolean: return "boolean"
            case .stream: return "stream"
            case .array: return "array"
            @unknown default: return "?"
            }
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array else { return token(object) }
        let size = CGPDFArrayGetCount(array)
        let values = (0..<min(size, 8)).map { i in
            var operand: CGPDFObjectRef?
            return CGPDFArrayGetObject(array, i, &operand) ? operand.map(token) ?? "?" : "?"
        }
        return "[" + values.joined(separator: " ") + (size > 8 ? " …]" : "]") + " (\(size) elements)"
    }

    private static func dictionary(_ parent: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(parent, key, &value) ? value : nil
    }

    private static func object(_ parent: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        // A null dictionary value is equivalent to an absent key. Array operands retain their nulls.
        guard CGPDFDictionaryGetObject(parent, key, &value), let value, CGPDFObjectGetType(value) != .null else {
            return nil
        }
        return value
    }

    private static func array(_ parent: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var value: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(parent, key, &value) ? value : nil
    }

    private static func name(_ parent: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(parent, key, &value), let value else { return nil }
        return String(cString: value)
    }

    private static func bytes(_ value: CGPDFStringRef) -> Data {
        guard let pointer = CGPDFStringGetBytePtr(value) else { return Data() }
        return Data(bytes: pointer, count: CGPDFStringGetLength(value))
    }
}
