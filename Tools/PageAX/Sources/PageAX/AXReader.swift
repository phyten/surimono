import ApplicationServices
import Foundation

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct ContainerHit: Error, CustomStringConvertible {
    let description: String
}

struct AXFailure: Error, CustomStringConvertible {
    let api: String
    let error: AXError

    var description: String {
        let name =
            switch error {
            case .success: "Success"
            case .failure: "Failure"
            case .illegalArgument: "IllegalArgument"
            case .invalidUIElement: "InvalidUIElement"
            case .invalidUIElementObserver: "InvalidUIElementObserver"
            case .cannotComplete: "CannotComplete"
            case .attributeUnsupported: "AttributeUnsupported"
            case .actionUnsupported: "ActionUnsupported"
            case .notificationUnsupported: "NotificationUnsupported"
            case .notImplemented: "NotImplemented"
            case .notificationAlreadyRegistered: "NotificationAlreadyRegistered"
            case .notificationNotRegistered: "NotificationNotRegistered"
            case .apiDisabled: "APIDisabled"
            case .noValue: "NoValue"
            case .parameterizedAttributeUnsupported: "ParameterizedAttributeUnsupported"
            case .notEnoughPrecision: "NotEnoughPrecision"
            @unknown default: "Unknown"
            }
        return "\(api): kAXError\(name) (\(error.rawValue))"
    }
}

func checked(_ result: AXError, _ api: String) throws {
    guard result == .success else { throw AXFailure(api: api, error: result) }
}

private func names(_ element: AXUIElement, parameterized: Bool = false) throws -> [String] {
    var list: CFArray?
    if parameterized {
        try checked(AXUIElementCopyParameterizedAttributeNames(element, &list), "parameterizedAttributeNames")
    } else {
        try checked(AXUIElementCopyAttributeNames(element, &list), "attributeNames")
    }
    return list as? [String] ?? []
}

private func value(_ element: AXUIElement, _ key: String) throws -> CFTypeRef? {
    var value: CFTypeRef?
    try checked(AXUIElementCopyAttributeValue(element, key as CFString, &value), key)
    return value
}

private func axElement(_ object: CFTypeRef?) throws -> AXUIElement {
    guard let object, CFGetTypeID(object) == AXUIElementGetTypeID() else { throw ProbeFailure("Expected AX element") }
    return unsafeDowncast(object, to: AXUIElement.self)
}

private func unpack<T>(_ object: CFTypeRef?, _ type: AXValueType, into result: inout T) throws {
    guard let object, CFGetTypeID(object) == AXValueGetTypeID() else { throw ProbeFailure("Expected AX geometry") }
    let ax = unsafeDowncast(object, to: AXValue.self)
    guard AXValueGetType(ax) == type, withUnsafeMutablePointer(to: &result, { AXValueGetValue(ax, type, $0) })
    else { throw ProbeFailure("Invalid AX geometry") }
}

enum Route: String, CaseIterable {
    case children, hit, focus
}

struct TreeNode: Encodable {
    let path: [Int]
    var role: String?
    var identifier: String?
    var childCount: Int?
    var isExternalHit: Bool?
    var errors: [String] = []
}

struct HitNode: Codable {
    var role: String?
    var identifier: String?
    var frame: CGRect?
    var errors: [String] = []

    func matchesAttributes(of other: HitNode) -> Bool {
        guard errors.isEmpty, other.errors.isEmpty, let role, role == other.role,
            (identifier ?? "") == (other.identifier ?? ""),
            let frame, let otherFrame = other.frame, !frame.isEmpty, !otherFrame.isEmpty
        else { return false }
        return abs(frame.minX - otherFrame.minX) <= 0.001 && abs(frame.minY - otherFrame.minY) <= 0.001
            && abs(frame.width - otherFrame.width) <= 0.001 && abs(frame.height - otherFrame.height) <= 0.001
    }

    func matchesWindow(_ window: HitNode) -> Bool {
        role == kAXWindowRole && identifier?.isEmpty == false && matchesAttributes(of: window)
    }
}

