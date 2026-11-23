/// Aho–Corasick over UTF-16. Register both the passages and the individual findings, so an extra
/// heading counts even if it only repeats the finding. Reading backwards shares common sentence
/// endings and gives the start of each (possibly overlapping) match directly.
struct ProsePatternIndex {
    private struct Node {
        var children: [UInt16: Int] = [:]
        var failure = 0
        var output = 0
        var pattern: Int?
    }

    private var nodes = [Node()]
    private(set) var lengths: [Int] = []

    mutating func register(_ units: ArraySlice<UInt16>) throws -> Int {
        var state = 0
        for i in units.indices.reversed() {
            if i.isMultiple(of: 8192) { try Task.checkCancellation() }
            let unit = units[i]
            if let child = nodes[state].children[unit] {
                state = child
            } else {
                let child = nodes.count
                nodes.append(Node())
                nodes[state].children[unit] = child
                state = child
            }
        }
        if let id = nodes[state].pattern { return id }
        let id = lengths.count
        nodes[state].pattern = id
        lengths.append(units.count)
        return id
    }

    mutating func prepare() throws {
        var queue = Array(nodes[0].children.values)
        var index = 0
        while index < queue.count {
            if index.isMultiple(of: 8192) { try Task.checkCancellation() }
            let parent = queue[index]
            for (unit, child) in nodes[parent].children {
                let failure = next(from: nodes[parent].failure, unit: unit)
                nodes[child].failure = failure
                nodes[child].output = nodes[failure].pattern == nil ? nodes[failure].output : failure
                queue.append(child)
            }
            index += 1
        }
    }

    private func next(from state: Int, unit: UInt16) -> Int {
        var state = state
        while true {
            if let child = nodes[state].children[unit] { return child }
            if state == 0 { return 0 }
            state = nodes[state].failure
        }
    }

    func matches(in units: [UInt16]) throws -> [[Int]] {
        var hits = Array(repeating: [Int](), count: lengths.count)
        var state = 0
        for i in units.indices.reversed() {
            if i.isMultiple(of: 8192) { try Task.checkCancellation() }
            state = next(from: state, unit: units[i])
            var terminal = state
            while terminal != 0 {
                if let pattern = nodes[terminal].pattern { hits[pattern].append(i) }
                terminal = nodes[terminal].output
            }
        }
        for index in hits.indices { hits[index].reverse() }
        return hits
    }
}
