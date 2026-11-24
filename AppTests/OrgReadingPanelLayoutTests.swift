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
        let width = OrgReadingPanel.width - 24
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
                    OrgReadingChoiceRow(title: Text(verbatim: label), picker: control) {
                        if index == 1 { OrgReadingResetButton(help: "Reset", action: {}) }
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
        let scripts = ["Only in { }", "With or without Braces", "Leave as Written"].map(translated)
        // The two 12 pt insets belong to SidePanel, outside the rows' proposal.
        let available = CGSize(width: OrgReadingPanel.width - 24, height: 1_000)
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
            case .drawers: choices = ["None", "All", "Except LOGBOOK"].map(translated)
            case .properties: choices = ["None", "All"].map(translated)
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
                let reset = OrgReadingResetButton(help: "Reset", action: {})
                let row = OrgReadingChoiceRow(title: title, picker: picker) { reset }
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
