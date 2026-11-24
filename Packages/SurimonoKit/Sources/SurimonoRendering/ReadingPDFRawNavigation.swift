import CoreGraphics
import Foundation

/// PDFKit exposes an internal destination as a point and a zoom even for Fit destinations.
/// Quartz resolves indirect objects but preserves the original destination operands and nulls.
struct ReadingPDFRawNavigation: Sendable {
    enum Action: Sendable, Equatable {
        case none
        case other
        case unresolved(String)
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

        var summary: String {
            switch self {
            case .internalDestination(let target), .namedDestination(let target):
                let args = target.arguments.map { $0.map { String(format: "%.8g", Double($0)) } ?? "null" }
                return "\(target.mode)(\(args.joined(separator: ",")))→p\(target.page + 1)"
            case .none: return "none"
            case .other: return "other"
            case .missingPage(let mode, _): return "\(mode)→missing"
            case .unresolved(let why): return why
            case .releasedPage: return "page=nil"
            }
        }

        var isInternal: Bool {
            switch self {
            case .internalDestination, .namedDestination, .unresolved, .missingPage, .releasedPage: true
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

    static func capture(_ pdf: CGPDFDocument, isolation: isolated (any Actor)? = #isolation)
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
        func action(_ dict: CGPDFDictionaryRef) -> Action {
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
            var resolved: CGPDFObjectRef?
            switch CGPDFObjectGetType(target) {
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
            if let candidate = resolved, CGPDFObjectGetValue(candidate, .dictionary, &wrapper),
                let wrapper
            {
                resolved = object(wrapper, "D")
            }
            var dest: CGPDFArrayRef?
            guard let resolved, CGPDFObjectGetValue(resolved, .array, &dest), let dest, CGPDFArrayGetCount(dest) >= 2
            else {
                return .unresolved("missing destination array or name")
            }
            var targetPage: CGPDFDictionaryRef?
            var kind: UnsafePointer<CChar>?
            guard CGPDFArrayGetName(dest, 1, &kind), let kind else { return .unresolved("missing view mode") }
            let mode = String(cString: kind)
            guard let count = ReadingPDFNavigationWriter.Destination.argumentCount(for: mode),
                CGPDFArrayGetCount(dest) == 2 + count
            else { return .unresolved("unknown view or operand count") }
            var arguments: [CGFloat?] = []
            for i in 0..<count {
                var operand: CGPDFObjectRef?
                var number: CGPDFReal = 0
                guard CGPDFArrayGetObject(dest, i + 2, &operand), let operand else {
                    return .unresolved("missing operand \(i)")
                }
                if CGPDFObjectGetType(operand) == .null && mode != "FitR" {
                    arguments.append(nil)
                } else if CGPDFArrayGetNumber(dest, i + 2, &number), number.isFinite {
                    arguments.append(number)
                } else {
                    return .unresolved("invalid operand \(i)")
                }
            }
            guard CGPDFArrayGetDictionary(dest, 0, &targetPage), let targetPage, let index = pages[targetPage] else {
                return .missingPage(mode: mode, arguments: arguments)
            }
            let record = ReadingPDFNavigationWriter.Destination(page: index, mode: mode, arguments: arguments)
            switch CGPDFObjectGetType(target) {
            case .name, .string: return .namedDestination(record)
            default: return .internalDestination(record)
            }
        }

        var links: [Link] = []
        for p in 0..<pageCount {
            try await checkpoint()
            guard let page = pdf.page(at: p + 1)?.dictionary else { throw Failure.page }
            guard let annots = array(page, "Annots") else { continue }
            for i in 0..<CGPDFArrayGetCount(annots) {
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
                links.append(Link(page: p, annotation: i, bounds: bounds.standardized, action: action(ref)))
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
        var stack = dictionary(catalog, "Outlines").map { [branch($0)] } ?? []
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
                        isOpen: child.next != nil && (child.count ?? 0) > 0, action: action(node)))
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
            pageCount: pageCount, links: links, outline: outline, hasValidOutlineCounts: countsValid)
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