struct HitInspection: Codable {
    let target: HitTarget
    let external: HitNode
    var parent: HitNode?
    var childCount: Int?
    var children: [HitNode] = []
    var pageFrame: CGRect?
    var parentIsPaperWindow: Bool?
    var indexInPaperWindow: Int?
    var paperAncestorDistance: Int?
    var directlyContainsPaper = false

    func exclusionReason(macOSMajor: Int, paperID: String) -> String? {
        guard [26, 27].contains(macOSMajor), target.mouseHitsPaper, target.paperHitIdentifier == target.page,
            target.windowRole == kAXGroupRole, external.role == kAXGroupRole,
            external.identifier?.isEmpty != false, external.errors.isEmpty,
            external.frame?.contains(target.point) == true, pageFrame?.contains(target.point) == true
        else { return nil }

        // The known content group sits exactly between this window and its tagged paper.
        // A root index or an indirect ancestor cannot distinguish it from another control.
        guard let parent, parent.role == kAXWindowRole, parent.identifier?.isEmpty == false,
            parent.errors.isEmpty, parent.frame?.contains(target.point) == true,
            parentIsPaperWindow == true, directlyContainsPaper, paperAncestorDistance == 1
        else { return nil }

        let windowStop: String
        if target.windowIdentifier == paperID {
            windowStop = "window hit the tagged paper; application hit its unnamed window content group"
        } else if target.windowIdentifier?.isEmpty != false, target.windowIsPaperAncestor {
            windowStop =
                "window hit a paper ancestor; application hit the unnamed window content group containing the paper"
        } else {
            return nil
        }
        return "macOS \(macOSMajor): " + windowStop
            + "; native mouse and paper AX reach the page. The hosting hierarchy and paper hit routing match origin/master."
    }
}

final class AXReader {
    let app: AXUIElement
    let token: String
    private var externalHit: AXUIElement?
    private(set) var hitInspection: HitInspection?
    private(set) var returnedFocusWindowCount = 0
    private(set) var optionalErrors: [String: Int] = [:]

    init(app: AXUIElement, token: String) {
        self.app = app
        self.token = token
    }

    private func optional(_ key: String, on element: AXUIElement, names: [String]) throws -> CFTypeRef? {
        guard names.contains(key) else { return nil }
        do {
            return try value(element, key)
        } catch let failure as AXFailure where failure.error == .noValue || failure.error == .attributeUnsupported {
            // AppKit can advertise an attribute even when this particular element has no value for it.
            optionalErrors[failure.description, default: 0] += 1
            return nil
        }
    }

    private func isPage(_ node: AXUIElement, names attributes: [String], generation: Int) throws -> Bool {
        guard let id = try optional(kAXIdentifierAttribute, on: node, names: attributes) as? String,
            id.hasPrefix(token + ".page."),
            try optional(kAXRoleAttribute, on: node, names: attributes) as? String == kAXStaticTextRole,
            let text = try optional(kAXValueAttribute, on: node, names: attributes) as? String
        else { return false }
        return Self.hasMarker(text, generation: generation, token: token)
    }

    private func identifier(_ node: AXUIElement) throws -> String? {
        try optional(kAXIdentifierAttribute, on: node, names: names(node)) as? String
    }

    func isFixturePaper(role: String?, identifier: () throws -> String?) throws -> Bool {
        // Only groups can be our paper. Unrelated controls may advertise AXIdentifier but fail when asked for it.
        guard role == kAXGroupRole else { return false }
        do {
            return try identifier() == token + ".paper"
        } catch let failure as AXFailure where failure.api == kAXIdentifierAttribute && failure.error == .failure {
            optionalErrors[failure.description, default: 0] += 1
            return false
        }
    }

