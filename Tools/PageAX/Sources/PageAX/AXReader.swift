import ApplicationServices
import Foundation

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct AXFailure: Error {
    let api: String
    let error: AXError
}

private func checked(_ result: AXError, _ api: String) throws {
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

private func identifier(_ element: AXUIElement, attributes: [String]) throws -> String? {
    guard attributes.contains(kAXIdentifierAttribute) else { return nil }
    do { return try value(element, kAXIdentifierAttribute) as? String } catch let failure as AXFailure
        where failure.error == .noValue
    { return nil }
}

struct AXReader {
    let app: AXUIElement
    let token: String

    func page(from root: AXUIElement, generation: Int) throws -> AXUIElement {
        var queue = [root]
        var visited = Set<AXUIElement>()
        var index = 0
        while index < queue.count, index < 4000 {
            let node = queue[index]
            index += 1
            guard visited.insert(node).inserted else { continue }
            let attributes = try names(node)
            if try identifier(node, attributes: attributes)?.hasPrefix(token + ".page.") == true,
                attributes.contains(kAXValueAttribute), let text = try value(node, kAXValueAttribute) as? String,
                Self.hasMarker(text, generation)
            {
                return node
            }
            if attributes.contains(kAXChildrenAttribute) {
                do { queue += try value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] } catch let failure
                    as AXFailure where failure.error == .noValue
                { continue }
            }
        }
        throw ProbeFailure("No published page for generation " + String(generation))
    }

    static func hasMarker(_ text: String, _ generation: Int) -> Bool {
        text.filter { !$0.isWhitespace }.contains("世代\(generation)。")
    }

    func currentPage(generation: Int) throws -> AXUIElement {
        guard try names(app).contains(kAXFocusedWindowAttribute) else { throw ProbeFailure("No focused window") }
        return try page(from: axElement(value(app, kAXFocusedWindowAttribute)), generation: generation)
    }

    func initialPages() throws -> [String: AXUIElement] {
        let child = try currentPage(generation: 0)
        let attrs = try names(child)
        guard attrs.contains(kAXPositionAttribute), attrs.contains(kAXSizeAttribute) else {
            throw ProbeFailure("Page has no position or size")
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        try unpack(value(child, kAXPositionAttribute), .cgPoint, into: &position)
        try unpack(value(child, kAXSizeAttribute), .cgSize, into: &size)
        var hit: AXUIElement?
        try checked(
            AXUIElementCopyElementAtPosition(
                app, Float(position.x + size.width / 2),
                Float(position.y + size.height / 2), &hit), "hitTest")
        guard let hit, try identifier(hit, attributes: names(hit))?.hasPrefix(token + ".page.") == true else {
            throw ProbeFailure("Hit test did not return the fixture's page")
        }
        guard try names(app).contains(kAXFocusedUIElementAttribute) else { throw ProbeFailure("No focused element") }
        let focus = try axElement(value(app, kAXFocusedUIElementAttribute))
        let focusID = try identifier(focus, attributes: names(focus))
        guard focusID == token + ".paper" || focusID?.hasPrefix(token + ".page.") == true else {
            throw ProbeFailure("Focus did not reach the fixture's paper")
        }
        return ["children": child, "hit": hit, "focus": try page(from: focus, generation: 0)]
    }
}

struct HeldPage {
    let element: AXUIElement
    let original: String
    let attributes: [String]
    let parameters: [String]

    init(_ element: AXUIElement) throws {
        self.element = element
        attributes = try names(element)
        parameters = try names(element, parameterized: true)
        guard attributes.contains(kAXValueAttribute), let original = try value(element, kAXValueAttribute) as? String,
            AXReader.hasMarker(original, 0)
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
                where error.error == .noValue && [kAXParentAttribute, kAXChildrenAttribute].contains(key)
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
