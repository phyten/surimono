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

    @Test("全体設定では変更の有無によらず三つの選択欄の右端が標準の設定行に揃う", arguments: UILanguage.supported, [520, 650])
    func defaultsAlignWithForm(language: String, width: CGFloat) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let strings = try #require(Bundle(path: path))
        let labels = ["Heading Numbers", "Table of Contents at the Top", "Subscripts and Superscripts"]
        for changed in [false, true] {
            let screen = OrgReadingTestWindow(width: width, height: 300) {
                Form {
                    Section {
                        Picker("Appearance", selection: .constant(0)) { Text("None").tag(0) }
                    }
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(labels.indices, id: \.self) { index in
                                let keys =
                                    changed
                                    ? ["All Levels", "All Levels", "Leave as Written"]
                                    : ["None", "None", "Only with { }"]
                                let key = keys[index]
                                let value = strings.localizedString(forKey: key, value: nil, table: nil)
                                let title = strings.localizedString(forKey: labels[index], value: nil, table: nil)
                                let picker = Picker("", selection: .constant(0)) { Text(verbatim: value).tag(0) }
                                    .labelsHidden().pickerStyle(.menu)
                                OrgReadingChoiceRow(
                                    title: Text(verbatim: title).fontWeight(changed ? .bold : .regular),
                                    token: ["num", "toc", "^"][index], picker: picker
                                ) {
                                    if changed {
                                        OrgReadingResetButton(help: "Reset", action: {})
                                    } else {
                                        Color.clear.frame(width: 16, height: 1)
                                    }
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped).environment(\.locale, Locale(identifier: language))
            }
            defer { screen.window.close() }
            let edges = screen.views(NSPopUpButton.self).map { $0.convert($0.bounds, to: screen.host).maxX }
            try #require(edges.count == 4)
            #expect((edges.max() ?? 0) - (edges.min() ?? 0) <= 1, "\(language): \(edges)")
        }
    }

    @Test("桁の多い深さでは縦スクロール内に横スクロールを置き、選択欄と戻すボタンの高さを保つ")
    func longDepthScrollsToReset() throws {
        let depth = Int.max
        let file = try #require(OrgConverter.convert("#+OPTIONS: toc:\(depth)").orgInstructions)
        try #require(OrgReadingSettings().resolve(.tableOfContents, file: file).value == .levels(depth))
        let path = try #require(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let strings = try #require(Bundle(path: path))
        let format = strings.localizedString(forKey: "Up to Level %lld", value: nil, table: nil)
        let choice = String(format: format, Int64(depth))
        let width = OrgReadingPanel.width - 24
        var resetFrame = CGRect.zero
        let screen = OrgReadingTestWindow(width: width, height: 160) {
            ScrollView(.vertical) {
                OrgReadingChoiceRow(
                    title: Text("Table of Contents at the Top"),
                    picker: Picker("", selection: .constant(depth)) { Text(verbatim: choice).tag(depth) }
                        .labelsHidden().pickerStyle(.menu)
                ) {
                    OrgReadingResetButton(help: "Reset", action: {})
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named("viewport"))
                        } action: {
                            resetFrame = $0
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "viewport")
        }
        defer { screen.window.close() }
        let popup = try #require(screen.views(NSPopUpButton.self).first)
        let horizontal = try #require(popup.enclosingScrollView)
        let document = try #require(horizontal.documentView)
        try #require(horizontal.enclosingScrollView != nil)
        let clip = horizontal.contentView
        try #require(document.bounds.width > clip.bounds.width && clip.bounds.width <= width)
        let viewport = horizontal.convert(clip.frame, to: screen.host)
        let button = popup.convert(popup.bounds, to: screen.host)
        #expect(popup.isEnabled && popup.title == choice)
        #expect(viewport.minY <= button.minY && viewport.maxY >= button.maxY)
        try #require(resetFrame.width > 0 && resetFrame.maxX > viewport.maxX)
        // Scroll the actual clip view to the trailing end, without a wheel event or an animation.
        clip.scroll(to: CGPoint(x: document.bounds.maxX - clip.bounds.width, y: clip.bounds.minY))
        horizontal.reflectScrolledClipView(clip)
        screen.host.layoutSubtreeIfNeeded()
        let scrolled = popup.convert(popup.bounds, to: screen.host)
        #expect(scrolled.maxX > viewport.minX && scrolled.maxX <= viewport.maxX)
        #expect(viewport.contains(resetFrame) && resetFrame.height > 0)
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