    private func paperPages(_ paper: AXUIElement, stage: Stage) throws -> [AXUIElement] {
        let children = try value(paper, kAXChildrenAttribute) as? [AXUIElement] ?? []
        var matches: [AXUIElement] = []
        for child in children {
            let attrs = try names(child)
            // Reject an unowned leaf before asking it for any text or geometry.
            guard let id = try optional(kAXIdentifierAttribute, on: child, names: attrs) as? String,
                id.hasPrefix(token + ".page."),
                try optional(kAXRoleAttribute, on: child, names: attrs) as? String == kAXStaticTextRole
            else { throw try unexpectedElement(child, names: attrs, route: .children) }
            if try isPage(child, names: attrs, generation: stage.generation) { matches.append(child) }
        }
        return matches
    }

    static func hasMarker(_ text: String, generation: Int, token: String) -> Bool {
        text.filter { !$0.isWhitespace }.contains("世代\(generation)。R01-" + token.prefix(8))
    }

    func page(via route: Route, stage: Stage) throws -> AXUIElement {
        let generation = stage.generation
        switch route {
        case .children:
            let attrs = try names(app)
            var queue = try optional(kAXWindowsAttribute, on: app, names: attrs) as? [AXUIElement] ?? []
            if queue.isEmpty {
                queue = try optional(kAXChildrenAttribute, on: app, names: attrs) as? [AXUIElement] ?? []
            }
            var visited = Set<AXUIElement>()
            var index = 0
            let deadline = ContinuousClock.now + .seconds(5)
            while index < queue.count, index < 4000 {
                guard ContinuousClock.now < deadline else { throw Deadline() }
                let node = queue[index]
                index += 1
                guard visited.insert(node).inserted else { continue }
                do {
                    let attrs = try names(node)
                    let role = try optional(kAXRoleAttribute, on: node, names: attrs) as? String
                    if try isFixturePaper(
                        role: role,
                        identifier: {
                            try optional(kAXIdentifierAttribute, on: node, names: attrs) as? String
                        })
                    {
                        guard let leaf = try paperPages(node, stage: stage).first else {
                            throw ProbeFailure("Paper lacks current fixture page")
                        }
                        return leaf
                    }
                    queue += try optional(kAXChildrenAttribute, on: node, names: attrs) as? [AXUIElement] ?? []
                } catch let failure as AXFailure where failure.error == .invalidUIElement {
                    optionalErrors[failure.description, default: 0] += 1
                }
            }
        case .hit:
            guard let target = stage.hit, target.mouseHitsPaper, target.paperHitIdentifier == target.page else {
                throw ProbeFailure("No point verified by native mouse and paper AX hit tests")
            }
            let point = target.point
            var hit: AXUIElement?
            try checked(AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit), "hitTest")
            if let hit {
                externalHit = hit
                let attrs = try names(hit)
                if try identifier(hit) == target.page, try isPage(hit, names: attrs, generation: generation) {
                    return hit
                }
                let inspection = try inspectHit(hit, target: target, stage: stage)
                if let reason = inspection.exclusionReason(
                    macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, paperID: token + ".paper")
                {
                    throw ContainerHit(description: reason)
                }
                throw try unexpectedElement(hit, names: attrs, route: route)
            }
        case .focus:
            let deadline = ContinuousClock.now + .seconds(5)
            while let object = try optional(kAXFocusedUIElementAttribute, on: app, names: names(app)) {
                var focus = try axElement(object)
                var attrs = try names(focus)
                let role = try optional(kAXRoleAttribute, on: focus, names: attrs) as? String
                if role == kAXWindowRole, try stage.isReturningFocusWindow(role: role, identifier: identifier(focus)) {
                    returnedFocusWindowCount += 1
                    // AppKit can expose the window before its focused child, especially in a background app.
                    // Follow only an actual focus attribute. AXChildren would conceal a lost keyboard focus.
                    if let child = try optional(kAXFocusedUIElementAttribute, on: focus, names: attrs),
                        !CFEqual(child, focus)
                    {
                        focus = try axElement(child)
                        attrs = try names(focus)
                    } else if ContinuousClock.now < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                        continue
                    }
                }
                if try isPage(focus, names: attrs, generation: generation) { return focus }
                if try identifier(focus) == token + ".paper",
                    let page = try paperPages(focus, stage: stage).first
                {
                    return page
                }
                throw try unexpectedElement(focus, names: attrs, route: route)
            }
        }
        throw ProbeFailure("No fixture page for generation " + String(generation))
    }

    private func frame(_ node: AXUIElement, attributes: [String]) throws -> CGRect? {
        guard let position = try optional(kAXPositionAttribute, on: node, names: attributes),
            let dimensions = try optional(kAXSizeAttribute, on: node, names: attributes)
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        try unpack(position, .cgPoint, into: &origin)
        try unpack(dimensions, .cgSize, into: &size)
        // A diagnostic frame from an unsettled AX node must not make the reader's JSON unwritable.
        guard origin.x.isFinite, origin.y.isFinite, size.width.isFinite, size.height.isFinite else {
            throw ProbeFailure("Non-finite AXPosition or AXSize: \(origin), \(size)")
        }
        return CGRect(origin: origin, size: size)
    }

    private func describe(_ node: AXUIElement) -> HitNode {
        var result = HitNode()
        do {
            let attrs = try names(node)
            result.role = try optional(kAXRoleAttribute, on: node, names: attrs) as? String
            result.frame = try frame(node, attributes: attrs)
            result.identifier = try optional(kAXIdentifierAttribute, on: node, names: attrs) as? String
        } catch {
            result.errors.append(String(describing: error))
        }
        return result
    }

    private func inspectHit(_ hit: AXUIElement, target: HitTarget, stage: Stage) throws -> HitInspection {
        var inspection = HitInspection(target: target, external: describe(hit))
        // Preserve partial evidence even if the next AX call fails or the element disappears.
        defer { hitInspection = inspection }
        let attrs = try names(hit)
        let parent = try optional(kAXParentAttribute, on: hit, names: attrs).map { try axElement($0) }
        inspection.parent = parent.map(describe)
        let children = try optional(kAXChildrenAttribute, on: hit, names: attrs) as? [AXUIElement]
        inspection.childCount = children?.count
        inspection.children = (children ?? []).prefix(32).map(describe)

        let leaf = try page(via: .children, stage: stage)
        let paper = try axElement(value(leaf, kAXParentAttribute))
        let taggedPaper = describe(paper)
        guard taggedPaper.role == kAXGroupRole, taggedPaper.identifier == token + ".paper" else { return inspection }
        if let window = try optional(kAXWindowAttribute, on: paper, names: names(paper)) {
            let window = try axElement(window)
            // AXParent and AXWindow can vend different handles for the same window.
            inspection.parentIsPaperWindow = inspection.parent?.matchesWindow(describe(window))
            if let roots = try optional(kAXChildrenAttribute, on: window, names: names(window)) as? [AXUIElement] {
                let matches = roots.indices.filter { inspection.external.matchesAttributes(of: describe(roots[$0])) }
                if matches.count == 1 { inspection.indexInPaperWindow = matches.first }
            }
        }
        inspection.directlyContainsPaper =
            inspection.children.contains { taggedPaper.matchesAttributes(of: $0) }
            || (children ?? []).dropFirst(inspection.children.count).contains {
                taggedPaper.matchesAttributes(of: describe($0))
            }
        guard let page = try paperPages(paper, stage: stage).first(where: { try identifier($0) == target.page })
        else { return inspection }
        inspection.pageFrame = try frame(page, attributes: names(page))
        var ancestor = paper
        for distance in 0..<32 {
            guard let object = try optional(kAXParentAttribute, on: ancestor, names: names(ancestor)) else { break }
            let ancestorParent = try axElement(object)
            // Nested unnamed groups can have identical frames. Match the parent on both paths as well.
            if inspection.external.matchesAttributes(of: describe(ancestor)),
                inspection.parent?.matchesAttributes(of: describe(ancestorParent)) == true
            {
                inspection.paperAncestorDistance = distance
                break
            }
            ancestor = ancestorParent
        }
        return inspection
    }

    private func unexpectedElement(_ node: AXUIElement, names attrs: [String], route: Route) throws -> ProbeFailure {
        let role = try optional(kAXRoleAttribute, on: node, names: attrs) as? String ?? "(absent)"
        let id = try optional(kAXIdentifierAttribute, on: node, names: attrs) as? String ?? "(absent)"
        return ProbeFailure("\(route.rawValue) returned role \(role), identifier \(id)")
    }

    func treeSummary() -> [TreeNode] {
        var result: [TreeNode] = []
        var queue: [(node: AXUIElement, path: [Int])] = [(app, [])]
        let deadline = ContinuousClock.now + .seconds(4)
        var index = 0
        while index < queue.count, ContinuousClock.now < deadline {
            let (node, path) = queue[index]
            index += 1
            var item = TreeNode(path: path)
            if let externalHit, CFEqual(externalHit, node) { item.isExternalHit = true }
            do {
                let attrs = try names(node)
                func read(_ key: String) -> CFTypeRef? {
                    guard attrs.contains(key) else { return nil }
                    do {
                        return try value(node, key)
                    } catch {
                        // An unreadable identifier must not hide the children needed to diagnose a miss.
                        item.errors.append(String(describing: error))
                        return nil
                    }
                }
                item.role = read(kAXRoleAttribute) as? String
                item.identifier = read(kAXIdentifierAttribute) as? String
                let children = read(kAXChildrenAttribute) as? [AXUIElement] ?? []
                item.childCount = children.count
                if path.count < 4 {
                    for (i, child) in children.prefix(128 - queue.count).enumerated() {
                        queue.append((child, path + [i]))
                    }
                }
            } catch {
                item.errors.append(String(describing: error))
            }
            result.append(item)
        }
        return result
    }
}

