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
        let fixture = try Fixture(width: width, layouts: crowdedArrangement())
        defer { fixture.close() }
        try await fixture.checkZones(windowWidth: width)
    }

    @Test("設定窓の既定幅では追加できる部品が縮図の右に並ぶ")
    func paletteBesideEditor() async throws {
        let fixture = try Fixture(
            width: SettingsWindowPlacement.defaultContentSize.width, layouts: BandArrangementVariants())
        defer { fixture.close() }
        try await fixture.waitForFrames(["topBand", "palette"])
        let band = try #require(fixture.session.layoutFrames["topBand"])
        let palette = try #require(fixture.session.layoutFrames["palette"])
        #expect(palette.minX > band.maxX)
    }

    @Test("同じ配置ペインで幅1100と820を往復すると両方の帯がその場で折り返す", arguments: [820.0, 1100.0])
    func resizeCrowdedZones(initialWidth: Double) async throws {
        // A saved name wider than the narrow column makes the header ask for extra room even on macOS 26.
        let fixture = try Fixture(
            width: initialWidth, layouts: crowdedArrangement(),
            setName: "Geometry – " + String(repeating: "Print and Page Layout ", count: 5))
        defer { fixture.close() }
        let otherWidth: Double = initialWidth == 820 ? 1100 : 820
        for width in [initialWidth, otherWidth, initialWidth] {
            fixture.window.setContentSize(CGSize(width: width, height: 900))
            try await fixture.checkZones(windowWidth: width)
            let viewport = try #require(fixture.scrollViews.first).contentView.bounds.width
            // The wide arrangement gives the palette 230 points and a 14-point gutter.
            // In both arrangements there are two 20-point page margins and two 8-point band insets.
            let expected = viewport - 40 - 16 - (width == 1100 ? 244 : 0)
            for key in ["topBand", "bottomBand"] {
                let band = try #require(fixture.session.layoutFrames[key])
                #expect(abs(band.width - expected) <= 1, "\(fixture.geometryDetails)")
            }
        }
    }

    private func crowdedArrangement() throws -> BandArrangementVariants {
        var layouts = BandArrangementVariants()
        for item in BandTestCatalog.addedItems {
            layouts.split = try layouts.split.moving(item, to: .zone(.topRight), before: .print, for: .split)
        }
        return layouts
    }

    @Test("設定幅820・900・1100で表示中のペインは詳細列に収まり、隠したペインは再表示で追いつく")
    func retainedPaneBounds() async throws {
        let fixture = try Fixture(width: 900, layouts: BandArrangementVariants())
        defer { fixture.close() }
        let window = fixture.window
        let content = try #require(window.contentView)
        await fixture.nextLayout()
        let pane = try #require(settingsPaneContainer(in: content))
        var hosts: [SettingsSection: NSView] = [:]
        var sections: [SettingsSection] = [.toolbarArrangement, .keyboardShortcuts, .general]
        for section in sections {
            fixture.session.showSection(section)
            await fixture.nextLayout()
            hosts[section] = try #require(pane.subviews.first { !$0.isHidden })
        }
        #expect(Set(hosts.values.map { ObjectIdentifier($0) }).count == 3)
        let verticalInset = content.bounds.height - pane.bounds.height

        // Leave a different pane visible during each resize, then bring both frozen frames up to date.
        for (index, width) in [820, 900, 1100].enumerated() {
            let hidden = pane.subviews.filter(\.isHidden).map { ($0, $0.frame) }
            let size = CGSize(width: width, height: 630 + 40 * index)
            window.setContentSize(size)
            await fixture.nextLayout()
            #expect(content.bounds.size == size)
            let column = pane.convert(pane.bounds, to: content)
            #expect(column.maxX == content.bounds.maxX)
            // The detail starts after the negotiated sidebar and the native divider.
            #expect(column.minX >= 230 && column.minX <= 301)
            #expect(column.height == size.height - verticalInset)
            #expect(pane.subviews.first { !$0.isHidden }?.frame == pane.bounds)
            for (host, frame) in hidden {
                #expect(host.isHidden && host.frame == frame)
            }
            sections.append(sections.removeFirst())
            for section in sections {
                fixture.session.showSection(section)
                await fixture.nextLayout()
                let host = try #require(hosts[section])
                #expect(pane.convert(pane.bounds, to: content) == column)
                #expect(
                    !host.isHidden && host.frame == pane.bounds, "\(width), \(section): \(host.frame), \(pane.bounds)")
            }
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
        let scrolls = fixture.scrollViews
        #expect(scrolls.count == 1)
        let scroll = try #require(scrolls.first)
        #expect(
            (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height, "\(fixture.geometryDetails)")
    }

    @MainActor private final class Fixture {
        let suite = BandTestDefaultsSuite()
        let session: BandArrangementEditorSession
        let window: NSWindow
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        init(width: Double, layouts: BandArrangementVariants, detailOnly: Bool = false, setName: String = "Geometry")
            throws
        {
            let preferences = AppPreferences(defaults: suite.defaults)
            preferences.menuArrangement = .split
            preferences.settingsSection = .toolbarArrangement
            try preferences.saveBandArrangement(.init(name: setName, layouts: layouts))
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
            // Shorter than the palette on any system, so the page must scroll whatever the font metrics are.
            let contentHeight: Double = detailOnly ? 600 : 900
            let hosting = NSHostingController(rootView: root.environment(\.locale, Locale(identifier: "de")))
            hosting.sizingOptions = []
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: contentWidth, height: contentHeight))
            window.alphaValue = 0
            window.orderFrontRegardless()
        }

        private var paneHost: NSView? {
            guard let content = window.contentView else { return nil }
            // The palette-only fixture mounts its editor directly. The full fixture also contains a sidebar list.
            if let container = settingsPaneContainer(in: content) { return container.subviews.first { !$0.isHidden } }
            return content
        }

        var scrollViews: [NSScrollView] {
            func collect(in view: NSView) -> [NSScrollView] {
                let children = view.subviews.flatMap { collect(in: $0) }
                guard let scroll = view as? NSScrollView else { return children }
                return [scroll] + children
            }
            return paneHost.map { collect(in: $0) } ?? []
        }

        var geometryDetails: String {
            let frames = session.layoutFrames
            let bands = ["topBand", "bottomBand"].map { frames[$0]?.width.description ?? "?" }
            let zones = ["topLeft", "topRight", "bottomLeft", "bottomRight"].map {
                "\($0)=\(String(describing: frames[$0]))"
            }
            return
                "window=\(window.contentView?.bounds.width.description ?? "?"), host=\(paneHost?.bounds.width.description ?? "?"), "
                + "viewport=\(scrollViews.map { $0.contentView.bounds.width }), wrap(top,bottom)=\(bands), \(zones.joined(separator: ", "))"
        }

        func checkZones(windowWidth: Double) async throws {
            try await waitForFrames(["topBand", "bottomBand", "topLeft", "topRight", "bottomLeft", "bottomRight"])
            let viewport = try #require(scrollViews.first, "\(geometryDetails)").contentView.bounds.width
            let details = geometryDetails
            for (bandID, leftID, rightID) in [
                ("topBand", "topLeft", "topRight"), ("bottomBand", "bottomLeft", "bottomRight"),
            ] {
                let band = try #require(session.layoutFrames[bandID])
                let left = try #require(session.layoutFrames[leftID])
                let right = try #require(session.layoutFrames[rightID])
                #expect(!left.isEmpty && !right.isEmpty, "\(details)")
                #expect(!left.intersects(right), "\(details)")
                #expect(left.minX >= 20 && right.maxX <= windowWidth - 230 - 20, "\(details)")
                #expect(right.maxX <= viewport - 20, "\(details)")
                #expect(left.minX >= band.minX - 1 && right.maxX <= band.maxX + 1, "\(details)")
                // The bottom band has no fixed suffix. Its right zone should actually use the available room.
                if bandID == "bottomBand" { #expect(abs(right.maxX - band.maxX) <= 1, "\(details)") }
            }
        }

        func nextLayout() async {
            // A hosted test can be driving a run-loop mode other than .default.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func waitForFrames(_ keys: [String]) async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            var previous: [String: CGRect] = [:]
            while ContinuousClock.now < deadline {
                await nextLayout()
                let frames = session.layoutFrames.filter { keys.contains($0.key) && !$0.value.isEmpty }
                if frames.count == keys.count, frames == previous { return }
                previous = frames
            }
            let missing = keys.filter { session.layoutFrames[$0]?.isEmpty != false }
            Issue.record("レイアウトの記録が揃わない: missing=\(missing), \(geometryDetails)")
            throw CocoaError(.coderInvalidValue)
        }

        func close() {
            window.close()
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
