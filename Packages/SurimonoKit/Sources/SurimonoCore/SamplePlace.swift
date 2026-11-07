/// A place in a document that a theme's sample can start from. Themes fit different amounts on a page, so their first
/// pages rarely show the same text; starting each sample at one place lets them be compared on it.
public struct SamplePlace: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case heading
        case code
    }

    public var kind: Kind
    /// Its position among the places of its kind, in the order of the document.
    public var index: Int
    /// A heading's level, from 1 to 6; a code block has none.
    public var level: Int?
    /// A heading's text, or the first line of a code block.
    public var title: String

    public var id: String { "\(kind.rawValue)-\(index)" }

    public init(kind: Kind, index: Int, level: Int? = nil, title: String) {
        self.kind = kind
        self.index = index
        self.level = level
        self.title = title
    }

    /// This place in a document that may have changed: where it was if it still says the same, or else the first place
    /// of its kind with its words.
    public func found(in places: [SamplePlace]) -> SamplePlace? {
        places.first { $0 == self } ?? places.first { $0.kind == kind && $0.title == title }
    }
}
