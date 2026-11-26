/// File locations belong to the instruction even while a document choice takes precedence.
public struct ReadingInstructionSource: Equatable, Sendable {
    public let fileName: String?
    public let lineNumber: Int
    public let rawText: String

    /// Retain the original lines so the reason row never has to reopen a changed file.
    public struct Excerpt: Equatable, Sendable {
        public let previous: String?
        public let line: String
        public let next: String?
        public let tokenOffset: Int
    }

    public internal(set) var excerpt: Excerpt?

    public init(fileName: String?, lineNumber: Int, rawText: String) {
        self.fileName = fileName
        self.lineNumber = lineNumber
        self.rawText = rawText
    }
}

public struct ReadingInstruction<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let source: ReadingInstructionSource?

    public init(_ value: Value, source: ReadingInstructionSource? = nil) {
        self.value = value
        self.source = source
    }
}

public enum ReadingLayer: Equatable, Sendable { case file, document, app }

/// Resolve one independently editable component. An atomic setting, including an Org depth, has one.
public struct ReadingResolution<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value
    public let inherited: Value
    public let layer: ReadingLayer
    public let source: ReadingInstructionSource?
    public let isLocked: Bool

    public init(file: ReadingInstruction<Value>?, document: Value?, app: Value, allowsFileChanges: Bool) {
        source = file?.source
        inherited = file?.value ?? app
        isLocked = file != nil && !allowsFileChanges
        if let document, !isLocked {
            value = document
            layer = .document
        } else {
            value = inherited
            layer = file == nil ? .app : .file
        }
    }

    /// Called only on a user action. A reload or a new app default never removes a stored choice.
    public func set(_ newValue: Value, in choice: inout Value?) {
        guard !isLocked else { return }
        choice = newValue == inherited ? nil : newValue
    }
}

/// The enabled depth is independent of whether contents or numbers are present.
public enum ReadingDepth: Codable, Hashable, Sendable {
    case all
    case levels(Int)

    public var headingLevels: Int {
        switch self {
        case .levels(let n): min(6, max(0, n))
        case .all: 6
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let n = try? container.decode(Int.self), n >= 0 {
            self = .levels(n)
        } else if (try? container.decode(String.self)) == "all" {
            self = .all
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid reading depth")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all: try container.encode("all")
        case .levels(let n): try container.encode(n)
        }
    }

}

public struct ReadingFileInstructions: Equatable, Sendable {
    public var present: ReadingInstruction<Bool>?
    public var depth: ReadingInstruction<ReadingDepth>?

    public init(present: ReadingInstruction<Bool>? = nil, depth: ReadingInstruction<ReadingDepth>? = nil) {
        self.present = present
        self.depth = depth
    }

    /// A file token that selects an enabled depth fixes both components with the same source.
    public init(enabledTo depth: ReadingDepth, source: ReadingInstructionSource) {
        self.init(present: .init(true, source: source), depth: .init(depth, source: source))
    }

}
