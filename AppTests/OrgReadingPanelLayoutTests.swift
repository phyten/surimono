import AppKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct OrgReadingPanelLayoutTests {
    @Test("読み方に変更がなければ下端を空け、変更すると件数と戻す操作を表示する")
    func changesFooter() {
        let available = CGSize(width: OrgReadingPanel.width - 24, height: 1_000)
        for count in 0...3 {
            let footer = NSHostingController(rootView: OrgReadingFooter(count: count, revert: {}))
            let size = footer.sizeThatFits(in: available)
            #expect((size.height > 0) == (count > 0))
            #expect(size.width <= available.width)
        }
    }

    @Test("読み方の三項目は八言語で選択値と戻す矢印が収まり、日本語は横一列を保つ", arguments: UILanguage.supported)
    func choicesFit(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        func translated(_ key: String) -> String {
            bundle.localizedString(forKey: key, value: nil, table: nil)
        }
        let depths =
            ["None", "All Levels"].map(translated)
            + (1...6).map {
                String(format: translated("Up to Level %lld"), Int64($0))
            }
        let scripts = ["Only with { }", "With or without Braces", "Leave as Written"].map(translated)
        // The two 12 pt insets belong to SidePanel, outside the rows' proposal.
        let available = CGSize(width: OrgReadingPanel.width - 24, height: 1_000)
        for (label, choices) in [
            ("Heading Numbers", depths), ("Table of Contents at the Top", depths),
            ("Subscripts and Superscripts", scripts),
        ] {
            let title = Text(verbatim: translated(label)).bold()
            for selection in choices {
                let picker = Picker("", selection: .constant(selection)) {
                    ForEach(choices, id: \.self) { Text(verbatim: $0).tag($0) }
                }.labelsHidden().pickerStyle(.menu)
                let reset = Image(systemName: "arrow.counterclockwise").frame(width: 16)
                let row = OrgReadingChoiceRow(title: title, picker: picker) { reset }
                let inline = HStack(alignment: .firstTextBaseline, spacing: 6) {
                    title
                    picker
                    reset
                }
                let locale = Locale(identifier: language)
                let ideal = NSHostingView(rootView: inline.environment(\.locale, locale).fixedSize()).fittingSize
                let size = NSHostingController(rootView: row.environment(\.locale, locale)).sizeThatFits(in: available)
                #expect(size.width <= available.width, "\(label) / \(selection)")
                if language == "ja" {
                    #expect(ideal.width <= available.width)
                }
                // A row that cannot fit at its natural width must put its controls below the title.
                #expect((size.height > ideal.height) == (ideal.width > available.width), "\(label) / \(selection)")
            }
        }
    }
}
