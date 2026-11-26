import AppKit
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BandAdditionalPartsTests {
    /// Actual bands and their measuring copies, kept visible so the Always Show toggle can be inspected both ways.
    private struct TestBands: View {
        @Bindable var model: DocumentViewModel
        let menu: OverlayMenuState
        var body: some View {
            let plans = BandPlans(model: model, menu: menu)
            VStack {
                OverlayBand(model: model, menu: menu, plans: plans)
                Spacer()
                if let row = plans.bottom { BottomBand(model: model, row: row) }
            }
            .background { BandMeasurements(model: model, items: BandLayout.Item.applicable(for: model), menu: menu) }
            .overlay { BandPresentationHost(model: model, plans: plans) }
            .coordinateSpace(name: BandAnchors.coordinateSpace)
            .recordingBandPlan(plans.resolved, in: model.bandAnchors)
        }
    }

    @MainActor private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = BandTestDefaultsSuite()
        let preferences: AppPreferences
        let model: DocumentViewModel
        let menu = OverlayMenuState()
        let controller: NSWindowController
        let window: NSWindow
        var saveDestinationRequests = 0

        init(
            parts: [BandLayout.Item], compact: Bool = false, measurementsOnly: Bool = false,
            documentContent: Bool = false, width: CGFloat = 1800, accessibilityEnabled: Bool = false
        ) throws {
            preferences = AppPreferences(defaults: defaults.defaults)
            preferences.menuArrangement = .split
            var layouts = BandArrangementVariants()
            for item in parts {
                layouts.split = try layouts.split.moving(item, to: .zone(.topRight), before: .print, for: .split)
            }
            try preferences.saveBandArrangement(.init(name: "Chips", layouts: layouts))
            let html = !documentContent && parts.contains(.ignoreSlides)
            let data =
                documentContent
                ? Data("# Toolbar\n\nA paragraph to paginate.\n".utf8)
                : html ? Data("<h1>Slides</h1>".utf8) : TestFixtures.textPDF(["First", "Second"])
            let url = html ? directory.appendingPathComponent("slides.html") : nil
            if let url {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url)
            }
            model = DocumentViewModel(
                data: data, fileURL: url, format: documentContent ? .markdown : html ? .html : .pdf,
                preferences: preferences, library: UserLibrary(root: directory.appendingPathComponent("Library")),
                settingsStore: DocumentSettingsStore(directory: directory.appendingPathComponent("Settings")))
            model.isolateBandTestOutput()
            if !documentContent {
                // Isolated chips use a fixed width. A real document must report its own traffic lights and width.
                menu.hasReadTrafficLights = true
                menu.bandWidth = compact ? 440 : width
            }
            model.isBandAlwaysVisible = true
            if parts.contains(.cover) { model.updateViewOptions { $0.layout = .spread } }
            if html {
                model.setHTMLPresentation(.paper, capturesWeb: false)
                model.slideDeckDidChange(SlideDeck(size: CGSize(width: 1280, height: 720), count: 3, currentIndex: 0))
            }
            window = NSWindow(
                contentRect: NSRect(x: 20, y: 20, width: width, height: 500),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            controller = NSWindowController(window: window)
            if measurementsOnly {
                window.contentView = NSHostingView(
                    rootView: BandMeasurements(model: model, items: BandTestCatalog.addedItems, menu: menu))
            } else if documentContent {
                window.contentView = NSHostingView(rootView: DocumentContent(model: model, bandMenu: menu))
            } else if accessibilityEnabled {
                window.contentView = NSHostingView(
                    rootView: TestBands(model: model, menu: menu).environment(\.accessibilityEnabled, true))
            } else {
                window.contentView = NSHostingView(rootView: TestBands(model: model, menu: menu))
            }
            model.chooseSaveDestination = { [weak self] _, completion in
                self?.saveDestinationRequests += 1
                completion(nil)
            }
            if measurementsOnly { window.alphaValue = 0 }
            window.orderFrontRegardless()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func close() {
            controller.close()
            model.stop()
            try? FileManager.default.removeItem(at: directory)
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

    private func waitUntil(
        _ reason: String, fixture: Fixture, _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        // A real document is laid out by a web content process, which starts slowly on a busy CI runner.
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition(), ContinuousClock.now < deadline { await nextLayout(in: fixture.window) }
        let plan = BandPlans(model: fixture.model, menu: fixture.menu)
        try #require(
            condition(),
            Comment(
                rawValue: "待機: \(reason); visible=\(fixture.window.isVisible), key=\(fixture.window.isKeyWindow), "
                    + "applicable=\(BandLayout.Item.applicable(for: fixture.model)), top=\(plan.top.forms), "
                    + "drawnPlan=\(String(describing: fixture.model.bandAnchors.plan)), width=\(fixture.menu.bandWidth), saveRequests=\(fixture.saveDestinationRequests), AX=\((fixture.window.contentView.map(elements) ?? []).compactMap { $0.accessibilityIdentifier() })"
            ),
            sourceLocation: sourceLocation)
    }

    private func elements(_ root: Any) -> [any NSAccessibilityProtocol] {
        var visited = Set<ObjectIdentifier>()
        func walk(_ value: Any) -> [any NSAccessibilityProtocol] {
            guard let element = value as? any NSAccessibilityProtocol,
                visited.insert(ObjectIdentifier(element)).inserted
            else { return [] }
            if let view = value as? NSView, view.isHiddenOrHasHiddenAncestor { return [] }
            // Native menus and SwiftUI's virtual nodes do not necessarily share the window's AX children.
            let children = (element.accessibilityChildren() ?? []) + ((value as? NSView)?.subviews ?? [])
            return [element] + children.flatMap(walk)
        }
        return walk(root)
    }

    /// Where the real chip stands, in window coordinates (bottom-left origin), once the band has drawn it.
    ///
    /// SwiftUI builds its accessibility tree only for an accessibility client, and the test host has none, so the
    /// chip is found by the place the band recorded for its popovers and operated with a real click there.
    private func chipFrame(_ item: BandLayout.Item, in fixture: Fixture) -> CGRect? {
        guard fixture.model.bandAnchors.plan?.band(of: item) != nil,
            let frame = fixture.model.bandAnchors.frames[.item(item)], !frame.isEmpty,
            let content = fixture.window.contentView
        else { return nil }
        let y = content.isFlipped ? content.bounds.minY + frame.minY : content.bounds.maxY - frame.maxY
        let rect = CGRect(x: content.bounds.minX + frame.minX, y: y, width: frame.width, height: frame.height)
        return content.convert(rect, to: nil)
    }

    /// A click as AppKit delivers it, at the middle of the chip.
    private func click(_ item: BandLayout.Item, in fixture: Fixture) throws {
        let frame = try #require(chipFrame(item, in: fixture))
        let point = NSPoint(x: frame.midX, y: frame.midY)
        if let button = fixture.window.contentView?.hitTest(point) as? NSButton {
            // The native button tracks synchronously. Exercise the action of the control actually hit at the chip.
            button.performClick(nil)
            return
        }
        try TestWindowMouse.click(at: point, in: fixture.window)
    }

    @Test(
        "配置した切り替えは、実際のチップをクリックするとモデルの状態が変わる",
        arguments: [BandLayout.Item.selectText, .alwaysShowToolbar, .cover, .ignoreSlides])
    func toggleThroughChip(item: BandLayout.Item) async throws {
        let fixture = try Fixture(parts: [item])
        defer { fixture.close() }
        // The test host is the active app on a CI runner and a background app on a developer's Mac, so the check is
        // that the clicks leave the app's activation as it was.
        let wasActive = NSApp.isActive
        #expect(BandLayout.Item.applicable(for: fixture.model).contains(item))
        #expect(BandPlans(model: fixture.model, menu: fixture.menu).band(of: item) == .top)
        try await waitUntil("\(item): 帯が実際のチップの位置を記録する", fixture: fixture) {
            chipFrame(item, in: fixture) != nil
        }
        let id = try #require(BandMenuContent.ID(rawValue: item.rawValue))
        let before = try #require(BandMenuContent(model: fixture.model).entry(id).isChecked)
        try click(item, in: fixture)
        try await waitUntil("\(item): クリックの後にモデルの状態が反転する", fixture: fixture) {
            BandMenuContent(model: fixture.model).entry(id).isChecked == !before
        }
        // A second click puts it back: the chip is bound to the state, not a one-way trigger.
        try await waitUntil("\(item): 反転後もチップが帯にある", fixture: fixture) { chipFrame(item, in: fixture) != nil }
        try click(item, in: fixture)
        try await waitUntil("\(item): もう一度のクリックで元に戻る", fixture: fixture) {
            BandMenuContent(model: fixture.model).entry(id).isChecked == before
        }
        #expect(NSApp.isActive == wasActive)
    }

    @Test("スクロールのチップは方向だけでなくスクロールを明記し詳細メニューの値を変えない")
    func scrollChipLabel() throws {
        let fixture = try Fixture(parts: [], measurementsOnly: true)
        defer { fixture.close() }
        let chip = BandAdditionalPart(model: fixture.model, item: .scrollDirection, form: .full)
        for axis in [ViewOptions.ScrollAxis.vertical, .horizontal] {
            fixture.model.viewOption(\.scrollAxis).wrappedValue = axis
            let entry = BandMenuContent(model: fixture.model).entry(.scrollDirection)
            #expect(
                chip.labelText(entry)
                    == (axis == .vertical
                        ? String(localized: "Vertical Scroll") : String(localized: "Horizontal Scroll")))
            #expect(
                entry.value == (axis == .vertical ? String(localized: "Vertical") : String(localized: "Horizontal")))
        }
    }

    @Test("印刷設定と余白は共通の線の記号を使い確認件数の例はミニチュアだけに出す")
    func reviewedGlyphs() {
        #expect(BandLayout.Item.printSettings.additionalSymbol == "doc.badge.gearshape")
        #expect(BandLayout.Item.margins.additionalSymbol == "rectangle.dashed")
        #expect(BandPartGlyph(item: .beforePrinting).sampleIssueCount == 2)
        #expect(BandPartGlyph(item: .beforePrinting, besideName: true).sampleIssueCount == nil)
    }

    @Test("配置した読む向きは帯に描かれ、チップと「…」が共有する選択で値と表示が変わる")
    func choiceChip() async throws {
        let fixture = try Fixture(parts: [.readingDirection])
        defer { fixture.close() }
        #expect(BandPlans(model: fixture.model, menu: fixture.menu).band(of: .readingDirection) == .top)
        try await waitUntil("帯が読む向きのチップの位置を記録する", fixture: fixture) {
            chipFrame(.readingDirection, in: fixture) != nil
        }
        // The chip's menu is SwiftUI's own: opening it runs a modal tracking loop, which a test cannot leave. The
        // chip and the "…" menu draw the same `BandPartChoices`, whose picker is bound to this view option.
        let entry = { BandMenuContent(model: fixture.model).entry(.readingDirection) }
        #expect(entry().value == String(localized: "Left to Right"))
        fixture.model.viewOption(\.direction).wrappedValue = .rightToLeft
        #expect(fixture.model.viewOptions.direction == .rightToLeft)
        #expect(entry().value == String(localized: "Right to Left"))
        try await waitUntil("値が変わってもチップは帯に残る", fixture: fixture) {
            chipFrame(.readingDirection, in: fixture) != nil
        }
    }

    @Test("測定だけの全形態はアクセシビリティとアンカーとドロップ位置とポップオーバーを作らない")
    func measurementIsInert() async throws {
        let fixture = try Fixture(parts: [], measurementsOnly: true)
        defer { fixture.close() }
        let dropFrame = fixture.model.drop.listButtonFrame
        fixture.model.isViewOptionsPresented = true
        fixture.model.isPrintFinishPresented = true
        try await waitUntil("14部品のfull/compactの計測", fixture: fixture) {
            BandTestCatalog.addedItems.allSatisfy {
                fixture.menu.bandWidths[.item($0, .full)] != nil && fixture.menu.bandWidths[.item($0, .compact)] != nil
            }
        }
        let measuredNodes = (fixture.window.contentView.map(elements) ?? []).filter {
            $0.accessibilityIdentifier()?.hasPrefix("band.part.") == true
        }
        #expect(measuredNodes.isEmpty)
        #expect(fixture.model.bandAnchors.frames.isEmpty)
        #expect(fixture.model.drop.listButtonFrame == dropFrame)
        #expect(fixture.window.childWindows?.isEmpty != false)
        #expect(fixture.saveDestinationRequests == 0)
    }

    @Test("表示のオプションは実表示の上下チップに付き未使用と幅不足と枠未取得では詳細へ戻る")
    func viewOptionsPlacement() throws {
        let fixture = try Fixture(parts: [.viewOptions])
        defer { fixture.close() }
        let chip = CGRect(x: 320, y: 8, width: 90, height: 24)
        let more = CGRect(x: 500, y: 8, width: 24, height: 24)
        let frames: [BandAnchors.Anchor: CGRect] = [.item(.viewOptions): chip, .more: more]
        fixture.menu.bandWidths[.item(.viewOptions, .full)] = 90
        fixture.menu.bandWidths[.item(.viewOptions, .compact)] = 24
        func placement(_ frames: [BandAnchors.Anchor: CGRect]) -> BandPresentationHost.Placement {
            BandPresentationHost.placement(
                of: .viewOptions, plans: BandPlans(model: fixture.model, menu: fixture.menu), frames: frames)
        }
        #expect(placement(frames) == .init(rect: chip, arrowEdge: .bottom))
        #expect(placement([.more: more]) == .init(rect: more, arrowEdge: .bottom))
        #expect(placement([:]) == .init(rect: nil, arrowEdge: .bottom))
        // Opening through the complete index uses exactly the same host and placement.
        BandMenuContent(model: fixture.model).perform(.viewOptions)
        #expect(fixture.model.isViewOptionsPresented)
        var layouts = fixture.preferences.bandArrangementStore.activeLayouts
        layouts.split = try layouts.split.moving(.viewOptions, to: .zone(.bottomRight), for: .split)
        try fixture.preferences.saveBandArrangement(.init(name: "Bottom", layouts: layouts))
        #expect(placement(frames) == .init(rect: chip, arrowEdge: .top))
        fixture.menu.bandWidth = 1
        #expect(placement(frames) == .init(rect: more, arrowEdge: .bottom))
        fixture.menu.bandWidth = 1800
        #expect(placement(frames) == .init(rect: chip, arrowEdge: .top))
        layouts.split = try layouts.split.moving(.viewOptions, to: .unused, for: .split)
        try fixture.preferences.saveBandArrangement(.init(name: "Unused", layouts: layouts))
        #expect(placement(frames) == .init(rect: more, arrowEdge: .bottom))
        #expect(fixture.model.isViewOptionsPresented)
    }

    @Test("ファイル保存チップは注入した保存先選択だけを呼ぶ")
    func saveThroughChip() async throws {
        let fixture = try Fixture(
            parts: [.saveAsFile], width: min(NSScreen.main?.visibleFrame.width ?? 800, 1000) - 40,
            accessibilityEnabled: true)
        defer { fixture.close() }
        #expect(fixture.model.canSaveAsFile)
        #expect(BandPlans(model: fixture.model, menu: fixture.menu).band(of: .saveAsFile) == .top)
        try await waitUntil("帯が保存チップの位置を記録する", fixture: fixture) {
            chipFrame(.saveAsFile, in: fixture) != nil
        }
        if #available(macOS 26, *) {
            try click(.saveAsFile, in: fixture)
        } else {
            // On the Sequoia runner the synthetic down reaches the hosting view but does not activate its
            // SwiftUI button. Press the actual visible control through its public accessibility action.
            let host = try #require(fixture.window.contentView)
            let frame = try #require(chipFrame(.saveAsFile, in: fixture))
            func controls() -> [any NSAccessibilityProtocol] {
                let buttons = elements(host).filter {
                    $0.isAccessibilityEnabled()
                        && fixture.window.convertFromScreen($0.accessibilityFrame()).contains(
                            CGPoint(x: frame.midX, y: frame.midY))
                }
                let marked = buttons.filter { $0.accessibilityIdentifier() == "band.part.saveAsFile" }
                if !marked.isEmpty { return marked }
                return buttons.filter {
                    $0.accessibilityRole() == .button
                        && [$0.accessibilityTitle(), $0.accessibilityLabel()].contains(
                            BandLayout.Item.saveAsFile.editorName)
                }
            }
            try await waitUntil("表示中の保存ボタンがアクセシビリティ操作を公開する", fixture: fixture) { !controls().isEmpty }
            let matches = controls()
            try #require(matches.count == 1, "\(OrgReadingTestWindow.diagnostic(in: host))")
            try #require(matches[0].accessibilityPerformPress(), "保存チップが押下を受理する")
        }
        try await waitUntil("実保存チップから注入した保存先選択を1回呼ぶ", fixture: fixture) {
            fixture.saveDestinationRequests == 1
        }
        #expect(fixture.window.attachedSheet == nil)
    }

    @Test(
        "全14部品と撮影停止した6部品の配置で実文書の帯と組版が安定する",
        arguments: [
            BandTestCatalog.addedItems,
            [.paperOrientation, .paperSeries, .cover, .alwaysShowToolbar, .printSettings, .keysAndGestures],
        ], [CGFloat(707), 1800])
    func allPartsSettle(parts: [BandLayout.Item], width: CGFloat) async throws {
        let fixture = try Fixture(parts: parts, documentContent: true, width: width)
        defer { fixture.close() }
        try await waitUntil("\(parts): 実文書の組版完了と帯の計画", fixture: fixture) {
            fixture.model.isUpToDate && fixture.model.bandAnchors.plan != nil
        }
        let settings = fixture.model.renderSettings
        let options = fixture.model.viewOptions
        let renders = fixture.model.renderStartCount
        try await waitUntil("章のページ照合と最初のウインドウ調整が完了する", fixture: fixture) {
            // The outline task publishes the chapter and contents chips after pagination finishes.
            fixture.model.isUpToDate && fixture.model.chapterEntries.first?.pageIndex == 0
                && fixture.model.hasSizedWindow && !ViewerWindow.isResizingProgrammatically(fixture.window)
        }
        fixture.window.setContentSize(CGSize(width: width, height: 500))
        try await waitUntil("表示幅、信号機と全チップの実測が描画済みの計画に反映される", fixture: fixture) {
            let menu = fixture.menu
            let items = BandLayout.Item.applicable(for: fixture.model)
            guard menu.hasReadTrafficLights, menu.bandWidth == width,
                menu.bandWidths[.name] != nil, menu.bandWidths[.more] != nil,
                items.allSatisfy({ item in
                    menu.bandWidths[.item(item, .full)] != nil
                        && (!item.hasCompactForm || menu.bandWidths[.item(item, .compact)] != nil)
                })
            else { return false }
            return BandPlans(model: fixture.model, menu: menu).resolved == fixture.model.bandAnchors.plan
        }
        var previous: BandResolvedPlan?
        var unchangedPasses = 0
        try await waitUntil("組版完了後に4回のレイアウトで同じ帯の計画", fixture: fixture) {
            let current = fixture.model.bandAnchors.plan
            if current != nil, current == previous, fixture.model.isUpToDate {
                unchangedPasses += 1
            } else {
                unchangedPasses = 0
            }
            previous = current
            return unchangedPasses >= 4
        }
        var plan = try #require(fixture.model.bandAnchors.plan)
        #expect(fixture.model.isBandAlwaysVisible)
        #expect(
            fixture.preferences.activeBandArrangement.topRight.compactMap(\.item)
                == parts + [.print])
        // Exercise repeated native layout passes after rendering, including the orientation label's final value.
        // On a busy machine a measurement may still arrive after the four quiet passes above, so the plan may take
        // it once or twice; what must not happen is a plan that keeps changing, or a layout that starts a render.
        var changes: [String] = []
        var quietPasses = 0
        for _ in 0..<24 {
            await nextLayout(in: fixture.window)
            let current = try #require(fixture.model.bandAnchors.plan)
            if current == plan {
                quietPasses += 1
            } else {
                changes.append(Self.difference(plan, current))
                plan = current
                quietPasses = 0
            }
            #expect(fixture.model.isUpToDate)
            #expect(fixture.model.renderSettings == settings)
            #expect(fixture.model.viewOptions == options)
            #expect(fixture.model.isBandAlwaysVisible)
            #expect(fixture.model.renderStartCount == renders)
            #expect(!fixture.model.isPrintFinishPresented)
            #expect(fixture.saveDestinationRequests == 0)
        }
        #expect(changes.count <= 2, "帯の計画が変わり続けた: \(changes)")
        #expect(quietPasses >= 8, "帯の計画が最後まで落ち着かなかった: \(changes)")
    }

    /// What differs between two plans, short enough to read in a CI log.
    private static func difference(_ old: BandResolvedPlan, _ new: BandResolvedPlan) -> String {
        var parts: [String] = []
        func row(_ name: String, _ old: BandRowPlan?, _ new: BandRowPlan?) {
            guard old != new else { return }
            guard let old, let new else {
                parts.append("\(name): \(old == nil ? "none" : "row") -> \(new == nil ? "none" : "row")")
                return
            }
            if old.leading != new.leading {
                parts.append("\(name).leading \(old.leading.map(\.rawValue)) -> \(new.leading.map(\.rawValue))")
            }
            if old.trailing != new.trailing {
                parts.append("\(name).trailing \(old.trailing.map(\.rawValue)) -> \(new.trailing.map(\.rawValue))")
            }
            for item in BandLayout.Item.allCases where old.forms[item] != new.forms[item] {
                parts.append(
                    "\(name).form \(item.rawValue) \(String(describing: old.forms[item])) -> "
                        + "\(String(describing: new.forms[item]))")
            }
            if old.nameWidth != new.nameWidth { parts.append("\(name).nameWidth \(old.nameWidth) -> \(new.nameWidth)") }
            if old.minimumWidth != new.minimumWidth {
                parts.append("\(name).minimumWidth \(old.minimumWidth) -> \(new.minimumWidth)")
            }
            if old.requiredWidth != new.requiredWidth {
                parts.append("\(name).requiredWidth \(old.requiredWidth) -> \(new.requiredWidth)")
            }
            if old.geometry != new.geometry { parts.append("\(name).geometry") }
        }
        row("top", old.top, new.top)
        row("bottom", old.bottom, new.bottom)
        if old.overflow != new.overflow {
            parts.append("overflow \(old.overflow.map(\.rawValue)) -> \(new.overflow.map(\.rawValue))")
        }
        if old.unusedAvailable != new.unusedAvailable {
            parts.append(
                "unusedAvailable \(old.unusedAvailable.map(\.rawValue)) -> \(new.unusedAvailable.map(\.rawValue))")
        }
        return parts.joined(separator: "; ")
    }

    @Test("切り替えの同じ値の書き戻しは状態を反転させない")
    func toggleWritesAreIdempotent() throws {
        let fixture = try Fixture(parts: [.selectText, .alwaysShowToolbar, .cover, .ignoreSlides])
        defer { fixture.close() }
        fixture.model.viewOptions.layout = .spread
        let content = BandMenuContent(model: fixture.model)
        for id in [BandMenuContent.ID.selectText, .alwaysShowToolbar, .cover, .ignoreSlides] {
            for value in [true, false] {
                content.setChecked(value, for: id)
                content.setChecked(value, for: id)
                #expect(content.entry(id).isChecked == value)
            }
        }
    }

    @Test(
        "手書きの全撮影見本は省略した新部品を未使用へ補って有効になる",
        arguments: ["printBottom", "reordered", "sparse", "editor", "editorReading"])
    func allDebugFixtures(name: String) throws {
        let store = try #require(DebugSnapshot.bandArrangementFixture(named: name))
        #expect(!store.sets.isEmpty)
        for set in store.sets {
            for mode in MenuArrangement.allCases {
                let layout = set.layouts.arrangement(for: mode)
                #expect(BandArrangementValidation.issues(in: layout, for: mode).isEmpty)
                #expect(BandTestCatalog.addedItems.allSatisfy { layout.unused.contains($0) })
            }
        }
    }

    @Test("撮影用配置は指定順で上の右へ置き残りの標準配置を保つ")
    func debugFixture() throws {
        let fixture = try #require(DebugSnapshot.bandPartsFixture("readingDirection,selectText,viewOptions,margins"))
        #expect(
            fixture.activeLayouts.split.topRight == [
                .part(.readingDirection), .part(.selectText), .part(.viewOptions), .part(.margins),
                .part(.print),
            ])
        #expect(fixture.activeLayouts.top == .standard(for: .top))
        #expect(fixture.activeLayouts.split.bottomLeft == BandArrangement.standard(for: .split).bottomLeft)
        #expect(fixture.sets.first?.name == "Band Parts")
        #expect(DebugSnapshot.bandPartsFixture("unknownPart") == nil)
    }

    @Test("全ての新部品に実在するシンボルと名前と説明と小さい形がある")
    func catalogPresentation() throws {
        for item in BandTestCatalog.addedItems {
            if item == .alwaysShowToolbar {
                #expect(item.additionalSymbol == nil)
            } else {
                let symbol = try #require(item.additionalSymbol)
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
            }
            #expect(!item.editorName.isEmpty && !item.editorDescription.isEmpty)
            #expect(item.hasCompactForm)
        }
        for symbol in ["arrow.left", "arrow.left.and.right"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        }
    }
}
