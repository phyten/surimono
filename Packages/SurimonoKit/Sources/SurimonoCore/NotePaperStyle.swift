import Foundation

public struct NotePaperStyle: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case ruled, grid, dot, dotted, dashed, wavy, plain, cornell, genko, staff, table
    }

    public enum Decoration: String, Codable, CaseIterable, Sendable {
        case none, minutes, gingham, mizutama, stripe, ichigo, hoshizora, kumo, ribbon, nikukyu, hana
    }

    public struct Header: Codable, Hashable, Sendable {
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

extension NotePaperStyle {
    /// The colors the sheet offers, with their names in the string catalog.
    public static let palette: [(hex: String, name: String)] = [
        ("#7FA3C7", "Sky"), ("#2B4C6F", "Indigo"), ("#9A9A96", "Gray"), ("#3A3A3D", "Ink"), ("#B08A5E", "Brown"),
        ("#7FA65B", "Young Green"), ("#E59AAE", "Cherry"), ("#A99BD1", "Wisteria"), ("#D9A63E", "Gold"),
        ("#B86A5A", "Red Ochre"),
    ]

    /// Lines this thin and pale can fade or break up on an office printer.
    public var isFaint: Bool {
        guard kind != .plain, let contrast = contrastOnWhite else { return false }
        return (weightInMillimeters <= 0.15 && contrast < 3.2) || (weightInMillimeters <= 0.25 && contrast < 1.9)
    }

    private var contrastOnWhite: Double? {
        let digits = colorHex.hasPrefix("#") ? String(colorHex.dropFirst()) : colorHex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        let channels = [(value >> 16) & 255, (value >> 8) & 255, value & 255].map { channel -> Double in
            let level = Double(channel) / 255
            return level <= 0.03928 ? level / 12.92 : pow((level + 0.055) / 1.055, 2.4)
        }
        return 1.05 / (0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2] + 0.05)
    }
}
