import Foundation

package enum LaTeXClassInputs {
    private static func texFiles(in directory: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "tex" }.sorted { $0.path < $1.path }
    }

    package static func corpus(includingSnapshots: Bool = false) throws -> [(String, URL)] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let samples = try texFiles(in: root.appendingPathComponent("Samples"))
        let fixtures = try texFiles(in: root.appendingPathComponent("Packages/SurimonoKit/Tests"))
            .filter { $0.pathComponents.contains("Fixtures") }
        var files = samples + fixtures
        if includingSnapshots {
            files += try texFiles(in: root.appendingPathComponent("Snapshots/corpus/latex"))
                .filter { $0.lastPathComponent == "main.tex" }
        }
        return files.map { (String($0.path.dropFirst(root.path.count + 1)), $0) }
    }

    package static func generated(in directory: URL) throws -> [(String, URL)] {
        func write(_ name: String, _ contents: String) throws -> URL {
            let url = directory.appendingPathComponent(name + ".tex")
            try Data(contents.utf8).write(to: url)
            return url
        }
        let begin = "\\begin{document}\n"
        let end = "\n\\end{document}\n"
        let article = "\\documentclass{article}\n"
        let short = try write("short", article + begin + "x" + end)
        let large = try write("body", article + begin + String(repeating: "x", count: 5_000_000) + end)
        let macros = try write("macros", article + definitions(2000) + begin + "x" + end)
        for depth in 1...50 {
            let next = depth == 50 ? "" : "\\input{child\(depth + 1)}\n"
            let padding = String(repeating: "x", count: 20_000 - next.utf8.count - 2)
            _ = try write("child\(depth)", "%" + padding + "\n" + next)
        }
        let nested = try write("nested", article + "\\input{child1}\n" + begin + "x" + end)
        let deepFolder = directory.appending(path: "depth20", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: deepFolder, withIntermediateDirectories: true)
        for depth in 1...20 {
            try Data(child(depth, total: 20).utf8).write(to: deepFolder.appending(path: "child\(depth).tex"))
        }
        let deep = deepFolder.appending(path: "main.tex")
        try Data((article + "\\input{child1}\n" + begin + "x" + end).utf8).write(to: deep)
        let uncommon = try write("uncommon", uncommonDefinitions(1000))
        let wide = try write("landscape", landscape(body: String(repeating: "x", count: 5_000_000)))
        let block = #"""
            \setcounter{n}{0}
            \loop\stepcounter{n}\stepcounter{total}\ifnum\value{n}<3 \repeat
            \foreach \i in {a,b,c}{\ifx\same\same\stepcounter{total}\fi}

            """#
        let loops = try write(
            "loops",
            #"\newcounter{n}\newcounter{total}\def\same{x}"# + "\n" + String(repeating: block, count: 100)
                + #"\ifnum\value{total}=600 \documentclass{beamer}\else\documentclass{article}\fi"# + "\n"
                + begin + "x" + end)
        return [
            ("short", short), ("macros", macros), ("nested", nested), ("loops", loops), ("body", large),
            ("uncommon", uncommon), ("depth20", deep), ("landscape", wide),
        ]
    }

    package static func macroName(_ index: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return "\\bench" + String([letters[index / 676], letters[index / 26 % 26], letters[index % 26]])
    }

    private static func definitions(_ count: Int, lastValue: String = "x") -> String {
        (0..<count).map { "\\newcommand{\(macroName($0))}{\($0 == count - 1 ? lastValue : "x")}\n" }.joined()
    }

    package static func macroDocument(_ count: Int) -> String {
        "\\documentclass{article}\n" + definitions(count, lastValue: "7")
            + "\\begin{document}$\(macroName(count - 1))$\\end{document}"
    }

    package static func uncommonDefinitions(_ count: Int) -> String {
        let definitions = (0..<count).map { "\\def\\!{\($0 == count - 1 ? "7" : String($0 % 2))}\n" }.joined()
        return definitions + #"\documentclass{book}\begin{document}$\!$\end{document}"#
    }

    package static func child(_ depth: Int, total: Int) -> String {
        var text = ""
        if depth == 20 { text += "\\documentclass{book}\n" }
        if depth == 21 { text += "\\documentclass{letter}\n" }
        if depth < total { text += "\\input{child\(depth + 1)}\n" }
        return text
    }

    package static func landscape(body: String, tail: String = "") -> String {
        #"\documentclass{article}\begin{document}\begin{landscape}"# + body
            + #"\end{landscape}"# + tail + #"\end{document}"#
    }
}
