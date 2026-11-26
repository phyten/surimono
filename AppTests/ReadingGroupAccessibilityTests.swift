import AppKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct ReadingGroupAccessibilityTests {
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
