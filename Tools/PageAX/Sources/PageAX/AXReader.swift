import ApplicationServices
import Foundation

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
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
    var errors: [String] = []
}

final class AXReader {
    let app: AXUIElement
    let token: String
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
        guard try optional(kAXRoleAttribute, on: node, names: attributes) as? String == kAXStaticTextRole,
            let text = try optional(kAXValueAttribute, on: node, names: attributes) as? String,
            Self.hasMarker(text, generation: generation, token: token)
        else { return false }
        if let object = try optional(kAXParentAttribute, on: node, names: attributes) {
            let parent = try axElement(object)
            if try optional(kAXRoleAttribute, on: parent, names: names(parent)) as? String == kAXGroupRole {
                return true
            }
        }
        let id = try optional(kAXIdentifierAttribute, on: node, names: attributes) as? String
        return id?.hasPrefix(token + ".page.") == true
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
                    if try isPage(node, names: attrs, generation: generation) { return node }
                    queue += try optional(kAXChildrenAttribute, on: node, names: attrs) as? [AXUIElement] ?? []
                } catch let failure as AXFailure where failure.error == .invalidUIElement {
                    optionalErrors[failure.description, default: 0] += 1
                }
            }
        case .hit:
            guard let point = stage.hitPoint else { throw ProbeFailure("No visible point on the paper") }
            var hit: AXUIElement?
            try checked(AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit), "hitTest")
            if let hit {
                let attrs = try names(hit)
                if try isPage(hit, names: attrs, generation: generation) { return hit }
                throw try unexpectedElement(hit, names: attrs, route: route)
            }
        case .focus:
            if let object = try optional(kAXFocusedUIElementAttribute, on: app, names: names(app)) {
                let focus = try axElement(object)
                let attrs = try names(focus)
                if try isPage(focus, names: attrs, generation: generation) { return focus }
                // The paper itself is the responder. Only its immediate page leaves belong to this route.
                if try optional(kAXRoleAttribute, on: focus, names: attrs) as? String == kAXGroupRole {
                    let children = try optional(kAXChildrenAttribute, on: focus, names: attrs) as? [AXUIElement] ?? []
                    for child in children where try isPage(child, names: names(child), generation: generation) {
                        return child
                    }
                }
                throw try unexpectedElement(focus, names: attrs, route: route)
            }
        }
        throw ProbeFailure("No fixture page for generation " + String(generation))
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

    init(_ element: AXUIElement, token: String) throws {
        self.element = element
        attributes = try names(element)
        parameters = try names(element, parameterized: true)
        guard attributes.contains(kAXValueAttribute), let original = try value(element, kAXValueAttribute) as? String,
            AXReader.hasMarker(original, generation: 0, token: token)
        else { throw ProbeFailure("Initial page has no generation-zero marker") }
        self.original = original
    }

    func verify() throws {
        let attributes = try names(element)
        let parameters = try names(element, parameterized: true)
        guard attributes.contains(kAXValueAttribute), try value(element, kAXValueAttribute) as? String == original
        else {
            throw ProbeFailure("Old AXValue changed")
        }
        for key in [
            kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXNumberOfCharactersAttribute,
            kAXParentAttribute, kAXChildrenAttribute,
        ] where attributes.contains(key) {
            do { _ = try value(element, key) } catch let error as AXFailure
                where (error.error == .noValue || error.error == .attributeUnsupported)
                && [kAXParentAttribute, kAXChildrenAttribute].contains(key)
            { continue }
        }
        var range = CFRange(location: 0, length: (original as NSString).length)
        guard let argument = AXValueCreate(.cfRange, &range) else { throw ProbeFailure("Could not form AX range") }
        for key in [
            kAXStringForRangeParameterizedAttribute, kAXAttributedStringForRangeParameterizedAttribute,
            kAXBoundsForRangeParameterizedAttribute,
        ] {
            guard parameters.contains(key) else {
                if self.parameters.contains(key) { throw ProbeFailure("Lost " + key) }
                continue
            }
            var result: CFTypeRef?
            try checked(AXUIElementCopyParameterizedAttributeValue(element, key as CFString, argument, &result), key)
            switch key {
            case kAXStringForRangeParameterizedAttribute:
                guard result as? String == original else { throw ProbeFailure("Old AXStringForRange changed") }
            case kAXAttributedStringForRangeParameterizedAttribute:
                guard (result as? NSAttributedString)?.string == original else {
                    throw ProbeFailure("Old AX attributed text changed")
                }
            default:
                var rect = CGRect.zero
                try unpack(result, .cgRect, into: &rect)
                guard [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) else {
                    throw ProbeFailure("Nonfinite AXBoundsForRange")
                }
            }
        }
    }
}
