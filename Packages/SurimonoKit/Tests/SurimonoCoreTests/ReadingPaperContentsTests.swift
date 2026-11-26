import Foundation
import SurimonoCore
import Testing

struct ReadingPaperContentsTests {
    @Test("Org・Markdown・Quarto の原稿の目次数にかかわらず、仕上げは同じ CSS で一括表示し、前付けだけが別の深さを使う")
    func combinations() {
        let outline = "# Title\n\n## Alpha\n\n### Bravo\n\n#### Charlie"
        let org = "* Title\n** Alpha\n*** Bravo\n**** Charlie"
        let cases = [
            (OrgConverter.convert(org), 0),
            (OrgConverter.convert("#+OPTIONS: toc:3\n" + org), 1),
            (MarkdownConverter.convert("---\ntoc: true\n---\n" + outline + "\n\n[TOC]"), 2),
            (ComputationalMarkdown.convert("---\ntoc: true\n---\n" + outline + "\n\n[TOC]"), 2),
        ]
        let modes: [(PaperTOC.Mode, Bool, Bool)] = [
            (.hidden, false, false), (.hidden, true, false), (.source, false, true), (.source, true, true),
            (.front, false, false), (.front, true, true),
        ]
        for (fragment, count) in cases {
            let facts = DocumentFacts(fragment: fragment)
            #expect(facts.hasSourceContents == (count > 0))
            #expect(fragment.body.components(separatedBy: "<nav class=\"toc\"").count - 1 == count)
            for (mode, keep, showsSource) in modes {
                var finish = PrintFinish()
                finish.legacyPresetContents.mode = mode
                finish.legacyPresetContents.keepsSourceTOC = keep
                for depth in PaperTOC.Depth.allCases {
                    finish.legacyPresetContents.depth = depth
                    #expect(finish.legacyPresetContents.showsSourceContents == showsSource)
                    #expect(finish.styleSheet.contains("nav.toc { display: none !important; }") == !showsSource)
                    let entries = PaperContents.entries(headings: facts.headings, pageNumbers: [], depth: depth)
                    #expect(entries.map(\.text) == (depth == .chapters ? ["Alpha"] : ["Alpha", "Bravo"]))
                }
            }
        }
    }
}
