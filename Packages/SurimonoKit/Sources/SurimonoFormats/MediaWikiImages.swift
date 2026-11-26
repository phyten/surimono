import Foundation

extension WikiReader {
    func image(_ name: String, options: [String]) -> String {
        var caption = ""
        var alt = ""
        var width: String?
        for (index, option) in options.enumerated() {
            if index.isMultiple(of: 128), PreviewConversion.expired { return "" }
            let value = option.wikiTrim
            let key = value.lowercased()
            if key.hasPrefix("alt=") {
                alt = String(value.dropFirst(4))
            } else if key.hasPrefix("upright") {
                let scale = Double(key.split(separator: "=").dropFirst().first ?? "") ?? 0.75
                width = String(Int(min(4096, max(1, 220 * (scale.isFinite ? scale : 1)))))
            } else if key.hasSuffix("px"),
                let n = Int(key.dropLast(2).trimmingCharacters(in: CharacterSet(charactersIn: "x"))), n > 0
            {
                width = String(min(n, 12000))
            } else if ![
                "thumb", "thumbnail", "frame", "framed", "frameless", "left", "center", "right", "none", "border",
            ].contains(key) {
                caption = inline(value)
            }
        }
        if let directory, !name.isEmpty, !name.contains("/"), !name.contains("\\"), ![".", ".."].contains(name) {
            let candidates = [
                name, name.replacingOccurrences(of: "_", with: " "), name.replacingOccurrences(of: " ", with: "_"),
            ]
            let canonical = name.replacingOccurrences(of: "_", with: " ")
            func nearby(_ file: String) -> Bool {
                let url = directory.appendingPathComponent(file)
                return url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path
                    == directory.resolvingSymlinksInPath().standardizedFileURL.path && imageExists(url)
            }
            var found = candidates.first(where: nearby)
            if found == nil, canonical.contains(" "), imageExists(directory) {
                if adjacentNames == nil {
                    var names: [String: String] = [:]
                    for file in ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
                    {
                        let key = file.replacingOccurrences(of: "_", with: " ")
                        if names[key] == nil { names[key] = file }
                    }
                    adjacentNames = names
                }
                if let equivalent = adjacentNames?[canonical], nearby(equivalent) { found = equivalent }
            }
            if let file = found {
                let size = width.map { " width=\"\($0)\"" } ?? ""
                let label = caption.isEmpty ? "" : "<figcaption>\(caption)</figcaption>"
                // Encode the whole basename as one relative path component, including any colon, hash or question mark.
                let src =
                    file.addingPercentEncoding(
                        withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))
                    ?? ""
                return "<figure><img src=\"./\(src)\" alt=\"\(HTML.escape(alt))\"\(size)>\(label)</figure>"
            }
        }
        let label = (japanese ? "画像が見つかりません: " : "Image unavailable: ") + HTML.escape(name)
        return note(label + (caption.isEmpty ? "" : " — " + caption))
    }
}
