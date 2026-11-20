import CoreText
import Foundation
import Synchronization

/// A process snapshot of the fonts available to local document rendering.
public struct InstalledFontIndex: Sendable {
    public struct Face: Sendable {
        public let family: String
        public let postScriptName: String
        public let bold: String?
        public let italic: String?
        public let boldItalic: String?
        let sharesIdeographs: Bool

        public init(
            family: String, postScriptName: String, bold: String? = nil, italic: String? = nil,
            boldItalic: String? = nil, sharesIdeographs: Bool = false
        ) {
            self.family = family
            self.postScriptName = postScriptName
            self.bold = bold
            self.italic = italic
            self.boldItalic = boldItalic
            self.sharesIdeographs = sharesIdeographs
        }
    }

    // Passing the default through a reader must stay cheap for documents without font requests.
    public static let system = Self { SystemFonts.shared.face(for: $0) }
    private let lookup: @Sendable (String) -> Face?

    private init(lookup: @escaping @Sendable (String) -> Face?) { self.lookup = lookup }

    /// Supply a fixed inventory, keyed by the family, full or PostScript names a document can request.
    public init(faces: [String: Face]) {
        let entries = Dictionary(faces.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        lookup = { entries[$0] }
    }

    public func face(named name: String) -> Face? { lookup(name.lowercased()) }

    /// Only the system inventory can supply faces for native drawing.
    public static func systemFont(named name: String, size: CGFloat) -> CTFont? {
        guard let face = system.face(named: name) else { return nil }
        return CTFontCreateWithName(face.postScriptName as CFString, size, nil)
    }
}

private final class SystemFonts: Sendable {
    static let shared = SystemFonts()
    typealias Face = InstalledFontIndex.Face

    private struct Cache {
        var names: [String: String]
        var faces: [String: Face?] = [:]
    }

    private let cache: Mutex<Cache>
    private let postScriptNames: Set<String>

    private init() {
        let families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        let postScript = CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
        postScriptNames = Set(postScript)
        var names = [String: String]()
        for name in families + postScript { names[name.lowercased()] = name }

        // Read just the name attributes in bulk. Creating a CTFont for every descriptor would
        // load unrelated faces before the document has requested even one.
        let keys: NSSet = [
            kCTFontNameAttribute, kCTFontDisplayNameAttribute, kCTFontFamilyNameAttribute, kCTFontStyleNameAttribute,
        ]
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let rows = CTFontCollectionCopyFontAttributes(collection, keys, []) as? [[String: Any]] ?? []
        for row in rows {
            guard let ps = row[kCTFontNameAttribute as String] as? String, postScriptNames.contains(ps) else {
                continue
            }
            if let full = row[kCTFontDisplayNameAttribute as String] as? String, names[full.lowercased()] == nil {
                names[full.lowercased()] = ps
            }
            if let family = row[kCTFontFamilyNameAttribute as String] as? String,
                let style = row[kCTFontStyleNameAttribute as String] as? String
            {
                let full = (family + " " + style).lowercased()
                if names[full] == nil { names[full] = ps }
            }
        }
        // These spellings occur in cross-platform TeX sources. Only alias an installed target.
        for (alias, canonical) in [
            "Yu Mincho": "YuMincho", "游明朝": "YuMincho", "Yu Gothic": "YuGothic", "游ゴシック": "YuGothic",
            "ヒラギノ明朝 ProN": "HiraMinProN-W3", "Hiragino Mincho ProN": "HiraMinProN-W3",
            "ヒラギノ角ゴ ProN": "HiraKakuProN-W3", "ヒラギノ角ゴシック": "Hiragino Sans",
        ] where names[alias.lowercased()] == nil {
            names[alias.lowercased()] = names[canonical.lowercased()]
        }
        cache = Mutex(Cache(names: names))
    }

    func face(for key: String) -> Face? {
        cache.withLock { cache in
            // Matching a missing name can enter font auto-activation. Arbitrary document names
            // must never reach Core Text or accumulate in the process cache.
            guard let name = cache.names[key] else { return nil }
            if let cached = cache.faces[name] { return cached }
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            let ps = CTFontCopyPostScriptName(font) as String
            let family = CTFontCopyFamilyName(font) as String
            let full = CTFontCopyFullName(font) as String
            let localFamily = CTFontCopyLocalizedName(font, kCTFontFamilyNameKey, nil) as String?
            let localFull = CTFontCopyLocalizedName(font, kCTFontFullNameKey, nil) as String?
            guard postScriptNames.contains(ps),
                [ps, family, full, localFamily, localFull].compactMap({ $0 }).contains(where: {
                    $0.caseInsensitiveCompare(name) == .orderedSame
                })
            else {
                cache.faces.updateValue(nil, forKey: name)
                return nil
            }
            for spelling in [full, localFull].compactMap({ $0 }) where cache.names[spelling.lowercased()] == nil {
                cache.names[spelling.lowercased()] = ps
            }
            if let localFamily, cache.names[localFamily.lowercased()] == nil {
                cache.names[localFamily.lowercased()] = cache.names[family.lowercased()]
            }
            if let cached = cache.faces[ps] {
                cache.faces.updateValue(cached, forKey: name)
                return cached
            }
            func variant(_ traits: CTFontSymbolicTraits) -> CTFont? {
                guard let face = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits),
                    CTFontCopyFamilyName(face) as String == family, CTFontGetSymbolicTraits(face).contains(traits),
                    postScriptNames.contains(CTFontCopyPostScriptName(face) as String)
                else { return nil }
                return face
            }
            let bold = variant(.boldTrait)
            let italic = variant(.italicTrait)
            let both = bold != nil && italic != nil ? variant([.boldTrait, .italicTrait]) : nil
            let face = Face(
                family: family, postScriptName: ps, bold: bold.map { CTFontCopyPostScriptName($0) as String },
                italic: italic.map { CTFontCopyPostScriptName($0) as String },
                boldItalic: both.map { CTFontCopyPostScriptName($0) as String },
                sharesIdeographs: [font, bold, italic].compactMap { $0 }.contains(where: LaTeXIdeographs.needsFallback))
            cache.faces[ps] = face
            cache.faces[name] = face
            return face
        }
    }
}
