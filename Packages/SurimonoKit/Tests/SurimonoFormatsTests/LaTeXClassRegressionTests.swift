import CryptoKit
import Foundation
import LaTeXCorpusSupport
import Synchronization
import Testing

@testable import SurimonoFormats

struct LaTeXClassRegressionTests {
    @Test("同梱の LaTeX 全件の HTML が高速化前のバイト列と一致する")
    func referenceHTML() throws {
        // SHA-256 of the UTF-8 fragment with a fixed font index at 0322c061.
        let digests = [
            "additive.tex": "502796adcc4f3514cb3e6b7d057fe8a8a3537ddfc34e061a819cb4b1589e44a1",
            "handout.tex": "247018f1fd8304f59fa6a5dea84e18b1620ab10b7eafdd0b6dfd010579f06fad",
            "overflow.tex": "da54f24ff3a251b833c48616a8da020e34c9c864e0053d311df2816055547e32",
            "specimen.tex": "17c9076cf2c197f8a5df14a14f922f8abd56a9e4fd7d14b6ab64b22c88180c18",
            "swap.tex": "23094a4fb930fdf762263ede0ade3077392abb342626719043ff3d0e2c1f457c",
            "column-notes.tex": "23b2004d695b1015a1131a14c8ee4ecc624c6c3c084eae28a3705a128bafffcf",
            "conference-links.tex": "8d4e5f0b80983d014d1cf8839122f5e5a5b17c0c278b3718f56f5647e76461a1",
            "math-outlines.tex": "0bf0a9b20bd2b8e3b95f66fec9c1590331eaec7d6119ed6bf74228c2b7536df5",
            "sample.tex": "276b3f71119fe38593da9da5c27e92fb321c5d76e2ba58af8ac21a8ed90b3843",
        ]
        let files = try LaTeXClassInputs.corpus()
        #expect(Set(files.map { $0.1.lastPathComponent }) == Set(digests.keys))
        for (path, file) in files {
            let source = TextDecoding.decode(try Data(contentsOf: file)).text
            let html = LaTeXConverter.convert(
                source, fontIndex: .init(faces: [:]), documentURL: file, readFile: { try? Data(contentsOf: $0) }
            ).body
            let digest = SHA256.hash(data: Data(html.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == digests[file.lastPathComponent], "\(path)")
        }
    }

    @Test("数式用の定義は2498個目まで使え、予算を超えた定義は組まずに知らせる")
    func definitionBudget() {
        let within = LaTeXConverter.convert(LaTeXClassInputs.macroDocument(2498))
        #expect(within.readingIssues.isEmpty)
        #expect(within.body.contains(">7</text>"))
        for count in [2499, 4000] {
            let fragment = LaTeXConverter.convert(LaTeXClassInputs.macroDocument(count))
            let formula = "$" + LaTeXClassInputs.macroName(count - 1) + "$"
            #expect(fragment.readingIssues.contains("LaTeX expansion limit reached"))
            #expect(fragment.body.contains("<code class=\"math-error\">" + formula + "</code>"))
        }
    }

    @Test("制御記号の定義を繰り返しても最後の定義で数式を組み、作業予算は守る")
    func uncommonDefinitions() {
        let source = LaTeXClassInputs.uncommonDefinitions(64)
        let fragment = LaTeXConverter.convert(source)
        #expect(LaTeXConverter.documentClassInfo(source).hasChapters)
        #expect(fragment.latexClass?.hasChapters == true)
        #expect(fragment.readingIssues.isEmpty)
        #expect(fragment.body.contains(">7</text>"))

        StackSpace.onLargeStack {
            let document = LaTeXDocument(fontIndex: .init(faces: [:]))
            let reader = LaTeXReader("", document: document, isBlock: false)
            reader.addMathDefinition(#"\def\!{7}"#)
            #expect(!document.mathDefinitions.containsOnlyPrimitiveDefinitions)
            let accepted = document.mathDefinitions.source
            document.expansionWork = 50_000_000 - 1
            reader.addMathDefinition(#"\def\!{9}"#)
            #expect(document.mathDefinitions.source == accepted)
            #expect(document.readingIssues.contains("LaTeX expansion limit reached"))
        }
    }

    @Test("前文の入力は20段目のクラスを採用し、21段目を開く前に打ち切る", arguments: [20, 21])
    func inputDepth(total: Int) {
        let root = URL(fileURLWithPath: "/fixture/main.tex")
        let source = #"\input{child1}\begin{document}x\end{document}"#
        let files = Dictionary(
            uniqueKeysWithValues: (1...total).map {
                ("child\($0).tex", Data(LaTeXClassInputs.child($0, total: total).utf8))
            })
        let reads = Mutex<[String]>([])
        @Sendable func read(_ url: URL) -> Data? {
            reads.withLock { $0.append(url.lastPathComponent) }
            return files[url.lastPathComponent]
        }
        let allowed = (1...20).map { "child\($0).tex" }
        let info = LaTeXConverter.documentClassInfo(source, documentURL: root, readFile: read)
        #expect(info.hasChapters)
        #expect(reads.withLock { $0 } == allowed)
        reads.withLock { $0.removeAll() }
        let fragment = LaTeXConverter.convert(source, documentURL: root, readFile: read)
        #expect(fragment.latexClass?.hasChapters == true)
        #expect(reads.withLock { $0 } == allowed)
        #expect(fragment.readingIssues == (total == 20 ? [] : ["child21.tex could not be read"]))
    }

    @Test("長い横向き環境の末尾まで確かめ、通常本文が続くときだけ縦向きにする")
    func wholeLandscape() {
        for tail in ["", "Narrow"] {
            let source = LaTeXClassInputs.landscape(
                body: String(repeating: "x", count: 8192) + #"\input{figure}"#, tail: tail)
            let file = URL(fileURLWithPath: "/fixture/main.tex")
            let reads = Mutex<[String]>([])
            @Sendable func read(_ url: URL) -> Data? {
                reads.withLock { $0.append(url.lastPathComponent) }
                return Data("Figure".utf8)
            }
            let info = LaTeXConverter.documentClassInfo(source, documentURL: file, readFile: read)
            #expect(reads.withLock { $0.isEmpty })
            #expect((info.pageBox.paperWidth > info.pageBox.paperHeight) == tail.isEmpty)
            let fragment = LaTeXConverter.convert(source, documentURL: file, readFile: read)
            #expect(reads.withLock { $0 } == ["figure.tex"])
            #expect(fragment.body.contains("Figure"))
            #expect(fragment.latexClass?.pageBox == info.pageBox)
            #expect(fragment.readingIssues.isEmpty)
        }
    }
}
