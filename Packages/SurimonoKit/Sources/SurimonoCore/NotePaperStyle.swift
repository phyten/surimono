import Foundation

public struct NotePaperStyle: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case ruled, grid, dot, dotted, dashed, wavy, plain, cornell, genko, staff, table
    }

    public enum Decoration: String, Codable, CaseIterable, Sendable {
        case none, minutes, gingham, mizutama, stripe, ichigo, hoshizora, kumo, ribbon, nikukyu, hana
    }

    public struct Header: Codable, Equatable, Sendable {
        public var date: Bool
        public var title: Bool
        public var pageNumber: Bool

        public init(date: Bool = false, title: Bool = false, pageNumber: Bool = true) {
            self.date = date
            self.title = title
            self.pageNumber = pageNumber
        }

        private enum CodingKeys: String, CodingKey { case date, title, pageNumber }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            date = (try? values.decode(Bool.self, forKey: .date)) ?? false
            title = (try? values.decode(Bool.self, forKey: .title)) ?? false
            pageNumber = (try? values.decode(Bool.self, forKey: .pageNumber)) ?? true
        }
    }

    public var kind: Kind
    public var weightInMillimeters: Double
    public var spacingInMillimeters: Double
    public var marginInMillimeters: Double
    public var colorHex: String
    public var header: Header
    public var decoration: Decoration

    public init(
        kind: Kind = .ruled, weightInMillimeters: Double = 0.2, spacingInMillimeters: Double = 7,
        marginInMillimeters: Double = 12, colorHex: String = "#7FA3C7", header: Header = Header(),
        decoration: Decoration = .none
    ) {
        self.kind = kind
        self.weightInMillimeters = weightInMillimeters
        self.spacingInMillimeters = spacingInMillimeters
        self.marginInMillimeters = marginInMillimeters
        self.colorHex = colorHex
        self.header = header
        self.decoration = decoration
    }

    private enum CodingKeys: String, CodingKey {
        case kind, weightInMillimeters, spacingInMillimeters, marginInMillimeters, colorHex, header, decoration
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Decode fields independently so a future choice cannot discard the user's other settings.
        self.init(
            kind: (try? values.decode(Kind.self, forKey: .kind)) ?? .ruled,
            weightInMillimeters: (try? values.decode(Double.self, forKey: .weightInMillimeters)) ?? 0.2,
            spacingInMillimeters: (try? values.decode(Double.self, forKey: .spacingInMillimeters)) ?? 7,
            marginInMillimeters: (try? values.decode(Double.self, forKey: .marginInMillimeters)) ?? 12,
            colorHex: (try? values.decode(String.self, forKey: .colorHex)) ?? "#7FA3C7",
            header: (try? values.decode(Header.self, forKey: .header)) ?? Header(),
            decoration: (try? values.decode(Decoration.self, forKey: .decoration)) ?? .none)
    }
}
