public struct PageHistory: Equatable, Sendable {
    private var backward: [ReadingPosition] = []
    private var forwardPositions: [ReadingPosition] = []

    public init() {}
    public var canGoBack: Bool { !backward.isEmpty }
    public var canGoForward: Bool { !forwardPositions.isEmpty }

    public mutating func record(_ position: ReadingPosition) {
        appendBackward(position)
        forwardPositions.removeAll()
    }

    public mutating func back(from current: ReadingPosition) -> ReadingPosition? {
        guard let position = backward.popLast() else { return nil }
        if forwardPositions.last != current { forwardPositions.append(current) }
        return position
    }

    public mutating func forward(from current: ReadingPosition) -> ReadingPosition? {
        guard let position = forwardPositions.popLast() else { return nil }
        appendBackward(current)
        return position
    }

    private mutating func appendBackward(_ position: ReadingPosition) {
        guard backward.last != position else { return }
        backward.append(position)
        if backward.count > 50 { backward.removeFirst(backward.count - 50) }
    }
}
