import Foundation

public struct PrinterProfile: Codable, Equatable, Sendable {
    public private(set) var rotatesBackSides: [DuplexMode: Bool]
    public var pageOrder: PrintPageOrder?

    public init(rotatesBackSides: [DuplexMode: Bool] = [:], pageOrder: PrintPageOrder? = nil) {
        self.rotatesBackSides = rotatesBackSides.filter { $0.key != .none }
        self.pageOrder = pageOrder
    }

    public func rotation(for duplex: DuplexMode, default fallback: Bool) -> Bool {
        duplex != .none && (rotatesBackSides[duplex] ?? fallback)
    }

    public func resolvedPageOrder(default fallback: PrintPageOrder) -> PrintPageOrder {
        pageOrder ?? fallback
    }

    public mutating func setRotation(_ rotates: Bool, for duplex: DuplexMode) {
        guard duplex != .none else { return }
        rotatesBackSides[duplex] = rotates
    }

    private enum CodingKeys: String, CodingKey { case rotatesBackSides, pageOrder }
    private enum BindingKeys: String, CodingKey { case longEdge, shortEdge }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rotatesBackSides = [:]
        // Decode each binding separately so a future or damaged value does not discard a working calibration.
        if let bindings = try? values.nestedContainer(keyedBy: BindingKeys.self, forKey: .rotatesBackSides) {
            if let value = try? bindings.decode(Bool.self, forKey: .longEdge) { rotatesBackSides[.longEdge] = value }
            if let value = try? bindings.decode(Bool.self, forKey: .shortEdge) { rotatesBackSides[.shortEdge] = value }
        }
        pageOrder = try? values.decode(PrintPageOrder.self, forKey: .pageOrder)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        var bindings = values.nestedContainer(keyedBy: BindingKeys.self, forKey: .rotatesBackSides)
        try bindings.encodeIfPresent(rotatesBackSides[.longEdge], forKey: .longEdge)
        try bindings.encodeIfPresent(rotatesBackSides[.shortEdge], forKey: .shortEdge)
        try values.encodeIfPresent(pageOrder, forKey: .pageOrder)
    }
}