struct HeldPage {
    let element: AXUIElement
    let original: String
    let attributes: [String]
    let parameters: [String]

    let reference: PageReference
    let paperIdentifier: String
    let generation: Int
    static let requiredParameters = [
        kAXStringForRangeParameterizedAttribute, kAXAttributedStringForRangeParameterizedAttribute,
        kAXBoundsForRangeParameterizedAttribute, kAXLineForIndexParameterizedAttribute,
        kAXRangeForLineParameterizedAttribute,
        kAXRangeForIndexParameterizedAttribute, kAXRangeForPositionParameterizedAttribute,
    ]

    init(_ element: AXUIElement, stage: Stage) throws {
        self.element = element
        generation = stage.generation
        paperIdentifier = stage.token + ".paper"
        attributes = try names(element)
        parameters = try names(element, parameterized: true)
        try Self.requireContract(attributes: attributes, parameters: parameters)
        guard let id = try value(element, kAXIdentifierAttribute) as? String,
            let reference = stage.pages.first(where: { $0.identifier == id }),
            let original = try value(element, kAXValueAttribute) as? String,
            AXReader.hasMarker(original, generation: generation, token: stage.token)
        else { throw ProbeFailure("Page lacks its fixture text or independent PDFKit reference") }
        self.original = original
        self.reference = reference
    }

