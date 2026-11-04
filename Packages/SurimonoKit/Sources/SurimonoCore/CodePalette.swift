import Foundation

/// The colors of highlighted code, an axis of its own beside the print theme: the theme says how the page looks, the
/// palette how code reads on it. Layered over the theme's `--hl-*` values, so "Match Style" is simply no palette.
public struct CodePalette: Equatable, Sendable, Identifiable {
    public enum Token: String, CaseIterable, Sendable {
        case keyword, type, builtin, function, literal, number, string, comment, meta, tag, attr, variable, addition,
            deletion, section
    }

    public struct Face: Equatable, Sendable {
        public let weight: Int
        public let isItalic: Bool

        public init(weight: Int, isItalic: Bool = false) {
            self.weight = weight
            self.isItalic = isItalic
        }

        /// What `common.css` gives each token.
        public static func standard(for token: Token) -> Self {
            switch token {
            case .keyword, .literal, .tag, .addition, .section: Self(weight: 600)
            case .comment: Self(weight: 400, isItalic: true)
            default: Self(weight: 400)
            }
        }

        /// A catalog value such as `700/italic`.
        init?(catalogValue: String) {
            let parts = catalogValue.split(separator: "/")
            guard parts.count == 2, let weight = Int(parts[0]), ["normal", "italic"].contains(parts[1]) else {
                return nil
            }
            self.init(weight: weight, isItalic: parts[1] == "italic")
        }
    }

    public enum Group: String, Sendable {
        case candidate
        /// Works on paper but costs far more ink, so it is offered apart and warns when chosen.
        case inkHeavy
    }

    public enum InkLevel: Sendable {
        case low, normal, raised, high
    }

    /// The id of "Match Style": no palette, the theme's colors as they are.
    public static let matchesStyleID = "match"
    /// The grounds a palette without its own may sit on: white paper, a pale code block, and the darkest theme ground.
    public static let lightGrounds = ["#ffffff", "#f4f3ef", "#eee8d5"]

    public let id: String
    public let name: String
    public let localizedNames: [String: String]
    public let note: String
    public let localizedNotes: [String: String]
    public let group: Group
    public let colors: [Token: String]
    public let faces: [Token: Face]
    public let additionBackground: String?
    public let deletionBackground: String?
    /// The ground of the code block, for a palette that cannot sit on the paper; nil keeps the theme's.
    public let ground: String?
    /// The color of code outside any token; nil keeps the theme's.
    public let ink: String?
    /// Ink a page of code takes, against 100 for the plain standard theme.
    public let inkIndex: Int

    public init(
        id: String, name: String, localizedNames: [String: String] = [:], note: String = "",
        localizedNotes: [String: String] = [:], group: Group = .candidate, colors: [Token: String],
        faces: [Token: Face] = [:], additionBackground: String? = nil, deletionBackground: String? = nil,
        ground: String? = nil, ink: String? = nil, inkIndex: Int = 100
    ) {
        self.id = id
        self.name = name
        self.localizedNames = localizedNames
        self.note = note
        self.localizedNotes = localizedNotes
        self.group = group
        self.colors = colors
        self.faces = faces
        self.additionBackground = additionBackground
        self.deletionBackground = deletionBackground
        self.ground = ground
        self.ink = ink
        self.inkIndex = inkIndex
    }

    public func displayName(language: String = "en") -> String {
        UILanguage.name(localizedNames, language: language, english: name)
    }

    public func displayNote(language: String = "en") -> String {
        UILanguage.name(localizedNotes, language: language, english: note)
    }

    public func face(for token: Token) -> Face { faces[token] ?? .standard(for: token) }

    /// The lowest contrast of any token on any ground it can sit on, the ones of added and removed lines included.
    public var minimumContrast: Double {
        var ratios: [Double] = []
        for ground in ground.map({ [$0] }) ?? Self.lightGrounds {
            ratios += colors.values.compactMap { CodeColor.contrast($0, ground) }
        }
        if let color = colors[.addition], let additionBackground {
            ratios += [CodeColor.contrast(color, additionBackground)].compactMap { $0 }
        }
        if let color = colors[.deletion], let deletionBackground {
            ratios += [CodeColor.contrast(color, deletionBackground)].compactMap { $0 }
        }
        return ratios.min() ?? 0
    }

    public var inkLevel: InkLevel {
        switch inkIndex {
        case 300...: .high
        case 115...: .raised
        case ..<95: .low
        default: .normal
        }
    }

