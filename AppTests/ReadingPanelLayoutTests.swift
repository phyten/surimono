import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct ReadingPanelLayoutTests {
    @Test("固定見出しの前を七ポイント広げ、開閉見出しに切り替わる境界に一本の線を置く")
    func groupSpacing() throws {
        let width = ReadingPanelMetrics.width - 24
        for (foldable, gap) in [([false, false], 23), ([false, true], 23), ([true, true], 16)] {
            let groups = ReadingPanelGroups(
                groups: [0, 1], isFoldable: { foldable[$0] }, section: { _ in Color.clear.frame(height: 10) })
            let renderer = ImageRenderer(content: groups.frame(width: width))
            renderer.scale = 1
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            #expect(bitmap.pixelsHigh == 20 + gap)
            let painted = (0..<bitmap.pixelsHigh).filter { (bitmap.colorAt(x: 10, y: $0)?.alphaComponent ?? 0) > 0 }
            #expect(painted == (foldable == [false, true] ? [21] : []))
        }
    }

    @Test("読み方に変更がなければ下端を空け、変更すると件数と戻す操作を表示する")
    func changesFooter() {
        let available = CGSize(width: ReadingPanelMetrics.width - 24, height: 1_000)
        for count in 0...3 {
            let footer = NSHostingController(rootView: ReadingPanelFooter(count: count, revert: {}))
            let size = footer.sizeThatFits(in: available)
            #expect((size.height > 0) == (count > 0), "count=\(count) footer=\(size) available=\(available)")
            #expect(size.width <= available.width, "count=\(count) footer=\(size) available=\(available)")
        }
    }

    @Test("全体設定では変更の有無によらず三つの選択欄の右端が標準の設定行に揃う", arguments: UILanguage.supported, [520, 650])
    func defaultsAlignWithForm(language: String, width: CGFloat) async throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let strings = try #require(Bundle(path: path))
        let labels = ["Heading Numbers", "Table of Contents at the Top", "Subscripts and Superscripts"]
        for changed in [false, true] {
            var frames = [String: CGRect]()
            let screen = OrgReadingTestWindow(width: width, height: 300) {
                Form {
                    Section {
                        Picker("Appearance", selection: .constant(0)) { Text("None").tag(0) }
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .global)
                            } action: {
                                frames["Appearance"] = $0
                            }
                    }
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(labels.indices, id: \.self) { index in
                                let keys =
                                    changed
                                    ? ["All Levels", "All Levels", "Leave as Written"]
                                    : ["None", "None", "Only in { }"]
                                let key = keys[index]
                                let value = strings.localizedString(forKey: key, value: nil, table: nil)
                                let title = strings.localizedString(forKey: labels[index], value: nil, table: nil)
                                let picker = Picker("", selection: .constant(0)) { Text(verbatim: value).tag(0) }
                                    .labelsHidden().pickerStyle(.menu)
                                    .onGeometryChange(for: CGRect.self) {
                                        $0.frame(in: .global)
                                    } action: {
                                        frames[labels[index]] = $0
                                    }
                                ReadingChoiceRow(
                                    title: Text(verbatim: title).fontWeight(changed ? .bold : .regular),
                                    token: ["num", "toc", "^"][index], picker: picker
                                ) {
                                    if changed {
                                        ReadingResetButton(help: "Reset", action: {})
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
            func detail() -> String {
                "language=\(language) width=\(width) changed=\(changed) pickerFrames=\(frames)"
            }
            try await screen.wait(detail()) { frames.count == 4 && frames.values.allSatisfy { !$0.isEmpty } }
            let edges = frames.values.map(\.maxX)
            #expect((edges.max() ?? 0) - (edges.min() ?? 0) <= 1, "\(detail())\n\(screen.diagnostic())")
        }
    }

    @Test("パネルのチェックボックスとメニューは、戻す矢印や折り返しの有無によらず右端が揃う")
    func panelControlEdges() async throws {
        var frames = [Int: CGRect]()
        let width = ReadingPanelMetrics.width - 24
        let screen = OrgReadingTestWindow(width: width, height: 360) {
            VStack(alignment: .leading) {
                ForEach(0..<3, id: \.self) { index in
                    let label = index == 1 ? String(repeating: "Long label ", count: 9) : "Short"
                    let control = Group {
                        if index == 2 {
                            Picker("", selection: .constant(0)) { Text("None").tag(0) }
                                .labelsHidden().pickerStyle(.menu)
                        } else {
                            Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.checkbox)
                        }
                    }.onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        frames[index] = $0
                    }
                    ReadingChoiceRow(title: Text(verbatim: label), picker: control) {
                        if index == 1 { ReadingResetButton(help: "Reset", action: {}) }
                    }
                }
            }.frame(width: width)
        }
        defer { screen.window.close() }
        try await screen.wait("width=\(width) frames=\(frames)") {
            frames.count == 3 && frames.values.allSatisfy { !$0.isEmpty }
        }
        for frame in frames.values { #expect(abs(frame.maxX - width) <= 1, "width=\(width) frames=\(frames)") }
    }

    @Test("畳んだ見出しは変更と指定の件数を含めて八言語で実幅に収まる", arguments: UILanguage.supported)
    func groupHeadersFit(language: String) throws {
        let locale = Locale(identifier: language)
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let strings = try #require(Bundle(path: path))
        let available = CGSize(width: ReadingPanelMetrics.width - 24, height: 500)
        for group in OrgReadingGroup.allCases where group.isFoldable {
            var counts = ReadingGroupCounts()
            counts.changed = 2
            counts.file = 2
            let key = group.title.key
            let title = strings.localizedString(forKey: key, value: "<missing>", table: nil)
            #expect(title != "<missing>")
            let section = ReadingPanelSection(
                title: LocalizedStringResource(String.LocalizationValue(stringLiteral: key), locale: locale),
                expanded: .constant(false), counts: counts, ids: group.settings
            ) { _ in EmptyView() }
            let host = NSHostingController(rootView: section.environment(\.locale, locale))
            let size = host.sizeThatFits(in: available)
            #expect(size.width <= available.width && size.height > 0, "\(language) \(title) \(size)")
        }
    }

    @Test(
        "原稿が先頭の目次を指定したときはパネルで深さだけを変えられる", arguments: [DocumentFormat.markdown, .quarto, .rMarkdown, .rst, .mediawiki])
    func formatPanel(format: DocumentFormat) async throws {
        let suite = TestDefaultsSuite()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            suite.remove()
            try? FileManager.default.removeItem(at: root)
        }
        let renderer = DocumentRenderer(paginate: { _ in
            try #require(PDFDocument(data: TestFixtures.pdf("A", pages: 1)))
        })
        let source =
            switch format {
            case .rst: ".. contents::\n\nA\n==="
            case .mediawiki: "__FORCETOC__\n== A =="
            case .rMarkdown: "---\noutput:\n  pdf_document:\n    toc: true\n---\n# A"
            default: "---\ntoc: true\n---\n# A"
            }
        let model = DocumentViewModel(
            data: Data(source.utf8),
            fileURL: nil,
            format: format, preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: root),
            renderer: renderer)
        defer { model.stop() }
        model.render()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.contentsFacts == nil {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        let row = try #require(model.readingResolution(.tableOfContents))
        guard case .outline(let present, let depth) = row else {
            Issue.record("目次の選択欄がない")
            return
        }
        let picker = ReadingOutlinePicker(
            label: ReadingSettingID.tableOfContents.label, present: present, depth: depth, set: { _ in })
        #expect(picker.hasAlternative && !picker.allows(nil) && picker.allows(.levels(1)) && picker.allows(.all))
        model.setReadingValue(.outline(present: true, depth: .levels(1)), for: .tableOfContents)
        #expect(model.leadContents == .levels(1) && model.readingChangedCount == 1)
        model.setReadingValue(.outline(present: false, depth: .all), for: .tableOfContents)
        #expect(model.leadContents == .levels(1))
        let host = NSHostingController(
            rootView: FormatReadingPanel(model: model).environment(\.locale, Locale(identifier: "en")))
        let size = host.sizeThatFits(in: CGSize(width: ReadingPanelMetrics.width, height: 600))
        #expect(size.width == ReadingPanelMetrics.width && size.height > 0)
    }

    @Test("Markdown の目次の理由は原稿行と変更できる成分を一行に示す")
    func markdownReason() throws {
        let file = MarkdownConverter.convert("---\ntoc: true\ntoc-depth: 2\n---\n# A").contentsInstructions
        let locale = Locale(identifier: "en")
        for (source, partialLock, expected): (ReadingInstructionSource?, ReadingFileReason.PartialLock?, String) in [
            (file.present?.source, .enabled, "Specified in file: toc: true (depth can be changed)"),
            (file.depth?.source, .depth, "Specified in file: toc-depth: 2 (can be turned on or off)"),
            (file.present?.source, nil, "Specified in file: toc: true"),
        ] {
            let view = ReadingFileReason(
                documentName: "test.md", fileURL: nil, allowsFileChanges: false,
                source: try #require(source), changed: false, partialLock: partialLock)
            #expect(view.reason(locale: locale) == expected)
        }
    }

    @Test("rST と Wiki の固定理由には原稿の指定と変更できる成分が一行で出る")
    func directiveReasons() throws {
        let rst = RSTConverter.convert(".. sectnum::\n\n.. contents:: Map")
        let cases: [(ReadingInstructionSource?, ReadingFileReason.PartialLock, String)] = [
            (rst.numberInstructions.present?.source, .enabled, ".. sectnum:: (depth can be changed)"),
            (rst.contentsInstructions.present?.source, .enabled, ".. contents:: Map (depth can be changed)"),
            (
                MediaWikiConverter.convert("__FORCETOC__").contentsInstructions.present?.source, .enabled,
                "__FORCETOC__ (depth can be changed)"
            ),
            (
                MediaWikiConverter.convert("__NOTOC__").contentsInstructions.present?.source, .disabled,
                "__NOTOC__ (off is fixed)"
            ),
        ]
        for (source, lock, expected) in cases {
            let reason = ReadingFileReason(
                documentName: "test", fileURL: nil, allowsFileChanges: false,
                source: try #require(source), changed: false, partialLock: lock)
            #expect(reason.reason(locale: Locale(identifier: "en")) == "Specified in file: " + expected)
        }
    }

    @Test("計算文書の指定行には固定した成分と変更できる成分を同じ行に示す", arguments: [DocumentFormat.quarto, .rMarkdown])
    func computationalReason(format: DocumentFormat) throws {
        let header =
            format == .quarto ? "format:\n  html:\n    number-depth: 2" : "output:\n  pdf_document:\n    toc: true"
        let fragment = ComputationalMarkdown.convert("---\n" + header + "\n---\n# One", format: format)
        let source = try #require(
            format == .quarto
                ? fragment.numberInstructions.depth?.source : fragment.contentsInstructions.present?.source)
        let reason = ReadingFileReason(
            documentName: "test", fileURL: nil, allowsFileChanges: false, source: source,
            changed: false, partialLock: format == .quarto ? .depth : .enabled)
        let expected =
            format == .quarto
            ? "Specified in file: number-depth: 2 (can be turned on or off)"
            : "Specified in file: toc: true (depth can be changed)"
        #expect(reason.reason(locale: Locale(identifier: "en")) == expected)
        #expect(source.lineNumber == 4)
    }

    @Test("読み方の全項目は八言語で選択値と戻す矢印が収まり、横に収まる行は一列を保つ", arguments: UILanguage.supported)
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
        let scripts = ["Only in { }", "Even without { }", "Leave as Written"].map(translated)
        // The two 12 pt insets belong to SidePanel, outside the rows' proposal.
        let available = CGSize(width: ReadingPanelMetrics.width - 24, height: 1_000)
        for id in OrgReadingGroup.allCases.flatMap(\.settings) {
            let label = id.label.key
            let choices: [String]
            let checkbox: Bool
            switch id {
            case .sectionNumbers, .tableOfContents, .headlineLevels: choices = depths
            case .scripts: choices = scripts
            case .tags: choices = ["On", "Off", "Except in Contents"].map(translated)
            case .math: choices = ["Typeset", "None", "Show Source"].map(translated)
            case .tasks: choices = ["All", "None", "Unfinished Only", "Completed Only"].map(translated)
            case .drawers: choices = ["Don't Show", "Show All", "Show All Except LOGBOOK"].map(translated)
            case .properties: choices = ["Don't Show", "Show All"].map(translated)
            case .archived: choices = ["Entire Tree", "Heading Only", "None"].map(translated)
            case .timestamps: choices = ["All", "None", "Active Only", "Inactive Only"].map(translated)
            default: choices = []
            }
            checkbox = choices.isEmpty
            let title = Text(verbatim: translated(label)).bold()
            for selection in checkbox ? [""] : choices {
                let picker = Group {
                    if checkbox {
                        Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.checkbox)
                    } else {
                        Picker("", selection: .constant(selection)) {
                            ForEach(choices, id: \.self) { Text(verbatim: $0).tag($0) }
                        }.labelsHidden().pickerStyle(.menu)
                    }
                }
                let reset = ReadingResetButton(help: "Reset", action: {})
                let row = ReadingChoiceRow(title: title, picker: picker) { reset }
                let inline = HStack(alignment: .firstTextBaseline, spacing: 6) {
                    title
                    picker
                    reset
                }
                let locale = Locale(identifier: language)
                let ideal = NSHostingView(rootView: inline.environment(\.locale, locale).fixedSize()).fittingSize
                let host = NSHostingController(rootView: row.environment(\.locale, locale))
                let size = host.sizeThatFits(in: available)
                func detail() -> String {
                    "language=\(language) label=\(label) selection=\(selection) "
                        + "inline=\(ideal) row=\(size) available=\(available)\n"
                        + OrgReadingTestWindow.diagnostic(in: host.view)
                }
                #expect(size.width <= available.width, "\(detail())")
                if [.sectionNumbers, .tableOfContents].contains(id), language == "ja",
                    ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
                {
                    #expect(ideal.width <= available.width, "\(detail())")
                }
                // Both systems must use one line when it fits and keep both controls intact below it otherwise.
                #expect((size.height > ideal.height) == (ideal.width > available.width), "\(detail())")
            }
        }
    }
}
