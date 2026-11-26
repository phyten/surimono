import Foundation

extension WikiReader {
    func template(_ body: String, block: Bool) -> String {
        let fields = body.wikiFields(separatedBy: "|")
        // Positional templates only inspect their first two arguments. Other templates consume fields as needed.
        let head = fields.prefix(3).map(\.wikiTrim)
        let name = head[0].replacingOccurrences(of: "_", with: " ")
        let first = head.count > 1 ? head[1] : ""
        let args = fields.dropFirst().lazy.map(\.wikiTrim)
        // MediaWiki title normalization folds only the first letter; the remainder can distinguish two templates.
        let key = name.prefix(1).lowercased() + String(name.dropFirst())
        switch key {
        case "!": return "|"
        case "=": return "="
        case "spaces", "nbsp": return "&nbsp;"
        case "lang" where head.count == 3:
            return "<span lang=\"\(HTML.escape(first))\">\(inline(head[2]))</span>"
        case "nowrap": return "<span class=\"wiki-nowrap\">\(inline(first))</span>"
        case "small": return "<small>\(inline(first))</small>"
        case "math": return "<code>\(inline(first))</code>"
        case "clear", "-": return ""
        case "reflist", "references":
            guard let data = named(args) else { return "" }
            return referenceList(data["group"] ?? "")
        case "quote":
            let credit = head.count == 3 ? " — <cite>\(inline(head[2]))</cite>" : ""
            return "<blockquote>\(inline(first))\(credit)</blockquote>"
        case "main", "see also", "main article", "詳細", "seealso", "関連項目":
            let main = ["main", "main article", "詳細"].contains(key)
            let label = main ? (japanese ? "詳細" : "Main article") : (japanese ? "関連項目" : "See also")
            var links = ""
            for (index, arg) in args.enumerated() {
                if index.isMultiple(of: 128), PreviewConversion.expired { return "" }
                if index > 0 { links += ", " }
                links += inline(arg)
            }
            return "<small><em>\(label): \(links)</em></small>"
        case "仮リンク": return inline(first)
        case "cite web", "cite book", "cite journal", "cite news", "ウェブ引用", "書籍引用", "論文引用", "ニュース引用":
            guard let data = named(args) else { return "" }
            let author =
                data["author"] ?? data["著者"] ?? [data["first"], data["last"]].compactMap { $0 }.joined(separator: " ")
            let title = inline(data["title"] ?? data["タイトル"] ?? "")
            let link = data["url"].map { anchor($0, HTML.escape($0)) }
            let publisher = data["publisher"] ?? data["website"] ?? data["journal"] ?? data["出版者"]
            let accessed = data["access-date"] ?? data["accessdate"] ?? data["閲覧日"]
            return [
                inline(author), title, link, publisher.map(inline),
                (data["date"] ?? data["year"] ?? data["日付"]).map(inline),
                accessed.map { (japanese ? "閲覧日 " : "Accessed ") + inline($0) },
            ]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
        default:
            let unresolved = name.hasPrefix("#") ? String(name.prefix(while: { $0 != ":" })) : name
            let label = inline(unresolved)
            guard block else { return "<small class=\"wiki-template\">\(label)</small>" }
            var rows: [String] = []
            for (index, arg) in args.enumerated() {
                if index.isMultiple(of: 128), PreviewConversion.expired { return "" }
                guard let equals = arg.firstIndex(of: "=") else { continue }
                if rows.count == 40 {
                    rows.append("<tr><td colspan=\"2\">…</td></tr>")
                    break
                }
                let key = String(arg[..<equals]).wikiTrim
                let value = String(arg[arg.index(after: equals)...]).wikiTrim
                rows.append("<tr><th>\(inline(key))</th><td>\(inline(value))</td></tr>")
            }
            let table = rows.isEmpty ? "" : "<table>" + rows.joined() + "</table>"
            return "<div class=\"wiki-note\"><strong>\(label)</strong>\(table)</div>"
        }
    }

    private func named(_ args: some Sequence<String>) -> [String: String]? {
        var values: [String: String] = [:]
        for (offset, arg) in args.enumerated() {
            if offset.isMultiple(of: 128), PreviewConversion.expired { return nil }
            if let index = arg.firstIndex(of: "=") {
                values[String(arg[..<index]).wikiTrim.lowercased()] = String(arg[arg.index(after: index)...]).wikiTrim
            }
        }
        return values
    }
}