    /// Goes after the theme, which may style a token as well as color it, so every token says all of its look.
    var css: String {
        let values = Token.allCases.compactMap { token in colors[token].map { "--hl-\(token.rawValue): \($0);" } }
        var rules = [":root { \(values.joined(separator: " ")) }"]
        for token in Token.allCases {
            let face = face(for: token)
            let background =
                switch token {
                case .addition: additionBackground ?? "none"
                case .deletion: deletionBackground ?? "none"
                default: "none"
                }
            rules.append(
                "body.surimono .hl-\(token.rawValue) { color: var(--hl-\(token.rawValue)); "
                    + "font-weight: \(face.weight); font-style: \(face.isItalic ? "italic" : "normal"); "
                    + "text-decoration: none; background: \(background); }")
        }
        return rules.joined(separator: "\n")
    }

    /// The colors a theme's style sheet ends up with, for showing "Match Style" beside the palettes.
    public static func colors(inStyleSheet css: String) -> [Token: String] {
        var colors: [Token: String] = [:]
        for token in Token.allCases {
            let name = "--hl-\(token.rawValue):"
            guard let range = css.range(of: name, options: .backwards) else { continue }
            let value = css[range.upperBound...].prefix { $0 != ";" && $0 != "}" }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if CodeColor.components(value) != nil { colors[token] = value }
        }
        return colors
    }
}

/// `#rrggbb` and `#rgb` colors of the code palettes, measured the way WCAG 2 does.
public enum CodeColor {
    public static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.hasPrefix("#") else { return nil }
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else {
            return nil
        }
        return (
            Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255
        )
    }

    public static func contrast(_ first: String, _ second: String) -> Double? {
        guard let a = luminance(first), let b = luminance(second) else { return nil }
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func luminance(_ hex: String) -> Double? {
        guard let color = components(hex) else { return nil }
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }
}

public enum CodePaletteLibrary {
    enum CatalogError: Error, Equatable {
        case duplicatePalette(String)
        case unknownGroup(String)
        case missingColor(palette: String, token: String)
        case invalidColor(palette: String, value: String)
        case invalidFace(palette: String, token: String)
    }

    private struct Catalog: Decodable {
        struct Palette: Decodable {
            let id: String
            let group: String
            let name: String
            let localizedNames: [String: String]?
            let note: String
            let localizedNotes: [String: String]?
            let colors: [String: String]
            let faces: [String: String]?
            let additionBackground: String?
            let deletionBackground: String?
            let ground: String?
            let ink: String?
            let inkIndex: Int
        }
        let palettes: [Palette]
    }

    /// The built-in palettes in the order they are offered, "Match Style" not among them.
    public static func load() throws -> [CodePalette] {
        try palettes(from: Data(contentsOf: CoreResources.url("code-palettes", extension: "json")))
    }

    /// Every value goes into a style sheet, so a catalog is checked whole rather than trusted.
    static func palettes(from data: Data) throws -> [CodePalette] {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var ids = Set<String>()
        return try catalog.palettes.map { entry in
            guard ids.insert(entry.id).inserted else { throw CatalogError.duplicatePalette(entry.id) }
            guard let group = CodePalette.Group(rawValue: entry.group) else {
                throw CatalogError.unknownGroup(entry.group)
            }
            func check(_ value: String?) throws {
                guard let value else { return }
                guard CodeColor.components(value) != nil else {
                    throw CatalogError.invalidColor(palette: entry.id, value: value)
                }
            }
            var colors: [CodePalette.Token: String] = [:]
            for token in CodePalette.Token.allCases {
                guard let color = entry.colors[token.rawValue] else {
                    throw CatalogError.missingColor(palette: entry.id, token: token.rawValue)
                }
                try check(color)
                colors[token] = color
            }
            for value in [entry.additionBackground, entry.deletionBackground, entry.ground, entry.ink] {
                try check(value)
            }
            var faces: [CodePalette.Token: CodePalette.Face] = [:]
            for (name, value) in entry.faces ?? [:] {
                guard let token = CodePalette.Token(rawValue: name),
                    let face = CodePalette.Face(catalogValue: value)
                else { throw CatalogError.invalidFace(palette: entry.id, token: name) }
                faces[token] = face
            }
            return CodePalette(
                id: entry.id, name: entry.name, localizedNames: entry.localizedNames ?? [:], note: entry.note,
                localizedNotes: entry.localizedNotes ?? [:], group: group, colors: colors, faces: faces,
                additionBackground: entry.additionBackground, deletionBackground: entry.deletionBackground,
                ground: entry.ground, ink: entry.ink, inkIndex: entry.inkIndex)
        }
    }
}
