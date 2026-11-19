import AppKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BandEditorGeometryTests {
    @Test("設定幅1100と820の混雑したミニチュアでも左右の領域が重ならない", arguments: [1100.0, 820.0])
    func crowdedZones(width: Double) async throws {
        var layouts = BandArrangementVariants()
        for item in BandTestCatalog.addedItems {
            layouts.split = try layouts.split.moving(item, to: .zone(.topRight), before: .print, for: .split)
        }
        let fixture = try Fixture(width: width, layouts: layouts)
        defer { fixture.close() }
        try await fixture.waitForFrames(["topLeft", "topRight", "bottomLeft", "bottomRight"])
        for pair in [("topLeft", "topRight"), ("bottomLeft", "bottomRight")] {
            let left = try #require(fixture.session.layoutFrames[pair.0])
            let right = try #require(fixture.session.layoutFrames[pair.1])
            #expect(!left.isEmpty && !right.isEmpty)
            #expect(!left.intersects(right), "\(width): \(left), \(right)")
            #expect(left.minX >= 20 && right.maxX <= width - 230 - 20)
        }
    }

    @Test("7群のパレットは全チップの高さを持ち詳細ページの縦スクロールは一つだけ")
    func paletteHeight() async throws {
        var layouts = BandArrangementVariants()
        for item in BandLayout.Item.allCases where item != .print {
            layouts.split = try layouts.split.moving(item, to: .unused, for: .split)
        }
        let fixture = try Fixture(width: 1100, layouts: layouts, detailOnly: true)
        defer { fixture.close() }
        let keys = layouts.split.unused.map { "unused-" + $0.rawValue }
        try await fixture.waitForFrames(["palette"] + keys)
        let palette = try #require(fixture.session.layoutFrames["palette"])
        for key in keys {
            let chip = try #require(fixture.session.layoutFrames[key])
            #expect(palette.contains(chip), "\(key): \(chip), palette: \(palette)")
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        // The fixture hosts the detail page directly, so the sidebar's native list is not counted.
        let content = try #require(fixture.window.contentView)
        let scrolls = scrollViews(content)
        #expect(scrolls.count == 1)
        let scroll = try #require(scrolls.first)
        #expect((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height)
    }

    @MainActor private final class Fixture {
        let suite = BandTestDefaultsSuite()
        let session: BandArrangementEditorSession
        let window: NSWindow
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        init(width: Double, layouts: BandArrangementVariants, detailOnly: Bool = false) throws {
            let preferences = AppPreferences(defaults: suite.defaults)
            preferences.menuArrangement = .split
            preferences.settingsSection = .toolbarArrangement
            try preferences.saveBandArrangement(.init(name: "Geometry", layouts: layouts))
            session = BandArrangementEditorSession(preferences: preferences)
            // The overlap regression uses the real Settings sidebar and its width negotiation.
            // Only the scroll-count test isolates the detail page from the sidebar's own list.
            let root: AnyView
            if detailOnly {
                root = AnyView(BandArrangementSettings(session: session))
            } else {
                root = AnyView(
                    SettingsView(
                        preferences: preferences, library: UserLibrary(root: directory), arrangementEditor: session))
            }
            let contentWidth = detailOnly ? width - 260 : width
            let hosting = NSHostingController(rootView: root.environment(\.locale, Locale(identifier: "de")))
            hosting.sizingOptions = []
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 900),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: contentWidth, height: 900))
            window.alphaValue = 0
            window.orderFrontRegardless()
        }

        func waitForFrames(_ keys: [String]) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            var previous: [String: CGRect] = [:]
            while ContinuousClock.now < deadline {
                await withCheckedContinuation { continuation in
                    RunLoop.main.perform(inModes: [.default]) { continuation.resume() }
                    CFRunLoopWakeUp(CFRunLoopGetMain())
                }
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let frames = session.layoutFrames
                if keys.allSatisfy({ frames[$0]?.isEmpty == false }), frames == previous { return }
                previous = frames
            }
            Issue.record("レイアウトの記録が揃わない: \(keys), \(session.layoutFrames)")
            throw CocoaError(.coderInvalidValue)
        }

        func close() {
            window.close()
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
