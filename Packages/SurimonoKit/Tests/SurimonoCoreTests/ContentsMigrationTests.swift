import Foundation
import SurimonoCore
import Testing

struct ContentsMigrationTests {
    private func readingFacts(for format: DocumentFormat) -> DocumentFacts {
        if format == .rst {
            return DocumentFacts(fragment: RSTConverter.convert(".. sectnum::\n\n.. contents::\n\nA\n==="))
        }
        if format == .mediawiki { return DocumentFacts(fragment: MediaWikiConverter.convert("__FORCETOC__\n== A ==")) }
        let header =
            format == .rMarkdown
            ? "output:\n  pdf_document:\n    toc: true\n    number_sections: true"
            : "toc: true\nnumber-sections: true"
        let source = "---\n" + header + "\n---\n# A"
        return DocumentFacts(
            fragment: format == .markdown
                ? MarkdownConverter.convert(source)
                : ComputationalMarkdown.convert(source, format: format))
    }

    @Test("読めない出力形式で固定を戻しても文書の番号と目次は残る", arguments: [DocumentFormat.quarto, .rMarkdown])
    func malformedOutputKeepsChoices(format: DocumentFormat) {
        let header =
            format == .quarto
            ? "format:\n  html:\n      toc: true\n    number-sections: true"
            : "output:\n  - html_document:\n      toc: true\n      number_sections: true"
        let facts = DocumentFacts(
            fragment: ComputationalMarkdown.convert("---\n" + header + "\n---\n# A", format: format))
        var document = DocumentSettings()
        document.formatReading.set(.outline(present: true, depth: .levels(2)), for: .tableOfContents, format: format)
        document.formatReading.set(
            format == .quarto ? .outline(present: false, depth: .all) : .toggle(false), for: .sectionNumbers,
            format: format)
        let expected = document
        document.formatReading.setAllowsFileChanges(true, for: format)
        #expect(
            document.lockReadingFileInstructions(for: format, facts: facts, generation: 1, defaults: .init())
                == .finished)
        #expect(document == expected)
    }

    @Test(
        "読めない rST と Wiki の指定で固定を戻しても他形式を含む保存値が残る",
        arguments: [DocumentFormat.rst, .mediawiki])
    func ambiguousManuscriptKeepsChoices(format: DocumentFormat) {
        let fragment =
            format == .rst
            ? RSTConverter.convert(".. sectnum::\n   :depth: 0\n\n.. contents::\n   :unknown: yes\n\nA\n===")
            : MediaWikiConverter.convert("{{nowrap|__FORCETOC__}}\n== A ==")
        var document = DocumentSettings()
        let formats: [DocumentFormat] = [.markdown, .quarto, .rMarkdown, .rst, .mediawiki]
        let facts = DocumentFacts(fragment: fragment)
        for (index, other) in formats.enumerated() {
            document.formatReading.set(
                .outline(present: true, depth: .levels(index + 1)), for: .tableOfContents, format: other)
            document.formatReading.set(
                other == .rMarkdown ? .toggle(false) : .outline(present: false, depth: .all), for: .sectionNumbers,
                format: other)
        }
        let expected = document
        document.formatReading.setAllowsFileChanges(true, for: format)
        #expect(
            document.lockReadingFileInstructions(for: format, facts: facts, generation: 1, defaults: .init())
                == .finished)
        #expect(document == expected)
    }

    @Test("五形式の読み手は同じ設定から自分の形式の目次だけを選ぶ")
    func separateReaderSettings() throws {
        let formats: [DocumentFormat] = [.markdown, .quarto, .rMarkdown, .rst, .mediawiki]
        for selected in formats {
            var reading = FormatReadingSettings()
            reading.defaults.set(.outline(present: true, depth: .levels(1)), for: .tableOfContents, format: selected)
            for format in formats {
                let fragment: HTMLFragment
                switch format {
                case .markdown: fragment = MarkdownConverter.convert("# A\n\n# B", reading: reading)
                case .rst: fragment = RSTConverter.convert("One\n===\n\nTwo\n===", reading: reading)
                case .mediawiki: fragment = MediaWikiConverter.convert("== A ==\n== B ==", reading: reading)
                default: fragment = ComputationalMarkdown.convert("# A\n\n# B", format: format, reading: reading)
                }
                #expect(
                    fragment.contentsKinds.values.contains(.lead) == (format == selected), "\(selected) → \(format)")
            }
        }
    }

    @Test(
        "固定を戻す確認は承認まで保存せず、設定・原稿世代の変化で古い承認を無効にする",
        arguments: [DocumentFormat.markdown, .quarto, .rMarkdown, .rst, .mediawiki])
    func readingLockConfirmation(format: DocumentFormat) throws {
        let facts = readingFacts(for: format)
        var document = DocumentSettings()
        document.formatReading.setAllowsFileChanges(true, for: format)
        document.formatReading.set(
            .outline(present: false, depth: .all), for: .tableOfContents, format: format,
            file: facts.contentsInstructions)
        func proposal(_ result: ReadingFileLockResult) throws -> ReadingDiscardConfirmation {
            let value: ReadingDiscardConfirmation? =
                if case .needsConfirmation(let pending) = result { pending } else { nil }
            return try #require(value)
        }
        let original = document
        let canceled = try proposal(
            document.lockReadingFileInstructions(for: format, facts: facts, generation: 1, defaults: .init()))
        #expect(canceled.count == 1 && document == original)
        // Cancel simply drops the proposal. Asking again must leave exactly the same settings.
        let again = try proposal(
            document.lockReadingFileInstructions(for: format, facts: facts, generation: 1, defaults: .init()))
        #expect(again == canceled && document == original)
        document.formatReading.set(
            .outline(present: true, depth: .levels(1)), for: .tableOfContents, format: format,
            file: facts.contentsInstructions)
        document.formatReading.set(
            .outline(present: false, depth: .levels(1)), for: .tableOfContents, format: format,
            file: facts.contentsInstructions)
        let changed = document
        let revised = try proposal(
            document.lockReadingFileInstructions(
                for: format, facts: facts, generation: 1, defaults: .init(), confirming: again))
        #expect(revised != again && document == changed)
        #expect(
            document.lockReadingFileInstructions(
                for: format, facts: nil, generation: 2, defaults: .init(), confirming: revised)
                == .awaitingInstructions)
        let reloaded = try proposal(
            document.lockReadingFileInstructions(
                for: format, facts: facts, generation: 2, defaults: .init(), confirming: revised))
        #expect(reloaded != revised && document == changed)
        var defaults = FormatReadingChoices()
        defaults.set(.outline(present: true, depth: .levels(2)), for: .tableOfContents, format: format)
        let current = try proposal(
            document.lockReadingFileInstructions(
                for: format, facts: facts, generation: 2, defaults: defaults, confirming: reloaded)
        )
        #expect(current != reloaded && document == changed)
        #expect(
            document.lockReadingFileInstructions(
                for: format, facts: facts, generation: 2, defaults: defaults, confirming: current)
                == .finished)
        var expected = FormatReadingChoices()
        expected.set(
            .outline(present: true, depth: .levels(1)), for: .tableOfContents, format: format,
            file: facts.contentsInstructions)
        #expect(document.formatReading == expected)
    }

    @Test("別形式の承認では固定を戻せず、承認した形式の変更だけが消える")
    func confirmationBelongsToFormat() throws {
        var document = DocumentSettings()
        let formats: [DocumentFormat] = [.rst, .mediawiki]
        for format in formats {
            document.formatReading.setAllowsFileChanges(true, for: format)
            document.formatReading.set(
                .outline(present: false, depth: .all), for: .tableOfContents,
                format: format, file: readingFacts(for: format).contentsInstructions)
        }
        let original = document
        func ask(_ format: DocumentFormat, confirming: ReadingDiscardConfirmation? = nil) -> ReadingFileLockResult {
            document.lockReadingFileInstructions(
                for: format, facts: readingFacts(for: format), generation: 3,
                defaults: .init(), confirming: confirming)
        }
        guard case .needsConfirmation(let rst) = ask(.rst),
            case .needsConfirmation(let wiki) = ask(.mediawiki, confirming: rst)
        else {
            Issue.record("形式ごとの承認が必要")
            return
        }
        #expect(document == original && rst != wiki)
        #expect(ask(.mediawiki, confirming: wiki) == .finished)
        #expect(document.formatReading.restricted(to: [.rst]) == original.formatReading.restricted(to: [.rst]))
        #expect(document.formatReading.restricted(to: [.mediawiki]).isEmpty)
        // Completing the Wiki confirmation must not invalidate the pending rST confirmation.
        #expect(ask(.rst, confirming: rst) == .finished)
        #expect(document.formatReading.isEmpty)
    }

    @Test("確認の間に破棄するものがなくなったら、古い承認のままでも固定を戻す", arguments: [false, true])
    func readingLockAfterNothingLeft(instructionRemoved: Bool) throws {
        let facts = DocumentFacts(fragment: MarkdownConverter.convert("---\ntoc: true\n---\n# A"))
        var document = DocumentSettings()
        document.formatReading.setAllowsFileChanges(true, for: .markdown)
        document.formatReading.set(
            .outline(present: false, depth: .all), for: .tableOfContents, format: .markdown,
            file: facts.contentsInstructions)
        document.formatReading.set(.toggle(true), for: .preserveBreaks, format: .markdown)
        guard
            case .needsConfirmation(let pending) = document.lockReadingFileInstructions(
                for: .markdown, facts: facts, generation: 1, defaults: .init())
        else {
            Issue.record("The first request asks before discarding")
            return
        }
        var later = facts
        if instructionRemoved {
            later = DocumentFacts(fragment: MarkdownConverter.convert("# A"))
        } else {
            document.formatReading.revert(.tableOfContents, for: .markdown)
        }
        var expected = document.formatReading
        expected.setAllowsFileChanges(false, for: .markdown)
        #expect(
            document.lockReadingFileInstructions(
                for: .markdown, facts: later, generation: 2, defaults: .init(), confirming: pending)
                == .finished)
        // Only the permission goes: the remaining choices no longer contradict the file.
        #expect(document.formatReading == expected)
        #expect(!document.formatReading.allowsFileChanges(for: .markdown))
    }

    @Test(
        "固定を戻すと原稿が指定した成分だけを消し、旧仕上げから移した深さか文書で選んだ深さを保つ",
        arguments: [DocumentFormat.markdown, .quarto, .rMarkdown, .rst, .mediawiki], [false, true])
    func readingLockMigratesContents(format: DocumentFormat, editedDepth: Bool) throws {
        let facts = readingFacts(for: format)
        var finish = PrintFinish()
        finish.legacyPresetContents.mode = .front
        finish.legacyPresetContents.depth = .sections
        var document = DocumentSettings(printFinish: finish)
        document.formatReading.setAllowsFileChanges(true, for: format)
        if editedDepth {
            document.formatReading.set(
                .outline(present: true, depth: .levels(4)), for: .tableOfContents, format: format,
                file: facts.contentsInstructions)
        }
        let off = ReadingSettingValue.outline(present: false, depth: .all)
        document.formatReading.set(off, for: .tableOfContents, format: format, file: facts.contentsInstructions)
        document.formatReading.set(
            format == .rMarkdown ? .toggle(false) : off, for: .sectionNumbers, format: format,
            file: facts.numberInstructions)
        document.formatReading.set(.toggle(true), for: .preserveBreaks, format: .markdown)
        let original = document
        let result = document.lockReadingFileInstructions(for: format, facts: facts, generation: 1, defaults: .init())
        guard case .needsConfirmation(let approval) = result else {
            Issue.record("原稿の指定に戻す確認がない")
            return
        }
        #expect(approval.count == (format == .mediawiki ? 1 : 2) && document == original)
        #expect(
            document.lockReadingFileInstructions(
                for: format, facts: facts, generation: 1, defaults: .init(), confirming: approval)
                == .finished)
        #expect(!document.formatReading.allowsFileChanges(for: format))
        #expect(document.printFinish?.legacyTOC == nil && document.printFinish?.contents.placement == .page)
        var expected = FormatReadingChoices()
        expected.set(
            .outline(present: true, depth: .levels(editedDepth ? 4 : 2)), for: .tableOfContents,
            format: format, file: facts.contentsInstructions)
        expected.set(.toggle(true), for: .preserveBreaks, format: .markdown)
        #expect(document.formatReading == expected)
    }

    @Test("旧目次の全モード・深さ・外観・本文併記を原稿ごとに移行し、保留時は本文と前付けを保つ")
    func migration() throws {
        let heading = "# Alpha\n\n## Bravo\n\n### Charlie"
        let cases: [(DocumentFormat, HTMLFragment, Set<PaperTOC.Mode>)] = [
            (.markdown, MarkdownConverter.convert(heading), [.source, .hidden, .front]),
            (.markdown, MarkdownConverter.convert("---\ntoc: true\n---\n" + heading), [.source]),
            (.markdown, MarkdownConverter.convert("[TOC]\n\n" + heading), [.source, .hidden]),
            (.markdown, MarkdownConverter.convert("---\ntoc: true\n---\n[TOC]\n\n" + heading), [.source]),
            (.rst, RSTConverter.convert("A\n===\n\n.. contents:: Here\n\nB\n===\n"), [.source, .hidden]),
            (.latex, LaTeXConverter.convert(#"\section{Alpha}\tableofcontents\listoffigures\listoftables"#), [.source]),
        ]
        for (format, fragment, convertible) in cases {
            let facts = DocumentFacts(fragment: fragment)
            for mode in PaperTOC.Mode.allCases {
                for keep in [false, true] {
                    for depth in PaperTOC.Depth.allCases {
                        for look in PaperTOC.Look.allCases {
                            var finish = PrintFinish()
                            finish.legacyPresetContents.mode = mode
                            finish.legacyPresetContents.keepsSourceTOC = keep
                            finish.legacyPresetContents.depth = depth
                            finish.legacyPresetContents.look = look
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
            finish.legacyPresetContents.mode = .source
            var document = DocumentSettings(printFinish: finish)
            #expect(facts.coalescesContentsInLegacy)
            let automatic = document.migrateContents(format: format, facts: facts)
            #expect(!automatic)
            #expect(finish.contentsBody(fragment, facts: facts, format: format, lead: .all) == fragment.body)
            let edited = document.migrateContents(format: format, facts: facts, editing: .lead)
            #expect(edited)
            #expect(document.printFinish?.legacyTOC == nil)
        }
    }

    @Test("旧版の目次は仕上げや別形式の編集で移行せず、rST の先頭目次を戻すと移行する", arguments: ["toc", "migratedTOC"])
    func rstLeadMigration(record: String) throws {
        let json = "{\"\(record)\":{\"mode\":\"hidden\"}}"
        let finish = try JSONDecoder().decode(PrintFinish.self, from: Data(json.utf8))
        var document = DocumentSettings(printFinish: finish)
        let facts = DocumentFacts(fragment: RSTConverter.convert(".. contents:: Map\n\nOne\n===\n\nTwo\n==="))
        _ = document.migrateContents(format: .rst, facts: facts, editing: .finish)
        document.printFinish?.contents.inText = .asWritten
        document = try JSONDecoder().decode(DocumentSettings.self, from: JSONEncoder().encode(document))
        document.printFinish?.contents.inText = .hidden
        document.setLeadContents(.levels(1), format: .markdown, facts: nil, defaults: .init(), orgDefaults: .surimono)
        #expect(document.printFinish?.keepsRSTLeadInText == true)
        let adopted = document.migrateContents(format: .rst, facts: facts, editing: .lead)
        #expect(adopted && document.printFinish?.keepsRSTLeadInText == false)
        #expect(document.printFinish?.contents.inText == .hidden)
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
        old.legacyPresetContents.mode = .hidden
        var saved = DocumentSettings(printFinish: old)
        let automatic = saved.migrateContents(format: .markdown, facts: facts)
        #expect(!automatic)
        let first = saved.migrateContents(format: .markdown, facts: facts, editing: .lead)
        #expect(first)
        saved.printFinish?.contents.inText = .asWritten
        let second = saved.migrateContents(format: .markdown, facts: facts, editing: .lead)
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
        finish.legacyPresetContents.mode = .front
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
            old.legacyPresetContents.mode = mode
            old.legacyPresetContents.depth = .sections
            old.legacyPresetContents.look = .ruled
            old.legacyPresetContents.keepsSourceTOC = true
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
        let adoc = "= Title\n:toc:\n\n== A\n\n=== B\n\n==== C"
        let wiki = "__FORCETOC__\n== A ==\n=== B ===\n==== C ===="
        let cases: [(DocumentFormat, HTMLFragment, [String])] = [
            (.markdown, MarkdownConverter.convert(qmd, contentsDepth: 1), ["B"]),
            (.mediawiki, MediaWikiConverter.convert(wiki, contentsDepth: 1), ["B"]),
            (.quarto, ComputationalMarkdown.convert(qmd, contentsDepth: 1), ["A"]),
            (.asciidoc, try AsciiDocConverter.convert(adoc, contentsDepth: 1), ["A"]),
        ]
        for (format, fragment, expected) in cases {
            let file = fragment.contentsInstructions
            var choices = FormatReadingChoices()
            choices.set(.outline(present: true, depth: .levels(1)), for: .tableOfContents, format: format, file: file)
            let row = try #require(choices.resolve(.tableOfContents, for: format, file: file))
            #expect(!row.allowsOutline(present: false, depth: .all))
            #expect(row.allowsOutline(present: true, depth: .all))
            #expect(choices.leadContents(for: format, file: file) == .levels(1))
            #expect(DocumentOutline.sourceContentsEntries(inHTML: fragment.body) == expected, "\(format)")
        }
        for enabled in [false, true] {
            let header = enabled ? "toc: true\n" : ""
            let fragment = ComputationalMarkdown.convert("---\n" + header + "toc-depth: 2\n---\n" + headings)
            let file = fragment.contentsInstructions
            guard
                case .outline(let presence, let depth) = FormatReadingChoices().resolve(
                    .tableOfContents, for: .quarto, file: file)
            else {
                Issue.record("目次の読み方がない")
                return
            }
            #expect(presence.isLocked == enabled && depth.isLocked && depth.value == .levels(2))
        }
        let explicit = try AsciiDocConverter.convert(
            adoc.replacingOccurrences(of: ":toc:", with: ":toc:\n:toclevels: 2"), contentsDepth: 1)
        #expect(explicit.contentsInstructions.depth?.value == .levels(2))
        #expect(DocumentOutline.sourceContentsEntries(inHTML: explicit.body) == ["A", "B"])
        let disabled = [
            MarkdownConverter.convert("---\ntoc: false\n---\n" + headings),
            ComputationalMarkdown.convert("---\ntoc: false\n---\n" + headings),
            try AsciiDocConverter.convert(adoc.replacingOccurrences(of: ":toc:", with: ":toc!:")),
            MediaWikiConverter.convert("__NOTOC__\n== A =="),
        ]
        for fragment in disabled { #expect(fragment.contentsInstructions.present?.value == false) }
    }

    @Test("有無だけ指定した旧原稿は深さ三を復元し、移行後の変更では深さだけを書ける")
    func migratedNativeDepth() {
        for (format, fragment) in [
            (DocumentFormat.markdown, MarkdownConverter.convert("---\ntoc: true\n---\n# A")),
            (.mediawiki, MediaWikiConverter.convert("__FORCETOC__\n== A ==")),
        ] {
            var defaults = FormatReadingChoices()
            defaults.set(.outline(present: true, depth: .all), for: .tableOfContents, format: format)
            var document = DocumentSettings(printFinish: .manuscriptContents)
            let facts = DocumentFacts(fragment: fragment)
            let migrated = document.migrateContents(format: format, facts: facts, defaults: defaults)
            #expect(migrated)
            #expect(
                document.formatReading.leadContents(for: format, file: facts.contentsInstructions, defaults: defaults)
                    == .levels(3))
            var previouslyMigrated = document
            previouslyMigrated.formatReading = .init()
            let repaired = previouslyMigrated.migrateContents(format: format, facts: facts, defaults: defaults)
            #expect(repaired && previouslyMigrated == document)
            let repeated = previouslyMigrated.migrateContents(format: format, facts: facts, defaults: defaults)
            #expect(!repeated)
            document.setLeadContents(
                .levels(1), format: format, facts: facts, defaults: defaults, orgDefaults: .surimono)
            #expect(
                document.formatReading.leadContents(for: format, file: facts.contentsInstructions, defaults: defaults)
                    == .levels(1))
        }
    }

    @Test("旧前付けと新しい目次の掲載項目や段が違えば自動移行を保留する")
    func nativeFrontMigration() {
        var finish = PrintFinish()
        finish.legacyPresetContents.mode = .front
        for (format, fragment, expected) in [
            (DocumentFormat.org, OrgConverter.convert("* A\n* B", proposedLeadDepth: 1), true),
            (.org, OrgConverter.convert("* A\n** B", proposedLeadDepth: 1), false),
            (
                .org, OrgConverter.convert("* A\n* B\n:PROPERTIES:\n:UNNUMBERED: notoc\n:END:", proposedLeadDepth: 1),
                false
            ),
            (.quarto, ComputationalMarkdown.convert("# A\n# B", proposedLeadDepth: 1), true),
            (.quarto, ComputationalMarkdown.convert("# A\n## B", proposedLeadDepth: 1), false),
            (.quarto, ComputationalMarkdown.convert("# A\n# B {.unlisted}", proposedLeadDepth: 1), false),
        ] {
            var document = DocumentSettings(printFinish: finish)
            let migrated = document.migrateContents(format: format, facts: DocumentFacts(fragment: fragment))
            #expect(migrated == expected, "\(format)")
        }
    }

    @Test("同名の見出しが続いても除外した見出しのページ番号を別ページの目次に使わない")
    func duplicateHeadingPages() {
        let fragment = ComputationalMarkdown.convert(
            "---\ntoc: true\n---\n# A {#first}\n# A {#skip .unlisted}\n# A {#last}")
        let facts = DocumentFacts(fragment: fragment)
        #expect(facts.leadEntries?.compactMap(\.id) == ["first", "last"])
        #expect(PaperContents.readerEntries(facts: facts, pageNumbers: [0, 2, 5]).map(\.page) == [0, 5])
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
