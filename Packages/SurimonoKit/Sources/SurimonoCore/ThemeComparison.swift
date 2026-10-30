/// The themes laid side by side to choose from: the current one and up to three others.
///
/// The current theme always stays among the candidates. Adding to a full set drops the candidate that has been there
/// longest, other than the current one, so the newest choices stay in view.
public struct ThemeComparison: Equatable, Sendable {
    public static let capacity = 4

    /// Theme ids in the order they joined.
    public private(set) var candidates: [String]
    public private(set) var current: String

    /// - Parameter suggestions: Themes to start with after the current one, such as the suggested themes.
    public init(current: String, suggestions: [String]) {
        self.current = current
        var candidates = [current]
        for id in suggestions where !candidates.contains(id) && candidates.count < Self.capacity {
            candidates.append(id)
        }
        self.candidates = candidates
    }

    public func contains(_ id: String) -> Bool { candidates.contains(id) }

    /// Adds `id`, or takes it out again when it is already there and is not the current theme.
    public mutating func toggle(_ id: String) {
        if contains(id) {
            remove(id)
            return
        }
        if candidates.count >= Self.capacity, let oldest = candidates.firstIndex(where: { $0 != current }) {
            candidates.remove(at: oldest)
        }
        candidates.append(id)
    }

    /// Takes `id` out; the current theme stays.
    public mutating func remove(_ id: String) {
        guard id != current else { return }
        candidates.removeAll { $0 == id }
    }

    /// Makes a candidate the current theme. It keeps its place, and the previous current theme becomes an ordinary
    /// candidate that can be taken out.
    public mutating func choose(_ id: String) {
        guard contains(id) else { return }
        current = id
    }

    /// Keeps the current theme and fills the rest with themes drawn at random from `pool`.
    public mutating func shuffle(from pool: [String], using generator: inout some RandomNumberGenerator) {
        var remaining = pool.filter { $0 != current }
        var candidates = [current]
        while candidates.count < Self.capacity, !remaining.isEmpty {
            let id = remaining.remove(at: Int.random(in: remaining.indices, using: &generator))
            if !candidates.contains(id) { candidates.append(id) }
        }
        self.candidates = candidates
    }
}
