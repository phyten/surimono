import Foundation

/// How many elements an SVG asks WebKit to draw once every reference is followed, counted from the markup alone.
///
/// A `<use>` draws a copy of what it points at, and a pattern, filter, mask, clip path, marker or gradient is drawn
/// again for each element that refers to it with `url(#…)` or `href="#…"`. Ten references to a group that holds ten
/// references to the next group, eleven levels down, is a short file that draws 10^11 rectangles: WebKit then works
/// past any deadline (the 15 seconds an image may take, and the few seconds the robustness tests allow). Such files are
/// refused before WebKit is asked to draw them.
enum SVGComplexity {
    /// Elements drawn after following references. An ordinary drawing, even a detailed map, draws tens of thousands;
    /// a quarter of a million leaves room for those while keeping WebKit's work to a few seconds at worst.
    static let maximumDrawnElements = 250_000

    /// Whether the drawing stays within `maximumDrawnElements`. A reference that leads back to itself is refused too:
    /// it is an error in SVG and a loop for a counter.
    static func withinLimit(_ data: Data) -> Bool {
        let counter = Counter()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = counter
        parser.parse()
        // A parse error that is not this counter's own leaves what was read so far; WebKit, which reads XML on its
        // own terms, decides about the rest.
        if counter.exceeded { return false }
        return counter.drawnElements().map { $0 <= maximumDrawnElements } ?? false
    }

    /// The markup as a tree of the elements that carry an `id`, each holding what it draws directly.
    private final class Counter: NSObject, XMLParserDelegate {
        struct Node {
            var elements = 0
            var references: [String] = []
            var children: [Int] = []
        }
        // Node 0 holds everything outside an element with an id.
        var nodes = [Node()]
        var identifiers: [String: Int] = [:]
        /// For each open element, the node it adds to.
        var open: [Int] = []
        var elements = 0
        var exceeded = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            var owner = open.last ?? 0
            if let id = attributes["id"], !id.isEmpty, identifiers[id] == nil {
                let node = nodes.count
                nodes.append(Node())
                nodes[owner].children.append(node)
                identifiers[id] = node
                owner = node
            }
            nodes[owner].elements += 1
            for (name, value) in attributes {
                if name == "href" || name.hasSuffix(":href") {
                    if value.hasPrefix("#") { nodes[owner].references.append(String(value.dropFirst())) }
                } else if value.contains("url(") {
                    nodes[owner].references += Self.urlTargets(value)
                }
            }
            open.append(owner)
            elements += 1
            // Even without references the file draws too much; the count need not go on.
            if elements > SVGComplexity.maximumDrawnElements {
                exceeded = true
                parser.abortParsing()
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
        ) {
            _ = open.popLast()
        }

        /// The ids in `url(#id)`, as written in an attribute or a style.
        static func urlTargets(_ value: String) -> [String] {
            var targets: [String] = []
            var rest = Substring(value)
            while let start = rest.range(of: "url(") {
                rest = rest[start.upperBound...].drop(while: { $0 == " " || $0 == "'" || $0 == "\"" })
                guard rest.first == "#" else { continue }
                let id = rest.dropFirst().prefix(while: { !")'\" ".contains($0) })
                if !id.isEmpty { targets.append(String(id)) }
            }
            return targets
        }

        /// The elements drawn from node 0, each reference counting what it points at; nil for a reference cycle.
        /// Worked without recursion, since the nesting comes from the file.
        func drawnElements() -> Int? {
            let limit = SVGComplexity.maximumDrawnElements + 1
            var cost = [Int?](repeating: nil, count: nodes.count)
            var visiting = [Bool](repeating: false, count: nodes.count)
            func dependencies(_ node: Int) -> [Int] {
                nodes[node].children + nodes[node].references.compactMap { identifiers[$0] }
            }
            var stack: [(node: Int, expanded: Bool)] = [(0, false)]
            while let (node, expanded) = stack.popLast() {
                if cost[node] != nil { continue }
                if expanded {
                    visiting[node] = false
                    // References beyond the limit saturate there; the answer is already "too many".
                    var total = nodes[node].elements
                    for child in nodes[node].children { total = min(limit, total + (cost[child] ?? 0)) }
                    for reference in nodes[node].references {
                        if let target = identifiers[reference] { total = min(limit, total + (cost[target] ?? 0)) }
                    }
                    cost[node] = total
                    continue
                }
                if visiting[node] { return nil }
                visiting[node] = true
                stack.append((node, true))
                for next in dependencies(node) where cost[next] == nil {
                    if visiting[next] { return nil }
                    stack.append((next, false))
                }
            }
            return cost[0]
        }
    }
}
