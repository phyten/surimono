/// The reader can withdraw a tray request until the complete paper is ready.
public struct PreviewPrintRequest: Equatable, Sendable {
    public enum Destination: Equatable, Sendable {
        case currentLayout
        case layout(String)
    }

    public private(set) var destination: Destination?
    public init() {}

    public mutating func press(_ choice: Destination) {
        destination = destination == nil ? choice : nil
    }

    public mutating func cancel() { destination = nil }

    public mutating func take() -> Destination? {
        defer { cancel() }
        return destination
    }
}
