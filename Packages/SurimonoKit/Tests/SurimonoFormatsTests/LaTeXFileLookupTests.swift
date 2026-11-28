import Foundation
import Testing

@testable import SurimonoFormats

struct LaTeXFileLookupTests {
    /// Writes the files under a fresh folder and reads `main`, recording every place the reader asked for.
    private func read(_ files: [String: String], main: String = "main.tex") throws -> (
        fragment: HTMLFragment, asked: [URL], folder: URL
    ) {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: folder) }
        for (name, text) in files {
            let url = folder.appending(path: name)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let file = folder.appending(path: main)
        let asked = AskedFiles()
        let fragment = LaTeXConverter.convert(
            try String(contentsOf: file, encoding: .utf8), documentURL: file,
            imageExists: {
                asked.add($0)
                return FileManager.default.fileExists(atPath: $0.path)
            },
            readFile: {
                asked.add($0)
                return try? Data(contentsOf: $0)
            })
        return (fragment, asked.urls, folder)
    }

    @Test("名前に点のある入力は、TeX と同じく .tex を足した名前から探す")
    func dottedInput() throws {
        let result = try read([
            "main.tex":
                #"\documentclass{article}\begin{document}\input{1.intro}\input{figures/plot.tikz}\end{document}"#,
            "1.intro.tex": "Introduction text", "figures/plot.tikz.tex": "Picture text",
        ])
        #expect(result.fragment.readingIssues.isEmpty)
        #expect(result.fragment.body.contains("Introduction text"))
        #expect(result.fragment.body.contains("Picture text"))
    }

    @Test("知らない拡張子の入力は、.tex を足した名前がなければ書いたとおりの名前を読む")
    func inputAsWritten() throws {
        let result = try read([
            "main.tex": #"\documentclass{article}\begin{document}\input{notes.txt}\end{document}"#,
            "notes.txt": "Plain notes",
        ])
        #expect(result.fragment.readingIssues.isEmpty)
        #expect(result.fragment.body.contains("Plain notes"))
    }

    @Test("include と includeonly は名前に点があっても .tex を足した同じ名前で突き合わせる")
    func dottedInclude() throws {
        let result = try read([
            "main.tex": #"""
            \documentclass{article}\includeonly{2.method}
            \begin{document}\include{1.intro}\include{2.method}\end{document}
            """#,
            "1.intro.tex": "Skipped chapter", "2.method.tex": "Method chapter",
        ])
        #expect(result.fragment.readingIssues.isEmpty)
        #expect(result.fragment.body.contains("Method chapter"))
        #expect(!result.fragment.body.contains("Skipped chapter"))
    }

    @Test("見つからない名前に点のある入力は、TeX が探す .tex つきの名前で知らせる")
    func dottedMissing() throws {
        let result = try read(["main.tex": #"\documentclass{article}\begin{document}\input{9.missing}\end{document}"#])
        #expect(result.fragment.readingIssues == ["9.missing.tex could not be read"])
        #expect(result.fragment.unreadFiles.first?.reference == "9.missing.tex")
    }

    @Test("名前に点のある文献データと画像も、BibTeX と graphicx が足す拡張子で探す")
    func dottedBibliographyAndImage() throws {
        let result = try read([
            "main.tex": #"""
            \documentclass{article}\begin{document}\cite{knuth}\includegraphics{fig_1.5}
            \bibliographystyle{plain}\bibliography{refs.v2}\end{document}
            """#,
            "refs.v2.bib": "@book{knuth, author={Donald Knuth}, title={The Book}, year={1984}}",
            "fig_1.5.png": "",
        ])
        #expect(result.fragment.readingIssues.isEmpty)
        #expect(result.fragment.body.contains("The Book"))
        #expect(result.fragment.body.contains(#"src="fig_1.5.png""#))
    }

    @Test("サブフォルダーにある主ファイルが最上位からの相対で入力を書いても、主ファイルのフォルダーの中から読む")
    func compiledFromTop() throws {
        let result = try read(
            [
                "latex/main.tex": #"""
                \documentclass{article}\begin{document}\input{latex/intro}\includegraphics{latex/figures/plot}
                \end{document}
                """#,
                "latex/intro.tex": "Introduction from the top", "latex/figures/plot.pdf": "",
            ], main: "latex/main.tex")
        #expect(result.fragment.readingIssues.isEmpty)
        #expect(result.fragment.body.contains("Introduction from the top"))
        #expect(result.fragment.body.contains(#"src="figures/plot.pdf""#))
    }

    @Test("最上位からの相対の読み替えは、主ファイルのフォルダーの外を一度も探さない")
    func staysInside() throws {
        let result = try read(
            [
                "paper/latex/main.tex": #"""
                \documentclass{article}\begin{document}\input{paper/latex/intro}\input{latex/missing}\end{document}
                """#,
                "paper/latex/intro.tex": "Found inside", "paper/intro.tex": "Outside copy",
            ], main: "paper/latex/main.tex")
        #expect(result.fragment.body.contains("Found inside"))
        let inside = result.folder.appending(path: "paper/latex").path + "/"
        #expect(result.asked.allSatisfy { $0.path.hasPrefix(inside) })
    }

    @Test("親へ上る名前は読み替えず、フォルダーの名前と合わない名前も読み替えない")
    func noRemapping() {
        let main = URL(fileURLWithPath: "/corpus/paper/latex/", isDirectory: true)
        #expect(
            LaTeXFileLookup.candidates(["../latex/a.tex"], in: [main], mainFolder: main).map(\.path) == [
                "/corpus/paper/latex/a.tex"
            ])
        #expect(
            LaTeXFileLookup.candidates(["other/a.tex"], in: [main], mainFolder: main).map(\.path) == [
                "/corpus/paper/latex/other/a.tex"
            ])
        #expect(
            LaTeXFileLookup.candidates(["paper/latex/a.tex"], in: [main], mainFolder: main).map(\.path) == [
                "/corpus/paper/latex/paper/latex/a.tex", "/corpus/paper/latex/a.tex",
            ])
    }

    @Test("ファイルでない名前は探さない")
    func notLocal() {
        for name in ["", "/etc/passwd", "~/secret", "https://example.com/a", "a\0b"] {
            #expect(LaTeXFileLookup.names(name, kind: .input) == nil)
        }
    }
}

/// The places asked for, from the converter's own thread while the test waits.
private final class AskedFiles: @unchecked Sendable {
    // Every access goes through `lock`.
    private let lock = NSLock()
    private var stored: [URL] = []

    func add(_ url: URL) { lock.withLock { stored.append(url) } }
    var urls: [URL] { lock.withLock { stored } }
}
