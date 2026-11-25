import Foundation

extension RSTDocument {
    /// The document directory is the outer boundary even when the sandbox grants a larger tree.
    /// Includes resolve relative to their own file; a web view still resolves relative to the main file.
    func rstFile(_ path: String) -> URL? {
        guard let directory, !path.isEmpty, !path.contains("\\"), !path.contains("\u{0}"),
            !path.hasPrefix("/"), !path.hasPrefix("~"), URLComponents(string: path)?.scheme == nil
        else { return nil }
        let parent = directives.includeStack.last?.deletingLastPathComponent() ?? directory
        let candidate = parent.appendingPathComponent(path)
        guard let canonical = try? ConfinedFile.canonicalPath(candidate) else {
            // The containing directory itself may still need a sandbox grant.
            _ = permitsFile(candidate)
            return nil
        }
        // Use the same path spelling as the descriptor check, including /private for macOS temporary folders.
        let file = URL(fileURLWithPath: canonical)
        let parts = file.pathComponents
        guard parts.count > directory.pathComponents.count, parts.starts(with: directory.pathComponents),
            permitsFile(file)
        else {
            return nil
        }
        return file
    }

    func rstRead(_ file: URL) -> String? {
        // Bound the aggregate, too: a small acyclic include tree may repeat the same subtree many times.
        let remaining = 5_000_000 - directives.bytesRead
        guard readsIncludes, remaining > 0, directives.readCount < 256, let directory,
            let data = try? ConfinedFile.readPermitted(
                file, within: directory.path, maximumSize: remaining, permitsOpenedFile: permitsFile)
        else { return nil }
        directives.bytesRead += data.count
        directives.readCount += 1
        return TextDecoding.decode(data).text
    }

    func rstImage(_ path: String, options: [String: String]) -> String {
        let alt = HTML.escape(options["alt"] ?? path)
        guard let file = rstFile(path.removingPercentEncoding ?? path), let directory,
            (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else {
            issueCount += 1
            return "<span>\(alt)</span>"
        }
        let src = rstRelativeURL(file, root: directory)
        var style = ""
        for key in ["width", "height"] {
            if let raw = options[key],
                raw.range(
                    of: #"^\d+(?:\.\d+)?(?:px|pt|em|ex|cm|mm|in|pc|%)?$"#,
                    options: .regularExpression) != nil
            {
                style += "\(key):\(raw)\(raw.last?.isNumber == true ? "px" : "");"
            }
        }
        if let percent = options["scale"].flatMap(Double.init), percent > 0, percent <= 10_000 {
            style += "zoom:\(percent / 100);"
        }
        let attr = style.isEmpty ? "" : " style=\"\(style)\""
        let image = "<img src=\"\(HTML.escape(src))\" alt=\"\(alt)\"\(attr)>"
        if let target = options["target"] {
            if target.hasSuffix("_"), !target.contains(":") {
                let name = String(target.dropLast()).trimmingCharacters(
                    in: CharacterSet(charactersIn: String(UnicodeScalar(96))))
                return rstNamedLink(name, label: image, source: target)
            }
            if let link = rstStaticLink(target) { return "<a href=\"\(HTML.escape(link))\">\(image)</a>" }
        }
        return image
    }

    private func rstRelativeURL(_ file: URL, root directory: URL) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return file.pathComponents.dropFirst(directory.pathComponents.count).map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }.joined(separator: "/")
    }

    func rstStaticLink(_ value: String) -> String? {
        if value.hasPrefix("#") { return value }
        guard let parts = URLComponents(string: value) else { return nil }
        if let scheme = parts.scheme?.lowercased() {
            return ["https", "http", "mailto"].contains(scheme) ? value : nil
        }
        guard parts.host == nil, let directory, let file = rstFile(parts.path) else { return nil }
        let fragment = parts.percentEncodedFragment.map { "#" + $0 } ?? ""
        return rstRelativeURL(file, root: directory) + fragment
    }
}