    static func requireContract(attributes: [String], parameters: [String]) throws {
        let required = [
            kAXIdentifierAttribute, kAXValueAttribute, kAXNumberOfCharactersAttribute,
            kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute,
        ]
        let missing = Set(required).subtracting(attributes).union(Set(Self.requiredParameters).subtracting(parameters))
        guard missing.isEmpty else {
            throw ProbeFailure("Missing AX attributes: " + missing.sorted().joined(separator: ", "))
        }
    }

    static func checkBounds(_ rect: CGRect, against box: CGRect) throws {
        guard !box.isEmpty, !rect.isEmpty,
            [rect.minX - box.minX, rect.maxX - box.maxX, rect.minY - box.minY, rect.maxY - box.maxY]
                .allSatisfy({ abs($0) <= 1 })
        else {
            throw ProbeFailure(
                "Marker AX bounds " + String(describing: rect) + " differ from expected bounds "
                    + String(describing: box))
        }
    }

    private func parameter(_ key: String, _ argument: CFTypeRef) throws -> CFTypeRef? {
        var result: CFTypeRef?
        try checked(AXUIElementCopyParameterizedAttributeValue(element, key as CFString, argument, &result), key)
        return result
    }

    private func checkRange(_ key: String, _ argument: CFTypeRef, _ expected: NSRange) throws {
        var result = CFRange()
        try unpack(parameter(key, argument), .cfRange, into: &result)
        guard result.location == expected.location, result.length == expected.length else {
            throw ProbeFailure("Unexpected " + key + ": " + String(describing: result))
        }
    }

