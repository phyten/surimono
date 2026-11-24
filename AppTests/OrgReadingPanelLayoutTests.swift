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
                                    : ["None", "None", "Only with { }"]
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

    @Test("桁の多い深さでは縦スクロール内に横スクロールを置き、選択欄と戻すボタンの高さを保つ")
    func longDepthScrollsToReset() async throws {
        let depth = Int.max
        let file = try #require(OrgConverter.convert("#+OPTIONS: toc:\(depth)").orgInstructions)
        try #require(OrgReadingSettings().resolve(.tableOfContents, file: file).value == .levels(depth))
        let path = try #require(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let strings = try #require(Bundle(path: path))
        let format = strings.localizedString(forKey: "Up to Level %lld", value: nil, table: nil)
        let choice = String(format: format, Int64(depth))
        let picker = Picker("", selection: .constant(depth)) { Text(verbatim: choice).tag(depth) }
            .labelsHidden().pickerStyle(.menu).accessibilityIdentifier("org.depth")
        var ideal = CGSize.zero
        let width = OrgReadingPanel.width - 24
        var button = CGRect.zero
        var reset = CGRect.zero
        var viewport = CGRect.zero
        var reader: ScrollViewProxy?
        let screen = OrgReadingTestWindow(width: width, height: 160) {
            ScrollView(.vertical) {
                ScrollViewReader { proxy in
                    OrgReadingChoiceRow(
                        title: Text("Table of Contents at the Top"),
                        picker:
                            picker
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named("panel"))
                            } action: {
                                button = $0
                            }
                            .onGeometryChange(for: CGRect?.self) { geometry in
                                guard geometry.bounds(of: .scrollView(axis: .vertical)) != nil,
                                    let clip = geometry.bounds(of: .scrollView(axis: .horizontal))
                                else { return nil }
                                let origin = geometry.frame(in: .named("panel")).origin
                                return clip.offsetBy(dx: origin.x, dy: origin.y)
                            } action: {
                                viewport = $0 ?? .zero
                            }
                    ) {
                        OrgReadingResetButton(help: "Reset", action: {})
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named("panel"))
                            } action: {
                                reset = $0
                            }
                            .id("reset")
                    }
                    .onAppear { reader = proxy }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "panel")
            // Use the same SwiftUI geometry and display scale for both pickers. AppKit's fittingSize rounds
            // a 298.5 pt picker to 299 pt at 2x. A background does not participate in the viewport's sizing.
            .background(alignment: .topLeading) {
                picker.fixedSize().hidden().accessibilityHidden(true).allowsHitTesting(false)
                    .onGeometryChange(for: CGSize.self) {
                        $0.size
                    } action: {
                        ideal = $0
                    }
            }
        }
        defer { screen.window.close() }
        screen.window.orderBack(nil)
        func detail() -> String {
            "depth=\(choice) width=\(width) ideal=\(ideal) picker=\(button) reset=\(reset) "
                + "nestedViewport=\(viewport) controlsWidth=\(reset.maxX - button.minX)"
        }
        try await screen.wait(detail()) {
            ideal.width > 0 && ideal.height > 0 && !viewport.isEmpty && !button.isEmpty && !reset.isEmpty
                && reader != nil
        }
        let initial = button
        try #require(
            reset.maxX - button.minX > viewport.width && viewport.width <= width,
            "\(detail())\n\(screen.diagnostic())")
        try #require(reset.maxX > viewport.maxX, "\(detail())\n\(screen.diagnostic())")
        // The two views round to the pixel on their own, so they may differ by less than a point.
        #expect(
            button.width >= ideal.width - 1 && button.height >= ideal.height - 1, "\(detail())\n\(screen.diagnostic())")
        #expect(viewport.minY <= button.minY && viewport.maxY >= button.maxY, "\(detail())\n\(screen.diagnostic())")
        // The selected value may be the accessible value or the menu button's title.
        try await screen.wait(detail()) {
            OrgReadingTestWindow.elements(in: screen.host).contains {
                ($0.accessibilityIdentifier() == "org.depth"
                    || [.popUpButton, .menuButton, .button].contains($0.accessibilityRole()))
                    && $0.isAccessibilityEnabled()
                    && [$0.accessibilityTitle(), $0.accessibilityValue() as? String, $0.accessibilityLabel()].contains(
                        choice)
            }
        }
        reader?.scrollTo("reset", anchor: .trailing)
        try await screen.wait("After scrolling from \(initial). \(detail())") {
            button.minX < initial.minX && button.maxX > viewport.minX && button.maxX <= viewport.maxX
                && viewport.contains(reset) && !reset.isEmpty
        }
    }

    @Test("読み方の三項目は八言語で選択値と戻す矢印が収まり、横に収まる行は一列を保つ", arguments: UILanguage.supported)
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
                if language == "ja", ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 {
                    #expect(ideal.width <= available.width, "\(detail())")
                }
                // Both systems must use one line when it fits and keep both controls intact below it otherwise.
                #expect((size.height > ideal.height) == (ideal.width > available.width), "\(detail())")
            }
        }
    }
}
