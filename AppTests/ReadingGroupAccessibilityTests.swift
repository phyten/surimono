import AppKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct ReadingGroupAccessibilityTests {
    @Test("暗い読み方パネルの固定値は設定名と値を持つ一つの無効な要素になる")
    func lockedValue() throws {
        let id = ReadingSettingID.sectionNumbers
        let value = "2 levels"
        let host = NSHostingView(
            rootView: ReadingSettingControl(id: id, changed: false, locked: true, resetHelp: "", reset: {}) {
                ReadingMenu(label: id.label, selection: .constant(0), valueLabel: Text(verbatim: value)) {
                    Text(verbatim: value).tag(0)
                }
            }
            .environment(\.colorScheme, .dark).environment(\.accessibilityEnabled, true))
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let matches = nodes(of: host).filter { $0.accessibilityIdentifier?() == id.rawValue }
        try #require(matches.count == 1)
        let badge = matches[0]
        let name = String(localized: id.label)
        let label: String? = badge.accessibilityLabel?()
        let title: String? = badge.accessibilityTitle?()
        let spokenValue: Any? = badge.accessibilityValue?()
        #expect(label == name || title == name)
        #expect(spokenValue as? String == value)
        #expect(badge.accessibilityRole?() == .staticText)
        #expect(badge.isAccessibilityEnabled?() == false)
        #expect(badge.accessibilityChildren?()?.isEmpty != false)
    }

    @Test("出典のポップオーバーは外部参照のときだけ、設定と本文を取り込まない説明を表示する", arguments: ["ja", "en"])
    func externalReferenceExplanation(language: String) async throws {
        let bundle = try #require(
            Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)))
        let key = "Settings and text in the referenced files are not brought into the display or print."
        let explanation = bundle.localizedString(forKey: key, value: "MISSING", table: nil)
        try #require(explanation != "MISSING")
        let fileName = "main.org"
        let file = try #require(
            OrgConverter.convert("#+SETUPFILE: a.org\n#+OPTIONS: num:t", fileName: fileName).orgInstructions)
        let fixed = try #require(OrgReadingSettings().resolve(.sectionNumbers, file: file).source)
        for (sources, explains): (ReadingSourceButton<EmptyView>.Sources, Bool) in [
            (.instruction(fixed), false), (.externalSettings(file.externalSettingsSources, additionalCount: 0), true),
        ] {
            let content = ReadingSourceButton(documentName: fileName, fileURL: nil, sources: sources) { EmptyView() }
                .popoverContent.environment(\.locale, Locale(identifier: language))
            let size = NSHostingView(rootView: content).fittingSize
            let screen = OrgReadingTestWindow(width: size.width, height: size.height) { content }
            defer { screen.window.close() }
            func hasText(_ text: String) -> Bool {
                nodes(of: screen.host).contains { spokenName($0).contains(text) }
            }
            try await screen.wait("language=\(language) external=\(explains)") {
                hasText(fileName) && (!explains || hasText(explanation))
            }
            #expect(hasText(explanation) == explains)
        }
    }

    @Observable fileprivate final class Expansion {
        var isOpen = false
    }

    @Test("一段でも折り返しでも、見出しと件数を一度だけ読み上げ、開閉操作で中の行に到達できる", arguments: [0, 2], [0, 3])
    func disclosure(changed: Int, file: Int) async throws {
        let locale = Locale(identifier: "en")
        let bundle = try #require(Bundle.main.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:)))
        let title = LocalizedStringResource("Tasks and Dates", locale: locale)
        let name = bundle.localizedString(forKey: title.key, value: nil, table: nil)
        func countLabel(_ key: String, _ count: Int) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil), locale: locale, Int64(count))
        }
        var counts = ReadingGroupCounts()
        counts.changed = changed
        counts.file = file
        var heights: [CGFloat] = []
        for width: CGFloat in [320, 74] {
            let state = Expansion()
            var height: CGFloat = 0
            let screen = OrgReadingTestWindow(width: width, height: 180) {
                Fixture(state: state, title: title, counts: counts).environment(\.locale, locale)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        height = $0
                    }
            }
            defer { screen.window.close() }

            func triangle(in nodes: [AnyObject]) -> AnyObject? {
                nodes.first { $0.accessibilityRole?() == .disclosureTriangle }
            }
            func expanded(_ node: AnyObject) -> Bool? {
                // A native AXDisclosureTriangle publishes 0/1 as its value on macOS.
                let value: Any? = node.accessibilityValue?()
                return (value as? NSNumber)?.boolValue ?? node.isAccessibilityExpanded?()
            }
            func check(open: Bool) async throws -> AnyObject {
                try await screen.wait("width=\(width) changed=\(changed) file=\(file) open=\(open)") {
                    guard let node = triangle(in: nodes(of: screen.host)) else { return false }
                    return height > 0 && expanded(node) == open && state.isOpen == open
                }
                let tree = nodes(of: screen.host)
                let header = try #require(triangle(in: tree))
                #expect(tree.count { $0.accessibilityRole?() == .disclosureTriangle } == 1)
                let spoken = tree.map(spokenName).joined(separator: "\n")
                let headerName = spokenName(header)
                for (text, times) in [
                    (name, 1), (countLabel("Changed %lld", changed), changed > 0 && !open ? 1 : 0),
                    (countLabel("File %lld", file), file > 0 && !open ? 1 : 0),
                ] {
                    #expect(headerName.components(separatedBy: text).count - 1 == times, "\(headerName)")
                    #expect(spoken.components(separatedBy: text).count - 1 == times, "\(spoken)")
                }
                #expect(tree.count { spokenName($0) == "Clock control" } == (open ? 1 : 0))
                return header
            }

            let closed = try await check(open: false)
            heights.append(height)
            try #require(closed.accessibilityPerformPress?() == true)
            let opened = try await check(open: true)
            try #require(opened.accessibilityPerformPress?() == true)
            _ = try await check(open: false)
        }
        #expect(heights[1] > heights[0], "wide/narrow=\(heights)")
    }

    private struct Fixture: View {
        let state: Expansion
        let title: LocalizedStringResource
        let counts: ReadingGroupCounts

        var body: some View {
            ReadingPanelSection(
                title: title, expanded: Binding(get: { state.isOpen }, set: { state.isOpen = $0 }),
                counts: counts, ids: [.clocks]
            ) { _ in Button(action: {}) { Text(verbatim: "Clock control") } }
        }
    }

    // SwiftUI virtual children may expose the AX selectors without declaring NSAccessibilityProtocol.
    private func nodes(of host: NSView) -> [AnyObject] {
        var visited: Set<ObjectIdentifier> = []
        func walk(_ objects: [Any]) -> [AnyObject] {
            objects.flatMap { object -> [AnyObject] in
                let node = object as AnyObject
                guard visited.insert(ObjectIdentifier(node)).inserted else { return [] }
                return [node] + walk(node.accessibilityChildren?() ?? [])
            }
        }
        return walk(host.accessibilityChildren() ?? [])
    }

    private func spokenName(_ node: AnyObject) -> String {
        let value: Any? = node.accessibilityValue?()
        let fields: [String?] = [node.accessibilityLabel?(), node.accessibilityTitle?(), value as? String]
        return Set(fields.compactMap { $0 }.filter { !$0.isEmpty }).sorted().joined(separator: "\n")
    }
}