    func verify(current: Bool, detached: Bool = false) throws {
        let text = original as NSString
        guard try value(element, kAXValueAttribute) as? String == original,
            try value(element, kAXNumberOfCharactersAttribute) as? Int == text.length
        else { throw ProbeFailure("Fixture text or UTF-16 character count changed") }
        let start = reference.characterIndex
        let expected = NSRange(location: start, length: 1)
        guard start >= 0, start < text.length, text.substring(with: expected) == "世" else {
            throw ProbeFailure("PDFKit reference does not index the fixture marker")
        }
        var range = CFRange(location: start, length: 1)
        guard let argument = AXValueCreate(.cfRange, &range) else { throw ProbeFailure("Invalid fixture range") }
        guard try parameter(kAXStringForRangeParameterizedAttribute, argument) as? String == "世",
            try (parameter(kAXAttributedStringForRangeParameterizedAttribute, argument) as? NSAttributedString)?.string
                == "世"
        else { throw ProbeFailure("Wrong substring at fixture marker") }
        try checkRange(kAXRangeForIndexParameterizedAttribute, start as NSNumber, expected)
        let line = text.lineRange(for: expected)
        var offset = 0
        var lineNumber = 0
        while offset < line.location {
            offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
            lineNumber += 1
        }
        guard try parameter(kAXLineForIndexParameterizedAttribute, start as NSNumber) as? Int == lineNumber else {
            throw ProbeFailure("Wrong line number at fixture marker")
        }
        try checkRange(kAXRangeForLineParameterizedAttribute, lineNumber as NSNumber, line)
        var rect = CGRect.zero
        try unpack(parameter(kAXBoundsForRangeParameterizedAttribute, argument), .cgRect, into: &rect)
        if !current {
            var full = CFRange(location: 0, length: text.length)
            guard let argument = AXValueCreate(.cfRange, &full),
                try parameter(kAXStringForRangeParameterizedAttribute, argument) as? String == original,
                try (parameter(kAXAttributedStringForRangeParameterizedAttribute, argument) as? NSAttributedString)?
                    .string == original
            else { throw ProbeFailure("Retained page no longer returns its complete original text") }
        }
        if detached && !rect.isEmpty { throw ProbeFailure("Detached marker still has screen bounds") }
        if current {
            let box = try reference.expectedBounds()
            try Self.checkBounds(rect, against: box)
            let parent = try axElement(value(element, kAXParentAttribute))
            guard try value(parent, kAXIdentifierAttribute) as? String == paperIdentifier,
                try value(element, kAXRoleAttribute) as? String == kAXStaticTextRole
            else { throw ProbeFailure("Page is not a static text child of the fixture paper") }
            var origin = CGPoint.zero
            var size = CGSize.zero
            try unpack(value(element, kAXPositionAttribute), .cgPoint, into: &origin)
            try unpack(value(element, kAXSizeAttribute), .cgSize, into: &size)
            guard CGRect(origin: origin, size: size).insetBy(dx: -1, dy: -1).contains(rect) else {
                throw ProbeFailure("Marker is outside its page frame")
            }
            var center = CGPoint(x: box.midX, y: box.midY)
            guard let point = AXValueCreate(.cgPoint, &center) else { throw ProbeFailure("Invalid marker point") }
            try checkRange(kAXRangeForPositionParameterizedAttribute, point, expected)
        }
    }
}
