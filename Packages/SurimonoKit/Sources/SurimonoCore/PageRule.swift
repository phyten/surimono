import Foundation

/// An `@page` rule of a document's style sheets, as the page rule script reads it: its selector and its `size`
/// descriptor as written. Only the orientation is taken from it; the paper size stays the reader's layout.
public struct PageRule: Codable, Equatable, Sendable {
    /// Empty for a rule that applies to every page; `:first`, a page name and so on otherwise.
    public var selector: String
    public var size: String
    /// The size was declared `!important`.
    public var important: Bool

    public init(selector: String = "", size: String, important: Bool = false) {
        self.selector = selector
        self.size = size
        self.important = important
    }

    private enum CodingKeys: String, CodingKey { case selector, size, important }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selector = try container.decodeIfPresent(String.self, forKey: .selector) ?? ""
        size = try container.decode(String.self, forKey: .size)
        important = try container.decodeIfPresent(Bool.self, forKey: .important) ?? false
    }

    /// The orientation all pages take, as the cascade picks the size among the rules for every page: an important
    /// declaration beats a normal one wherever it stands, and among equals the later wins. A rule for some pages
    /// only, such as `:first` or a named page, does not turn the whole document.
    public static func orientation(of rules: [PageRule]) -> PaperOrientation? {
        let allPages = rules.filter { $0.selector.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let rule = allPages.last(where: \.important) ?? allPages.last else { return nil }
        return orientation(ofSize: rule.size)
    }

    /// The orientation a `size` value asks for: `landscape`, `A4 landscape` and `297mm 210mm` are landscape;
    /// `portrait`, `A4` and `210mm 297mm` are portrait; `auto`, a square and anything unknown ask for nothing.
    public static func orientation(ofSize value: String) -> PaperOrientation? {
        let tokens =
            value.lowercased().replacingOccurrences(of: "!important", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        if tokens.contains("landscape") { return .landscape }
        if tokens.contains("portrait") { return .portrait }
        let lengths = tokens.compactMap(points(of:))
        if lengths.count == 2 {
            if lengths[0] > lengths[1] { return .landscape }
            if lengths[0] < lengths[1] { return .portrait }
            return nil
        }
        // A named size alone is upright, as CSS defines all of them.
        if lengths.isEmpty, tokens.count == 1, namedSizes.contains(tokens[0]) { return .portrait }
        return nil
    }

    private static let namedSizes: Set<String> = [
        "a5", "a4", "a3", "b5", "b4", "jis-b5", "jis-b4", "letter", "legal", "ledger",
    ]

    private static let pointsPerUnit: [String: Double] = [
        "pt": 1, "px": 0.75, "pc": 12, "in": 72, "cm": 72 / 2.54, "mm": 72 / 25.4, "q": 72 / 101.6,
    ]

    /// A positive CSS length in points, or nil for anything else.
    private static func points(of token: String) -> Double? {
        guard let unitStart = token.firstIndex(where: { $0.isLetter }),
            let factor = pointsPerUnit[String(token[unitStart...])],
            let number = Double(token[..<unitStart]), number > 0
        else { return nil }
        return number * factor
    }

    /// Decodes the page rule script's result; anything unreadable counts as no rules.
    public static func rules(fromJSON json: String) -> [PageRule] {
        (try? JSONDecoder().decode([PageRule].self, from: Data(json.utf8))) ?? []
    }

    /// A callAsyncJavaScript function body that returns the `@page` rules with a size, as JSON. It reads the style
    /// sheets through the DOM, so it works in an isolated world while the document's own JavaScript is off.
    public static let javaScript = #"""
        const rules = [];
        // Whether a media list applies to print. A query matches when its type is print or all; features cannot be
        // known for paper here, so a query with features goes by its type alone.
        const printMatches = media => {
          const text = ((media && media.mediaText) || '').trim().toLowerCase();
          if (!text) return true;
          return text.split(',').some(part => {
            let query = part.trim();
            if (!query) return false;
            let negated = false;
            if (/^not\s/.test(query)) {
              negated = true;
              query = query.slice(4).trim();
            } else if (/^only\s/.test(query)) {
              query = query.slice(5).trim();
            }
            const type = query.startsWith('(') ? 'all' : query.split(/\s+/)[0];
            const matches = type === 'all' || type === 'print';
            return negated ? !matches : matches;
          });
        };
        const supported = rule => {
          try { return CSS.supports(rule.conditionText); } catch (_) { return false; }
        };
        const sizeOf = rule => {
          const style = rule.style;
          const declared = style ? style.getPropertyValue('size') : '';
          if (declared && declared.trim()) {
            return { size: declared.trim(), important: style.getPropertyPriority('size') === 'important' };
          }
          const match = /(?:^|[{;\s])size\s*:\s*([^;}]+)/i.exec(rule.cssText || '');
          if (!match) return null;
          return { size: match[1].replace(/!\s*important/i, '').trim(), important: /!\s*important/i.test(match[1]) };
        };
        const walk = list => {
          for (const rule of Array.from(list || [])) {
            if (rule.type === CSSRule.PAGE_RULE) {
              const declared = sizeOf(rule);
              if (declared && declared.size) {
                rules.push({ selector: (rule.selectorText || '').trim(), size: declared.size, important: declared.important });
              }
              continue;
            }
            // Rules that do not apply to print never reach paper.
            if (rule.media && !printMatches(rule.media)) continue;
            if (rule.type === CSSRule.SUPPORTS_RULE && !supported(rule)) continue;
            if (rule.styleSheet) {
              try { walk(rule.styleSheet.cssRules); } catch (_) {}
            }
            try { if (rule.cssRules) walk(rule.cssRules); } catch (_) {}
          }
        };
        for (const sheet of Array.from(document.styleSheets)) {
          if (sheet.disabled || !printMatches(sheet.media)) continue;
          // A style sheet from another origin cannot be read; its rules are not known.
          try { walk(sheet.cssRules); } catch (_) {}
        }
        return JSON.stringify(rules);
        """#
}
