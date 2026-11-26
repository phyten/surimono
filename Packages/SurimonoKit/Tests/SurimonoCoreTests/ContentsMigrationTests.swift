import Foundation
import SurimonoCore
import Testing

struct ContentsMigrationTests {
    @Test("旧目次の全モード・深さ・外観・本文併記を原稿ごとに移行し、保留時は本文と前付けを保つ")
    func migration() throws {
        let heading = "# Alpha\n\n## Bravo\n\n### Charlie"
        let cases: [(DocumentFormat, HTMLFragment, Set<PaperTOC.Mode>)] = [
            (.markdown, MarkdownConverter.convert(heading), [.source, .hidden, .front]),
            (.markdown, MarkdownConverter.convert("---\ntoc: true\n---\n" + heading), [.source]),
            (.markdown, MarkdownConverter.convert("[TOC]\n\n" + heading), [.source, .hidden]),
            (.markdown, MarkdownConverter.convert("---\ntoc: true\n---\n[TOC]\n\n" + heading), [.source]),
            (.latex, LaTeXConverter.convert(#"\section{Alpha}\tableofcontents\listoffigures\listoftables"#), [.source]),
        ]
        for (format, fragment, convertible) in cases {
            let facts = DocumentFacts(fragment: fragment)
            for mode in PaperTOC.Mode.allCases {
                for keep in [false, true] {
                    for depth in PaperTOC.Depth.allCases {
                        for look in PaperTOC.Look.allCases {
                            var finish = PrintFinish()
                            finish.toc.mode = mode
                            finish.toc.keepsSourceTOC = keep
                            finish.toc.depth = depth
                            finish.toc.look = look
                            var document = DocumentSettings(printFinish: finish)
                            #expect(
                                document.migrateContents(format: format, facts: facts) == convertible.contains(mode))
                            let saved = try #require(document.printFinish)
                            let lead = document.formatReading.leadContents(
                                for: format, file: facts.contentsInstructions)
                            if convertible.contains(mode) {
                                #expect(saved.legacyTOC == nil)
                                #expect(saved.contents.look == look)
                                #expect(saved.contents.placement == (mode == .front ? .page : .inline))
                            } else {
                                #expect(saved == finish)
                                #expect(
                                    saved.contentsBody(fragment, facts: facts, format: format, lead: lead)
                                        == fragment.body)
                                #expect(
                                    saved.styleSheet.contains("nav.toc { display: none")
                                        == (mode == .hidden || mode == .front && !keep))
                            }
                            #expect(
                                saved.frontDepth(format: format, lead: lead)
                                    == (mode == .front ? (depth == .chapters ? .levels(1) : .levels(2)) : nil))
                        }
                    }
                }
            }
        }
    }

    @Test("旧版が先頭と本文の指示を一つにまとめた原稿は、本文どおりの仕上げも最初の編集まで保つ")
    func coalescedContents() throws {
        let cases: [(DocumentFormat, HTMLFragment)] = [
            (.asciidoc, try AsciiDocConverter.convert("= Title\n:toc:\n\n== Alpha\n\ntoc::[]\n\n== Bravo")),
            (.mediawiki, MediaWikiConverter.convert("__FORCETOC__\n== Alpha ==\n__TOC__\n== Bravo ==")),
        ]
        for (format, fragment) in cases {
            let facts = DocumentFacts(fragment: fragment)
            var finish = PrintFinish()
            finish.toc.mode = .source
            var document = DocumentSettings(printFinish: finish)
            #expect(facts.coalescesContentsInLegacy)
            let automatic = document.migrateContents(format: format, facts: facts)
            #expect(!automatic)
            #expect(finish.contentsBody(fragment, facts: facts, format: format, lead: .all) == fragment.body)
            let edited = document.migrateContents(format: format, facts: facts, editing: true)
            #expect(edited)
            #expect(document.printFinish?.legacyTOC == nil)
        }
    }

    @Test("旧形式の文書・新規文書の仕上げ・設定セットを再保存しても保留中の目次を失わない")
    func oldRecords() throws {
        let old = #"{"toc":{"mode":"front","depth":"sections","look":"ruled","keepsSourceTOC":true}}"#
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let finish = try decoder.decode(PrintFinish.self, from: Data(old.utf8))
        let defaults = try decoder.decode(
            PrintFinishDefaults.self, from: Data("{\"options\":{},\"finish\":\(old)}".utf8))
        #expect(defaults.finish == finish)
        #expect(try decoder.decode(PrintFinishDefaults.self, from: encoder.encode(defaults)) == defaults)
        let settings = try decoder.decode(DocumentSettings.self, from: Data("{\"printFinish\":\(old)}".utf8))
        let set = try decoder.decode(
            PrintSettingSet.self,
            from: Data(
                """
                {"id":"878BEFBD-2A72-4A7C-8FE6-75965C52A16B","name":"old","finish":\(old)}
                """.utf8))
        #expect(settings.printFinish == finish && set.finish == finish && set.leadContents == nil)
        #expect(try decoder.decode(PrintFinish.self, from: encoder.encode(finish)) == finish)
        #expect(try decoder.decode(DocumentSettings.self, from: encoder.encode(settings)) == settings)
        #expect(try decoder.decode(PrintSettingSet.self, from: encoder.encode(set)) == set)
    }

    @Test("保留中の目次は最初の編集で一度だけ移行し、ファイルの指定と次の編集を保つ")
    func firstEdit() throws {
        let fragment = MarkdownConverter.convert("---\ntoc: true\n---\n# Alpha\n\n[TOC]")
        let facts = DocumentFacts(fragment: fragment)
        var old = PrintFinish()
        old.toc.mode = .hidden
        var saved = DocumentSettings(printFinish: old)
        let automatic = saved.migrateContents(format: .markdown, facts: facts)
        #expect(!automatic)
        let first = saved.migrateContents(format: .markdown, facts: facts, editing: true)
        #expect(first)
        saved.printFinish?.contents.inText = .asWritten
        let second = saved.migrateContents(format: .markdown, facts: facts, editing: true)
        #expect(!second)
        #expect(saved.formatReading.leadContents(for: .markdown, file: facts.contentsInstructions) == .levels(3))
        #expect(saved.printFinish?.contents.inText == .asWritten)
        let json = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: json) == saved)
    }

    @Test("深さだけを指定した原稿で、無効な選択は旧仕上げも変えず、有効な選択だけが移行する")
    func firstEditWithLockedDepth() throws {
        let manuscript = "---\ntoc-depth: 2\n---\n# Alpha\n\n## Bravo"
        let facts = DocumentFacts(fragment: ComputationalMarkdown.convert(manuscript))
        #expect(facts.contentsInstructions.present == nil && facts.contentsInstructions.depth?.value == .levels(2))
        var finish = PrintFinish()
        finish.toc.mode = .front
        var document = DocumentSettings(printFinish: finish)
        document.formatReading.set(.outline(present: true, depth: .all), for: .tableOfContents, format: .quarto)
        document.formatReading.set(.outline(present: false, depth: .all), for: .tableOfContents, format: .quarto)
        let original = document
        func choose(_ value: OrgReadingDefaults.Depth) {
            document.setLeadContents(value, format: .quarto, facts: facts, defaults: .init(), orgDefaults: .surimono)
        }
        choose(.levels(1))
        #expect(document == original)
        choose(.levels(2))
        #expect(document.printFinish?.legacyTOC == nil && document.printFinish?.contents.placement == .page)
        #expect(document.formatReading.leadContents(for: .quarto, file: facts.contentsInstructions) == .levels(2))
        #expect(document.formatReading.leadContents(for: .quarto) == .all)
        choose(.off)
        #expect(document.formatReading == original.formatReading)
        // A first edit that switches off directly must not seed the former front-page depth into the document.
        document = original
        choose(.off)
        #expect(document.printFinish?.legacyTOC == nil && document.formatReading == original.formatReading)
    }

    @Test("自動移行後に保存し直しても新規文書には元の仕上げを渡し、明示した目次の選択は文書だけに残す")
    func portableFinish() throws {
        let facts = DocumentFacts(fragment: MarkdownConverter.convert("# Alpha\n\n# Bravo"))
        for mode in PaperTOC.Mode.allCases {
            var old = PrintFinish()
            old.toc.mode = mode
            old.toc.depth = .sections
            old.toc.look = .ruled
            old.toc.keepsSourceTOC = true
            var document = DocumentSettings(printFinish: old)
            let migrated = document.migrateContents(format: .markdown, facts: facts)
            #expect(migrated)
            let restored = try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(document))
            #expect(restored == document)
            #expect(restored.printFinish?.legacyTOC == nil && restored.printFinish?.forNewDocuments == old)
            document.setLeadContents(.all, format: .markdown, facts: facts, defaults: .init(), orgDefaults: .surimono)
            #expect(document.printFinish?.forNewDocuments.legacyTOC == nil)
        }
    }

    @Test("先頭の目次と独立ページは三段目以降も選んだ深さまで掲載する")
    func deepContents() {
        let fragment = MarkdownConverter.convert("# A\n\n# B\n\n## C\n\n### D\n\n#### E")
        let facts = DocumentFacts(fragment: fragment)
        let finish = PrintFinish()
        for (depth, entries): (ReadingDepth, [String]) in [
            (.levels(3), ["A", "B", "C", "D"]), (.all, ["A", "B", "C", "D", "E"]),
        ] {
            let body = finish.contentsBody(fragment, facts: facts, format: .markdown, lead: depth)
            #expect(DocumentOutline.sourceContentsEntries(inHTML: body) == entries)
            #expect(
                PaperContents.entries(headings: facts.headings, pageNumbers: [], depth: depth).map(\.text) == entries)
        }
    }

    @Test("ファイルが出現と深さを別々に指定し、深さを読める形式だけ文書の深さを使う")
    func nativeDepth() throws {
        let headings = "# A\n\n## B\n\n### C"
        let qmd = "---\ntoc: true\n---\n" + headings
        let rst = ".. contents::\n\nA\n====\n\nB\n----\n\nC\n~~~~"
        let adoc = "= Title\n:toc:\n\n== A\n\n=== B\n\n==== C"
        let cases: [(DocumentFormat, HTMLFragment, Bool)] = [
            (.markdown, MarkdownConverter.convert(qmd), true),
            (.quarto, ComputationalMarkdown.convert(qmd, contentsDepth: 1), false),
            (.rst, RSTConverter.convert(rst, contentsDepth: 1), false),
            (.asciidoc, try AsciiDocConverter.convert(adoc, contentsDepth: 1), false),
        ]
        for (format, fragment, fixedDepth) in cases {
            let file = fragment.contentsInstructions
            guard
                case .outline(let present, let depth) = FormatReadingChoices().resolve(
                    .tableOfContents, for: format, file: file)
            else {
                Issue.record("目次の読み方がない")
                continue
            }
            #expect(present.value && present.isLocked)
            #expect(depth.isLocked == fixedDepth)
            let entries = DocumentOutline.sourceContentsEntries(inHTML: fragment.body)
            if !fixedDepth { #expect(entries == ["A"], "\(format)") }
        }
        let explicit = [
            ComputationalMarkdown.convert(
                qmd.replacingOccurrences(of: "toc: true", with: "toc: true\ntoc-depth: 2"), contentsDepth: 1),
            RSTConverter.convert(
                rst.replacingOccurrences(of: ".. contents::", with: ".. contents::\n   :depth: 2"), contentsDepth: 1),
            try AsciiDocConverter.convert(
                adoc.replacingOccurrences(of: ":toc:", with: ":toc:\n:toclevels: 2"), contentsDepth: 1),
        ]
        for fragment in explicit {
            #expect(fragment.contentsInstructions.depth?.value == .levels(2))
            #expect(DocumentOutline.sourceContentsEntries(inHTML: fragment.body) == ["A", "B"])
        }
        let disabled = [
            MarkdownConverter.convert("---\ntoc: false\n---\n" + headings),
            ComputationalMarkdown.convert("---\ntoc: false\n---\n" + headings),
            try AsciiDocConverter.convert(adoc.replacingOccurrences(of: ":toc:", with: ":toc!:")),
            MediaWikiConverter.convert("__NOTOC__\n== A =="),
        ]
        for fragment in disabled { #expect(fragment.contentsInstructions.present?.value == false) }
    }

    @Test("既存の識別子を保ち、識別子のない見出しにも先頭の目次から移動できる")
    func generatedAnchors() {
        let fragment = HTMLFragment(body: "<p id=\"surimono-heading-1\"></p><h1>A &amp; B</h1><h1 id=\"b\">B</h1>")
        let html = PrintFinish().contentsBody(
            fragment, facts: DocumentFacts(fragment: fragment), format: .docx, lead: .all)
        #expect(
            html.contains("href=\"#surimono-heading-2\"") && html.contains("<h1 id=\"surimono-heading-2\">A &amp; B"))
        #expect(html.contains("href=\"#b\""))
    }

    @Test("LaTeXの目次・図目次・表目次は原稿にあるものだけを個別に表示する")
    func latexLists() {
        let fragment = LaTeXConverter.convert(#"\section{Alpha}\tableofcontents\listoffigures\listoftables"#)
        let facts = DocumentFacts(fragment: fragment)
        #expect(facts.contentsKinds == [.contents, .figures, .tables])
        for contents in [false, true] {
            for figures in [false, true] {
                for tables in [false, true] {
                    var finish = PrintFinish()
                    finish.contents.showsContents = contents
                    finish.contents.showsFigures = figures
                    finish.contents.showsTables = tables
                    let body = finish.contentsBody(fragment, facts: facts, format: .latex, lead: nil)
                    #expect(body.contains(">Contents<") == contents)
                    #expect(body.contains(">List of Figures<") == figures)
                    #expect(body.contains(">List of Tables<") == tables)
                }
            }
        }
        #expect(DocumentFacts(fragment: LaTeXConverter.convert(#"\listoffigures"#)).contentsKinds == [.figures])
    }
}
