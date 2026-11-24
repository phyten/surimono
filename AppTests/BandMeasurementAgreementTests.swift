import AppKit
import Foundation
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

/// The band decides what fits from widths measured out of sight; these tests compare them with what the band draws.
/// Widths come from the host's own labels, so each test sweeps widths around the folds instead of fixing one width
/// for one language.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BandMeasurementAgreementTests {
    /// The bands and their measuring copy, with the band's width following the window as in the view mode.
    private struct TestBands: View {
        @Bindable var model: DocumentViewModel
        let menu: OverlayMenuState
        let labels: BandLabelMeasurements

        var body: some View {
            let plans = BandPlans(model: model, menu: menu)
            VStack {
                OverlayBand(model: model, menu: menu, plans: plans)
                Spacer()
                if let row = plans.bottom { BottomBand(model: model, row: row) }
            }
            .environment(\.bandLabelMeasurements, labels)
            .background { BandMeasurements(model: model, items: BandLayout.Item.applicable(for: model), menu: menu) }
            .coordinateSpace(name: BandAnchors.coordinateSpace)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: { width in
                if menu.bandWidth != width { menu.bandWidth = width }
            }
            .recordingBandPlan(plans.resolved, in: model.bandAnchors)
        }
    }

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = BandTestDefaultsSuite()
        let model: DocumentViewModel
        let menu = OverlayMenuState()
        let labels = BandLabelMeasurements()
        let controller: NSWindowController
        let window: NSWindow

        /// A Markdown file named as in the screenshots, with the given parts before Print at the top right of Split.
        init(parts: [BandLayout.Item], width: CGFloat, corners: CornerPreset = .standard, imageBundle: Bool = false)
            throws
        {
            let preferences = AppPreferences(defaults: defaults.defaults)
            preferences.corners = corners
            preferences.menuArrangement = .split
            var layouts = BandArrangementVariants()
            for item in parts {
                layouts.split = try layouts.split.moving(item, to: .zone(.topRight), before: .print, for: .split)
            }
            try preferences.saveBandArrangement(.init(name: "Parts", layouts: layouts))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(imageBundle ? "A.png" : "booklet-demo.md")
            let data = imageBundle ? TestFixtures.png(red: 0) : Data("# Toolbar\n\nA paragraph to paginate.\n".utf8)
            var bundle: ImageBundleModel?
            if imageBundle {
                let second = directory.appendingPathComponent("B.png")
                try TestFixtures.png(red: 1).write(to: second)
                bundle = ImageBundleModel(urls: [url, second])
            }
            try data.write(to: url)
            model = DocumentViewModel(
                data: data, fileURL: url, format: imageBundle ? .image : .markdown, preferences: preferences,
                library: UserLibrary(root: directory.appendingPathComponent("Library")),
                imageBundle: bundle,
                settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
            model.isolateBandTestOutput()
            menu.hasReadTrafficLights = true
            model.isBandAlwaysVisible = true
            window = NSWindow(
                contentRect: NSRect(x: 20, y: 20, width: width, height: 300), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            controller = NSWindowController(window: window)
            let host = NSHostingView(rootView: TestBands(model: model, menu: menu, labels: labels))
            // As the view mode's window: the band never widens the window to fit what the plan folded away.
            host.sizingOptions = []
            window.contentView = host
            window.alphaValue = 0
            window.orderFrontRegardless()
        }

        func close() {
            controller.close()
            model.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        var plan: BandResolvedPlan? { model.bandAnchors.plan }

        /// The file name's drawn width: it ends the title's gap before the format badge, after the traffic lights.
        var drawnNameWidth: CGFloat? {
            guard let plan, plan.top.showsName, plan.top.forms[.formatBadge] != nil,
                let badge = model.bandAnchors.frames[.item(.formatBadge)]
            else { return nil }
            let gap = plan.top.geometry.gapsBefore[.formatBadge] ?? 0
            return badge.minX - gap - (OverlayBand.lightsRoom(nil) + OverlayBand.spacing)
        }
    }

    // Yield to AppKit's run loop, not only the cooperative executor. Non-key hosting views need a layout pass.
    private func nextLayout(in window: NSWindow) async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) { continuation.resume() }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    /// Lays the band out at the width until its plan, measurements and drawn places stop changing.
    private func settle(_ fixture: Fixture, width: CGFloat) async throws {
        fixture.window.setContentSize(CGSize(width: width, height: 300))
        var previous: (BandResolvedPlan?, [BandSlot: CGFloat], [BandAnchors.Anchor: CGRect])?
        var unchanged = 0
        let deadline = ContinuousClock.now + .seconds(5)
        while unchanged < 3, ContinuousClock.now < deadline {
            await nextLayout(in: fixture.window)
            let current = (fixture.plan, fixture.menu.bandWidths, fixture.model.bandAnchors.frames)
            let ready = fixture.menu.bandWidth == width && current.0 != nil && fixture.menu.bandWidths[.name] != nil
            if ready, let previous, previous.0 == current.0, previous.1 == current.1, previous.2 == current.2 {
                unchanged += 1
            } else {
                unchanged = 0
            }
            previous = current
        }
        try #require(unchanged >= 3, "幅 \(width) で帯が落ち着かない")
    }

    nonisolated private static let sixParts: [BandLayout.Item] = [
        .readingDirection, .scrollDirection, .paperOrientation, .margins, .printSettings, .saveAsFile,
    ]

    @Test("部品の表示を変えると開いている画像の束の上下の帯は同じ幅のまま切り替わる")
    func namesChangeInOpenWindow() async throws {
        let fixture = try Fixture(parts: [], width: 1000, imageBundle: true)
        defer { fixture.close() }
        // Keep the document and the window width fixed so only a preference change can switch the forms.
        for names in [BandLayout.Names.shown, .hidden, .shown] {
            fixture.model.preferences.bandNames = names
            try await settle(fixture, width: 1000)
            let plan = try #require(fixture.plan)
            let form: BandLayout.Form = names == .hidden ? .compact : .full
            #expect(plan.top.forms[.print] == form)
            #expect(plan.bottom?.forms[.thumbnails] == form)
            let measured = try #require(fixture.menu.bandWidths[.item(.thumbnails, form)])
            let drawn = try #require(fixture.model.bandAnchors.frames[.item(.thumbnails)])
            #expect(measured > 0 && abs(drawn.width - measured) <= 1)
        }
    }

    @Test("画像の束では実測した文字つきの入口が先にアイコンになり、描画幅も実測幅に合う")
    func measuredBundleEntry() async throws {
        let fixture = try Fixture(parts: [], width: 1000, imageBundle: true)
        defer { fixture.close() }
        fixture.model.start()
        for _ in 0..<500 where !fixture.model.isUpToDate { try await Task.sleep(for: .milliseconds(20)) }
        try #require(fixture.model.pageCount == 2)
        try await settle(fixture, width: 1000)
        let full = try #require(fixture.menu.bandWidths[.item(.thumbnails, .full)])
        let compact = try #require(fixture.menu.bandWidths[.item(.thumbnails, .compact)])
        try #require(full > compact && compact > 0)
        let row = try #require(fixture.plan?.bottom)
        #expect(row.forms[.thumbnails] == .full)
        let frame = try #require(fixture.model.bandAnchors.frames[.item(.thumbnails)])
        let layout = try #require(fixture.model.bandAnchors.frames[.item(.layout)])
        #expect(abs(frame.width - full) <= 1 && frame.maxX <= layout.minX)
        try #require(row.showsScrubber)
        try await settle(fixture, width: row.requiredWidth.rounded(.up) - 1)
        #expect(fixture.plan?.bottom?.showsScrubber == false)
        #expect(fixture.plan?.bottom?.forms[.thumbnails] == .full)

        // Use the measured labels for this locale to locate the fold, then actually resize and draw it.
        let width = try #require(
            (1...1000).reversed().first { width in
                BandPlans(model: fixture.model, menu: fixture.menu, availableWidth: CGFloat(width))
                    .bottom?.forms[.thumbnails] == .compact
            })
        // The window cannot be made this narrow (its minimum keeps the paper readable), so the compact entry is not
        // drawn here; the plan built from the real measurements is what decides it.
        let plan = try #require(
            BandPlans(model: fixture.model, menu: fixture.menu, availableWidth: CGFloat(width)).bottom)
        #expect(plan.forms[.thumbnails] == .compact)
        #expect(plan.forms[.layout] == .full)
    }

    @Test("新しい部品を6つ置いた帯は、ファイル名を切る前に新しい部品を絵だけにする")
    func addedPartsYieldBeforeName() async throws {
        let fixture = try Fixture(parts: Self.sixParts, width: 1100)
        defer { fixture.close() }
        var sawCompactWithFullName = false
        var sawShortName = false
        for width in stride(from: CGFloat(1100), through: 440, by: -5) {
            try await settle(fixture, width: width)
            let plan = try #require(fixture.plan)
            let natural = try #require(fixture.menu.bandWidths[.name])
            guard let name = fixture.drawnNameWidth else { continue }
            let added = Self.sixParts.filter { plan.top.forms[$0] != nil }
            let fullAdded = added.filter { plan.top.forms[$0] == .full }
            if name < natural - 1 {
                sawShortName = true
                #expect(fullAdded.isEmpty, "幅 \(width): 名前が \(name)/\(natural) に切れたのに名前つきの新しい部品 \(fullAdded)")
            } else if fullAdded.count < added.count {
                sawCompactWithFullName = true
            }
        }
        // The sweep crossed both folds: new parts went to icons while the name was whole, then the name shrank.
        #expect(sawCompactWithFullName)
        #expect(sawShortName)
    }

    @Test("角の丸みごとに実測した標準の帯が最小幅から900ptまで収まる", arguments: CornerPreset.allCases, MenuArrangement.allCases)
    func defaultBandFits(corners: CornerPreset, mode: MenuArrangement) async throws {
        let fixture = try Fixture(parts: [], width: 1000, corners: corners)
        defer { fixture.close() }
        fixture.model.preferences.menuArrangement = mode
        try await settle(fixture, width: 1000)
        let measured = OverlayMenuState()
        measured.hasReadTrafficLights = true
        measured.bandWidths = fixture.menu.bandWidths
        for slot: BandSlot in [.name, .item(.layout, .full), .item(.print, .full), .item(.print, .compact)] {
            try #require((measured.bandWidths[slot] ?? 0) > 0)
        }
        for width in 1...900 {
            measured.bandWidth = CGFloat(width)
            let plans = BandPlans(model: fixture.model, menu: measured)
            for row in [plans.top, plans.bottom].compactMap({ $0 }) {
                #expect(row.requiredWidth <= max(row.minimumWidth, CGFloat(width)) + 0.01)
            }
        }
    }

    @Test(
        "帯に描いた部品と「…」の幅は、見えない所で測った同じ形の幅より1ptを超えて広くならず、2ptを超えて狭くならない",
        arguments: [CGFloat(1800), 640], CornerPreset.allCases)
    func drawnWidthsMatchMeasured(width: CGFloat, corners: CornerPreset) async throws {
        let fixture = try Fixture(parts: BandTestCatalog.addedItems, width: width, corners: corners)
        defer { fixture.close() }
        try await settle(fixture, width: width)
        let plan = BandPlans(model: fixture.model, menu: fixture.menu).resolved
        #expect(fixture.plan == plan, "描いた計画 \(String(describing: fixture.plan))、現在の計画 \(plan)")
        let rows = [plan.top] + (plan.bottom.map { [$0] } ?? [])
        var compared = 0
        for row in rows {
            for item in row.leading + row.trailing {
                let form = try #require(row.forms[item])
                let measured = try #require(fixture.menu.bandWidths[.item(item, form)], "\(item) \(form) を測っていない")
                let drawn = try #require(fixture.model.bandAnchors.frames[.item(item)], "\(item) を描いていない")
                // Wider than measured is what breaks the band (the name gets squeezed), so that way has one point of
                // slack. Narrower only leaves room: a native segmented control draws two points narrower than its
                // hidden copy measures on a Retina screen (56 against 54), and as wide as it on a 1x screen.
                let excess = drawn.width - measured
                let label = fixture.labels.drawn[item]
                if [.selectText, .viewOptions].contains(item) {
                    // Both controls add only a three-point gap and the title to their compact symbol.
                    let compact = try #require(fixture.menu.bandWidths[.item(item, .compact)])
                    let minimum = form == .full ? max(1, measured - compact - 3 - 2) : 1
                    #expect(
                        label?.form == form && (label?.width ?? 0) >= minimum,
                        "\(item): 計画 \(form)、実際の文字またはアイコン \(String(describing: label))、必要幅 \(minimum)")
                }
                #expect(
                    excess <= 1 && excess >= -2,
                    "\(item) \(form): 測った \(measured)、アンカー \(drawn)、文字またはアイコン \(String(describing: label))、帯 \(row.requiredWidth)/\(width)"
                )
                compared += 1
            }
        }
        let more = try #require(fixture.model.bandAnchors.frames[.more])
        let measuredMore = try #require(fixture.menu.bandWidths[.more])
        #expect(abs(more.width - measuredMore) <= 1, "「…」: 測った \(measuredMore)、描いた \(more.width)")
        #expect(compared >= 10)
        if width < 1000 {
            // The narrow width really draws the icon forms of the new parts.
            #expect(BandTestCatalog.addedItems.contains { plan.top.forms[$0] == .compact })
        }
    }

    @Test(
        "畳んでいく帯で、描いたファイル名は計画の幅を1pt以上下回らず、最小の80ptを保つ",
        arguments: [BandTestCatalog.addedItems, sixParts], CornerPreset.allCases)
    func nameKeepsPlannedWidth(parts: [BandLayout.Item], corners: CornerPreset) async throws {
        let fixture = try Fixture(parts: parts, width: 760, corners: corners)
        defer { fixture.close() }
        var sawMinimum = false
        for width in stride(from: CGFloat(760), through: 380, by: -4) {
            try await settle(fixture, width: width)
            let plan = try #require(fixture.plan)
            guard let name = fixture.drawnNameWidth else { continue }
            #expect(name >= plan.top.nameWidth - 1, "幅 \(width): 計画 \(plan.top.nameWidth)、描いた \(name)")
            // While the format badge is still on the band, the plan has not taken the steps that may go below 80.
            #expect(name >= 79, "幅 \(width): 名前が最小の80ptより狭い \(name)")
            // Within one step of the sweep from the floor.
            if plan.top.nameWidth < 84 { sawMinimum = true }
        }
        #expect(sawMinimum)
    }
}
