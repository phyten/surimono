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
            // In both arrangements there are two 20-point page margins around the full drop target.
            let expected = viewport - 40 - (width == 1100 ? 244 : 0)
            for key in ["topBand", "bottomBand"] {
                let band = try #require(fixture.session.layoutFrames[key])
                #expect(abs(band.width - expected) <= 1, "\(fixture.geometryDetails)")
            }
        }
    }

    #if DEBUG
        @Test(
            "実測座標を使う撮影コマンドで新しい線と配置済みの線を落とし、一手で元に戻せる",
            arguments: ["fixed", "space", "empty", "wrap", "outside"])
        func coordinateDrop(scenario: String) async throws {
            let layouts =
                scenario == "empty"
                ? try #require(DebugSnapshot.bandArrangementFixture(named: "sparse")).activeLayouts
                : BandArrangementVariants()
            let fixture = try Fixture(width: 820, layouts: layouts)
            defer { fixture.close() }
            let session = fixture.session
            if scenario == "fixed" || scenario == "wrap" { session.mode = .top }
            let keys = session.zones.map(\.rawValue) + ["topBand"]
            try await fixture.waitForFrames(keys)
            if scenario == "space" {
                let scroll = try #require(fixture.scrollViews.first)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: 20))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await fixture.waitForFrames(keys)
                #expect(scroll.contentView.bounds.minY > 0)
            }
            let band = try #require(session.layoutFrames["topBand"])
            let left = try #require(session.layoutFrames["topLeft"])
            let right = try #require(session.layoutFrames["topRight"])
            let before = session.draft
            var zone = BandZoneID.topLeft
            var source = "new"
            var index = 0
            let point: CGPoint
            switch scenario {
            case "fixed":
                zone = .topRight
                let lock = try #require(session.dockedMoreFrame)
                index = try #require(session.arrangement.topRight.firstIndex(of: .part(.print)))
                point = CGPoint(x: right.minX + lock.midX, y: right.minY + lock.midY)
            case "space":
                zone = .topRight
                source = "bottomLeft:1"
                #expect(right.minX > left.maxX)
                point = CGPoint(x: right.minX - (right.minX - left.maxX) / 4, y: right.midY)
            case "empty":
                point = CGPoint(x: left.midX, y: left.midY)
            case "wrap":
                zone = .topRight
                let frames = try #require(session.chipFrames[zone])
                let first = try #require(frames.first)
                index = try #require(frames.firstIndex { $0.midY > first.midY + 1 })
                point = CGPoint(x: right.minX + frames[index - 1].maxX + 1, y: right.minY + first.midY)
            default:
                source = "bottomLeft:1"
                point = CGPoint(x: band.midX, y: band.maxY + 10)
            }
            let frame = try #require(session.layoutFrames[zone.rawValue])
            let command = "drop:\(source)@\(zone.rawValue):\(point.x - frame.minX),\(point.y - frame.minY)"
            try await DebugSnapshot.configureArrangementEditor(command, editor: session)
            if scenario == "outside" {
                #expect(session.message == .separatorDeleted)
            } else {
                #expect(session.selection == .separator(zone, index))
                var expected = before.arrangement(for: session.mode)[zone]
                expected.insert(.separator, at: index)
                #expect(session.arrangement[zone] == expected)
            }
            if source != "new" {
                var remaining = before.split.bottomLeft
                remaining.remove(at: 1)
                #expect(session.arrangement.bottomLeft == remaining)
            }
            session.undo()
            #expect(session.draft == before)
        }
    #endif

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
                let first = CGPoint(x: band.minX + 1, y: left.minY + 1)
                let last = CGPoint(x: band.maxX - 1, y: right.midY)
                if let leftZone = BandZoneID(rawValue: leftID), let rightZone = BandZoneID(rawValue: rightID) {
                    #expect(BandEditorDrop.placement(at: first, in: session).target == .zone(leftZone, index: 0))
                    // On a wrapped zone the right edge appends to the pointed line.
                    if case .zone(let zone, _) = BandEditorDrop.placement(at: last, in: session).target {
                        #expect(zone == rightZone)
                    } else {
                        Issue.record("帯の右端がドロップ先になっていない")
                    }
                }
                // The bottom band has no fixed suffix. Its right zone should actually use the available room.
                if bandID == "bottomBand" { #expect(abs(right.maxX + 8 - band.maxX) <= 1, "\(details)") }
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
