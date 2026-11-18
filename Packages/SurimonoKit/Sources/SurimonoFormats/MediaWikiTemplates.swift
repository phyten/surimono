import Foundation

extension WikiReader {
    func template(_ body: String, block: Bool) -> String {
        let fields = body.components(separatedBy: "|").map(\.wikiTrim)
        let name = fields[0].replacingOccurrences(of: "_", with: " ")
        let args = Array(fields.dropFirst())
        let first = args.first ?? ""
        // MediaWiki title normalization folds only the first letter; the remainder can distinguish two templates.
        let key = name.prefix(1).lowercased() + String(name.dropFirst())
        switch key {
        case "!": return "|"
        case "=": return "="
        case "spaces", "nbsp": return "&nbsp;"
        case "lang" where args.count >= 2:
            return "<span lang=\"\(HTML.escape(first))\">\(inline(args[1]))</span>"
        case "nowrap": return "<span class=\"wiki-nowrap\">\(inline(first))</span>"
        case "small": return "<small>\(inline(first))</small>"
        case "math": return "<code>\(inline(first))</code>"
        case "clear", "-": return ""
        case "reflist", "references":
            return referenceList(named(args)["group"] ?? "")
        case "quote":
            let credit = args.count > 1 ? " — <cite>\(inline(args[1]))</cite>" : ""
            return "<blockquote>\(inline(first))\(credit)</blockquote>"
        case "main", "see also", "main article", "詳細", "seealso", "関連項目":
            let main = ["main", "main article", "詳細"].contains(key)
            let label = main ? (japanese ? "詳細" : "Main article") : (japanese ? "関連項目" : "See also")
            return "<small><em>\(label): \(args.map(inline).joined(separator: ", "))</em></small>"
        case "仮リンク": return inline(first)
        case "cite web", "cite book", "cite journal", "cite news", "ウェブ引用", "書籍引用", "論文引用", "ニュース引用":
            let data = named(args)
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
            for arg in args {
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

    private func named(_ args: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for arg in args {
            if let index = arg.firstIndex(of: "=") {
                values[String(arg[..<index]).wikiTrim.lowercased()] = String(arg[arg.index(after: index)...]).wikiTrim
            }
        }
        return values
    }
}
