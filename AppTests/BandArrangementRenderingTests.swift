import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI
import Testing

@testable import Surimono

/// The view mode's bands drawn from the saved arrangement: Standard as before, other sets in any window, popovers that
/// survive a part moving away, the window's narrowest width and what "…" offers.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BandArrangementRenderingTests {
    @Test("並べ替え見本には余分な区切りと同じ群の間の区切りがあり計画は描く線だけ返す")
    func separatorFixture() throws {
        let fixture = try #require(DebugSnapshot.bandArrangementFixture(named: "reordered"))
        #expect(
            fixture.activeLayouts.split.topLeft == [
                .separator, .part(.formatBadge), .separator, .separator, .part(.outline), .separator,
            ])
        #expect(
            fixture.activeLayouts.top.topLeft == [
                .part(.formatBadge), .part(.pageIndicator), .part(.outline), .separator, .part(.style),
            ])
        let plan = BandLayout.resolve(
            arrangement: fixture.activeLayouts.top, mode: .top, availableItems: Set(BandLayout.Item.allCases),
            measurements: .init(items: [:], name: 0),
            metrics: .init(topFixed: 0, bottomFixed: 0, separator: 9), availableWidth: 1000)
        #expect(plan.top.geometry.separatorsBefore == [.style])
        #expect(plan.top.geometry.gapsBefore[.style] == 8)
    }

    @MainActor private struct Environment {
        let preferences: AppPreferences
        let library: UserLibrary
        let store: DocumentSettingsStore
        let directory: URL
        let suite: BandTestDefaultsSuite

        init() {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = BandTestDefaultsSuite()
            preferences = AppPreferences(defaults: suite.defaults)
            library = UserLibrary(root: directory.appendingPathComponent("Library"))
            store = DocumentSettingsStore(directory: directory.appendingPathComponent("Settings"))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            suite.remove()
        }

        /// A two-chapter Markdown document on two pages: it has a style, contents, a page indicator and page turns.
        func chapters() -> DocumentViewModel {
            let renderer = DocumentRenderer(paginate: { _ in
                try #require(PDFDocument(data: TestFixtures.textPDF(["First Chapter", "Second Chapter"])))
            })
            let model = DocumentViewModel(
                data: Data("# First Chapter\n\n# Second Chapter\n".utf8), fileURL: nil, format: .markdown,
                preferences: preferences, library: library, renderer: renderer, settingsStore: store)
            model.isolateBandTestOutput()
            return model
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func open(_ model: DocumentViewModel) async throws {
        model.start()
        try await waitUntil { model.contentHash != nil && model.result != nil && !model.isRendering }
        try await waitUntil { model.hasOutline }
    }

    /// Applicable new parts of the two-page, single-page-view Markdown fixture.
    private static let availableAdded: [BandLayout.Item] = [
        .readingDirection, .scrollDirection, .paperOrientation, .paperSeries, .selectText,
        .alwaysShowToolbar, .margins, .printSettings, .viewOptions, .saveAsFile, .keysAndGestures,
    ]

    /// Measured widths of the legacy parts, without the stacks' spacing.
    private static let widths: [BandSlot: CGFloat] = [
        .name: 120, .more: 24,
        .item(.formatBadge, .full): 30, .item(.pageIndicator, .full): 50,
        .item(.style, .full): 90, .item(.style, .compact): 40,
        .item(.outline, .full): 60, .item(.outline, .compact): 30,
        .item(.layout, .full): 60, .item(.transition, .full): 100, .item(.transition, .compact): 40,
        .item(.floatOnTop, .full): 28, .item(.pageTurn, .full): 60,
        .item(.print, .full): 70, .item(.print, .compact): 34,
    ]

    private func menu(width: CGFloat) -> OverlayMenuState {
        let menu = OverlayMenuState()
        // No traffic lights read: the band uses the window's usual ones.
        menu.hasReadTrafficLights = true
        menu.bandWidths = Self.widths
        menu.bandWidth = width
        return menu
    }

    /// Use the original width calculation with today's default parts to check every collapse boundary.
    private func legacy(_ model: DocumentViewModel, mode: MenuArrangement, width: CGFloat) -> (
        top: BandLayout.Plan, bottom: BandLayout.Plan?
    ) {
        let topItems: Set<BandLayout.Item> = [.formatBadge, .floatOnTop, .print]
        // The previous/next buttons start on the split band only.
        let applicable = BandLayout.Item.applicable(for: model).filter {
            !BandTestCatalog.standardUnused.contains($0) && (mode == .split || $0 != .pageTurn)
        }
        func widths(top: Bool) -> [BandLayout.Item: BandLayout.Widths] {
            var result: [BandLayout.Item: BandLayout.Widths] = [:]
            for item in applicable where (mode == .top || topItems.contains(item)) == top {
                let gap: CGFloat =
                    switch item {
                    case .formatBadge: 6
                    case .pageIndicator: mode == .split ? 8 : 6
                    case .print: 0
                    default: 8
                    }
                result[item] = BandLayout.Widths(
                    full: (Self.widths[.item(item, .full)] ?? 0) + gap,
                    compact: Self.widths[.item(item, .compact)].map { $0 + gap })
            }
            return result
        }
        let top = BandLayout.plan(
            widths: widths(top: true), fixed: OverlayBand.fixedWidth(lights: nil) + 24, separator: 9, name: 120,
            available: width)
        let bottom =
            mode == .split
            ? BandLayout.plan(
                widths: widths(top: false), fixed: 28, separator: 9, name: 0, available: width,
                steps: BandLayout.bottomSteps) : nil
        return (top, bottom)
    }

    @Test("標準配置の部品を帯へ順に渡し、どの幅でも部品とファイル名が収まる", arguments: MenuArrangement.allCases)
    func standardFeedsRenderer(mode: MenuArrangement) async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = mode
        let model = environment.chapters()
        defer { model.stop() }
        try await open(model)

        let wide = BandPlans(model: model, menu: menu(width: 2000))
        #expect(wide.top.geometry.usesStandardSpacing)
        switch mode {
        case .split:
            #expect(wide.top.leading == [.formatBadge])
            #expect(wide.top.trailing == [.print])
            #expect(wide.bottom?.leading == [.style, .outline, .layout])
            #expect(wide.bottom?.trailing == [.chapter, .pageIndicator, .pageTurn])
            #expect(wide.bottom?.geometry.usesStandardSpacing == true)
            #expect(
                wide.resolved.unusedAvailable == [.transition, .floatOnTop, .showOnAllSpaces] + Self.availableAdded)
        case .top:
            #expect(wide.top.leading == [.formatBadge, .pageIndicator, .chapter])
            #expect(wide.top.trailing == [.style, .outline, .layout, .print])
            #expect(wide.bottom == nil)
            // Standard Top Only leaves Page Turn off the band; "…" now offers its two actions.
            #expect(
                wide.resolved.unusedAvailable == [.transition, .floatOnTop, .showOnAllSpaces, .pageTurn]
                    + Self.availableAdded)
        }
        #expect(wide.top.geometry.moreDock == .beforePrint)

        // Zero stands for a band not laid out yet, which shows everything.
        for width in stride(from: CGFloat(1), through: 900, by: 1) {
            let plans = BandPlans(model: model, menu: menu(width: width))
            let old = legacy(model, mode: mode, width: width)
            #expect(plans.top.forms == old.top.forms, "top at \(width)")
            #expect(plans.top.nameWidth == old.top.nameWidth, "name at \(width)")
            #expect(plans.bottom?.forms == old.bottom?.forms, "bottom at \(width)")
            let pushedOut = Set(old.top.overflow + (old.bottom?.overflow ?? []))
            #expect(Set(plans.resolved.overflow) == pushedOut, "overflow at \(width)")
        }
    }

    @Test("配置を変えると開いている窓の帯がその配置で描き直し、標準に戻すと元の位置に戻る")
    func activeSetReachesOpenWindow() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .split
        environment.preferences.defaultBandVisibility = .always
        let model = environment.chapters()
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        try await open(model)
        let content = { window.contentRect(forFrameRect: window.frame).height }
        func band(of item: BandLayout.Item) -> VerticalEdge? {
            guard let frame = model.bandAnchors.frames[.item(item)] else { return nil }
            if frame.maxY <= model.topBandHeight + 1 { return .top }
            return frame.minY >= content() - ViewerWindow.bandHeight - 1 ? .bottom : nil
        }
        try await waitUntil { band(of: .print) == .top && band(of: .style) == .bottom }

        var layouts = BandArrangementVariants()
        layouts.split = try layouts.split.moving(.print, to: .zone(.bottomLeft), before: .style, for: .split)
        layouts.split = try layouts.split.moving(.style, to: .zone(.topLeft), for: .split)
        try environment.preferences.saveBandArrangement(BandArrangementSet(name: "Reading", layouts: layouts))
        try await waitUntil { band(of: .print) == .bottom && band(of: .style) == .top }

        try environment.preferences.selectBandArrangement(.standard)
        try await waitUntil { band(of: .print) == .top && band(of: .style) == .bottom }
    }

    /// The popovers shown from this window, which AppKit attaches to it as child windows.
    private func popoverCount(_ window: NSWindow) -> Int {
        (window.childWindows ?? []).filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
            .count
    }

    enum BandPopover: String, CaseIterable, Sendable {
        case contents, documentInfo, viewOptions
    }

    private func isPresented(_ popover: BandPopover, in model: DocumentViewModel) -> Bool {
        switch popover {
        case .contents: model.isOutlinePresented
        case .documentInfo: model.isFiguresPresented
        case .viewOptions: model.isViewOptionsPresented
        }
    }

    private func present(_ popover: BandPopover, _ shown: Bool, in model: DocumentViewModel) {
        switch popover {
        case .contents: model.isOutlinePresented = shown
        case .documentInfo: model.isFiguresPresented = shown
        case .viewOptions: model.isViewOptionsPresented = shown
        }
    }

    @Test(
        "開いたポップオーバーは、上の帯の部品が幅で「…」に畳まれても、広げて戻っても閉じず一つだけ",
        arguments: BandPopover.allCases)
    func popoverSurvivesFold(popover: BandPopover) async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .split
        environment.preferences.defaultBandVisibility = .always
        // Contents and the page indicator on the top band, where they fold at a width the window still allows.
        var layouts = BandArrangementVariants()
        layouts.split = try layouts.split.moving(.pageIndicator, to: .zone(.topLeft), for: .split)
        layouts.split = try layouts.split.moving(.outline, to: .zone(.topLeft), for: .split)
        layouts.split = try layouts.split.moving(.viewOptions, to: .zone(.topLeft), for: .split)
        try environment.preferences.saveBandArrangement(BandArrangementSet(name: "Top Parts", layouts: layouts))
        let model = environment.chapters()
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        window.orderFrontRegardless()
        try await open(model)
        // The window opens as large as the screen lets the paper be. On a small screen (a CI runner's) that is too
        // narrow for the three parts and one starts folded, so the test starts from a width that holds them all.
        let opened = window.contentRect(forFrameRect: window.frame).size
        window.setContentSize(NSSize(width: max(opened.width, 1200), height: opened.height))
        let folding: BandLayout.Item =
            switch popover {
            case .documentInfo: .pageIndicator
            case .contents: .outline
            case .viewOptions: .viewOptions
            }
        let anchors = model.bandAnchors
        try await waitUntil {
            anchors.plan?.band(of: folding) == .top && anchors.frames[.item(folding)] != nil
                && anchors.frames[.more] != nil
        }
        let base = popoverCount(window)
        present(popover, true, in: model)
        try await waitUntil { popoverCount(window) == base + 1 }

        let wide = window.contentRect(forFrameRect: window.frame).size
        window.setContentSize(NSSize(width: 260, height: wide.height))
        #expect(window.contentRect(forFrameRect: window.frame).width == 260)
        try await waitUntil { anchors.plan != nil && anchors.plan?.band(of: folding) == nil }
        #expect(anchors.plan?.overflow.contains(folding) == true)
        #expect(isPresented(popover, in: model))
        #expect(popoverCount(window) == base + 1)

        window.setContentSize(wide)
        try await waitUntil { anchors.plan?.band(of: folding) == .top }
        #expect(anchors.plan?.overflow.contains(folding) == false)
        #expect(isPresented(popover, in: model))
        #expect(popoverCount(window) == base + 1)

        present(popover, false, in: model)
        try await waitUntil { popoverCount(window) == base }
    }

    @Test("目次を開いたまま上の帯へ移しても、使わない部品にしても、ポップオーバーは閉じず一つだけ")
    func popoverSurvivesMove() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .split
        environment.preferences.defaultBandVisibility = .always
        let model = environment.chapters()
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        window.orderFrontRegardless()
        try await open(model)
        let anchors = model.bandAnchors
        try await waitUntil { anchors.plan?.band(of: .outline) == .bottom && anchors.frames[.item(.outline)] != nil }
        let base = popoverCount(window)
        model.toggleOutline()
        try await waitUntil { popoverCount(window) == base + 1 }

        var layouts = BandArrangementVariants()
        layouts.split = try layouts.split.moving(.outline, to: .zone(.topLeft), for: .split)
        try environment.preferences.saveBandArrangement(BandArrangementSet(name: "Top Contents", layouts: layouts))
        try await waitUntil {
            anchors.plan?.band(of: .outline) == .top
                && (anchors.frames[.item(.outline)]?.maxY ?? .infinity) <= model.topBandHeight + 1
        }
        #expect(model.isOutlinePresented)
        #expect(popoverCount(window) == base + 1)

        layouts.split = try layouts.split.moving(.outline, to: .unused, for: .split)
        try environment.preferences.saveBandArrangement(BandArrangementSet(name: "No Contents", layouts: layouts))
        try await waitUntil { anchors.plan != nil && anchors.plan?.band(of: .outline) == nil }
        #expect(anchors.plan?.unusedAvailable.contains(.outline) == true)
        #expect(model.isOutlinePresented)
        #expect(popoverCount(window) == base + 1)

        model.isOutlinePresented = false
        try await waitUntil { popoverCount(window) == base }
    }

    @Test("表示のオプションを開いたまま上下と未使用へ移しても一つだけ表示し続ける")
    func viewOptionsSurviveMove() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .split
        environment.preferences.defaultBandVisibility = .always
        var initial = BandArrangementVariants()
        initial.split = try initial.split.moving(.viewOptions, to: .zone(.bottomLeft), for: .split)
        try environment.preferences.saveBandArrangement(BandArrangementSet(name: "Bottom Options", layouts: initial))
        let model = environment.chapters()
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        window.orderFrontRegardless()
        try await open(model)
        let anchors = model.bandAnchors
        try await waitUntil {
            anchors.plan?.band(of: .viewOptions) == .bottom && anchors.frames[.item(.viewOptions)] != nil
        }
        let base = popoverCount(window)
        model.isViewOptionsPresented = true
        try await waitUntil { popoverCount(window) == base + 1 }

        var layouts = BandArrangementVariants()
        layouts.split = try layouts.split.moving(.viewOptions, to: .zone(.topLeft), for: .split)
        try environment.preferences.saveBandArrangement(BandArrangementSet(name: "Top Contents", layouts: layouts))
        try await waitUntil {
            anchors.plan?.band(of: .viewOptions) == .top
                && (anchors.frames[.item(.viewOptions)]?.maxY ?? .infinity) <= model.topBandHeight + 1
        }
        #expect(model.isViewOptionsPresented)
        #expect(popoverCount(window) == base + 1)

        layouts.split = try layouts.split.moving(.viewOptions, to: .unused, for: .split)
        try environment.preferences.saveBandArrangement(BandArrangementSet(name: "No Contents", layouts: layouts))
        try await waitUntil { anchors.plan != nil && anchors.plan?.band(of: .viewOptions) == nil }
        #expect(anchors.plan?.unusedAvailable.contains(.viewOptions) == true)
        #expect(model.isViewOptionsPresented)
        #expect(popoverCount(window) == base + 1)

        model.isViewOptionsPresented = false
        try await waitUntil { popoverCount(window) == base }
    }

    @Test("帯にない部品のポップオーバーは「…」から出し、下の帯の部品なら上向きに出す")
    func popoverPlacement() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .split
        let model = environment.chapters()
        defer { model.stop() }
        try await open(model)
        let more = CGRect(x: 600, y: 4, width: 24, height: 24)
        let outline = CGRect(x: 120, y: 700, width: 60, height: 24)
        let frames: [BandAnchors.Anchor: CGRect] = [.more: more, .item(.outline): outline]

        let wide = BandPlans(model: model, menu: menu(width: 2000))
        #expect(
            BandPresentationHost.placement(of: .outline, plans: wide, frames: frames)
                == .init(rect: outline, arrowEdge: .top))
        #expect(
            BandPresentationHost.placement(of: nil, plans: wide, frames: frames)
                == .init(rect: more, arrowEdge: .bottom))

        // Folded at this width, Contents keeps its last place on record, but its popover goes to "…".
        let narrow = BandPlans(model: model, menu: menu(width: 100))
        #expect(narrow.band(of: .outline) == nil)
        #expect(
            BandPresentationHost.placement(of: .outline, plans: narrow, frames: frames)
                == .init(rect: more, arrowEdge: .bottom))
    }

    @Test("窓の最小の幅は帯の信号機・「…」・印刷が収まる幅を下回らず、紙の形を保つ")
    func minimumWidth() async throws {
        let a4 = CGSize(width: 595, height: 842)
        let paperOnly = ViewerWindow.minimumContentSize(unit: a4, band: 70, side: 0, bandMinimum: 0)
        #expect(abs(paperOnly.width - 280 * 595 / 842) < 0.001)
        #expect(paperOnly.height == 350)
        let banded = ViewerWindow.minimumContentSize(unit: a4, band: 70, side: 0, bandMinimum: 400)
        #expect(banded.width == 400)
        #expect(abs(banded.height - (400 * 842 / 595 + 70)) < 0.001)
        let withSide = ViewerWindow.minimumContentSize(unit: a4, band: 70, side: 260, bandMinimum: 400)
        #expect(abs(withSide.width - (260 + 280 * 595 / 842)) < 0.001)

        let environment = Environment()
        defer { environment.cleanUp() }
        let model = environment.chapters()
        defer { model.stop() }
        try await open(model)
        // The traffic lights' room and spacing, "…" and Print as an icon: everything else can leave.
        let plans = BandPlans(model: model, menu: menu(width: 1))
        #expect(plans.top.forms == [.print: .compact])
        #expect(plans.minimumWidth == OverlayBand.fixedWidth(lights: nil) + 24 + 34)

        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        try await waitUntil { ViewerWindow.bandMinimumWidth(of: window) > 0 }
        // A wide band minimum against a narrow paper: the lock keeps the paper's shape at the band's width.
        ViewerWindow.lockAspectRatio(of: window, unit: CGSize(width: 100, height: 842), band: 70)
        let measured = ViewerWindow.bandMinimumWidth(of: window)
        #expect(abs(window.contentMinSize.width - max(measured, 280 * 100 / 842)) < 0.001)
        ViewerWindow.setBandMinimumWidth(500, of: window)
        #expect(window.contentMinSize.width == 500)
        #expect(window.contentMinSize.height > 500)
    }

    /// A PDF of two pages half as wide as they are tall.
    private func narrowPages() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 150, height: 300)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @Test("細い紙でも窓は帯の信号機・「…」・印刷が収まる幅になって印刷は窓の中にあり、帯の幅が増えると紙の形のまま広がる")
    func narrowPaperKeepsBandsOnScreen() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .split
        environment.preferences.defaultBandVisibility = .always
        let pages = try narrowPages()
        let renderer = DocumentRenderer(paginate: { _ in try #require(PDFDocument(data: pages)) })
        let model = DocumentViewModel(
            data: pages, fileURL: nil, format: .pdf, preferences: environment.preferences,
            library: environment.library, renderer: renderer, settingsStore: environment.store)
        model.isolateBandTestOutput()
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        model.start()
        try await waitUntil { model.contentHash != nil && model.result != nil && !model.isRendering }
        model.sizeWindowToPaper(initialOnly: true)
        // Measured: the traffic lights' room, "…" and Print as an icon, far more than the paper's own 140 pt minimum.
        try await waitUntil { ViewerWindow.bandMinimumWidth(of: window) > 160 }
        let minimum = ViewerWindow.bandMinimumWidth(of: window)
        let content = { window.contentRect(forFrameRect: window.frame) }
        // The app's own smallest paper for this page, as a reader's remembered size or a narrow page would ask.
        ViewerWindow.setPaperSize(CGSize(width: 140, height: 280), band: model.bandInset, of: window, animate: false)
        #expect(content().width >= minimum)
        #expect(abs((content().height - model.bandInset) - content().width * 2) <= 2)
        try await waitUntil {
            let print = model.bandAnchors.frames[.item(.print)] ?? .null
            return !print.isNull && print.minX >= 0 && print.maxX <= content().width + 0.5
                && model.bandAnchors.plan?.top.forms[.print] != nil
        }

        // Wider bands than the window: the window grows on its own after the update, keeping the paper's shape.
        model.bandMinimumWidthDidChange(minimum + 60)
        try await waitUntil { content().width >= minimum + 60 }
        #expect(abs((content().height - model.bandInset) - content().width * 2) <= 2)
    }

    @Test("一覧のボタンの場所は一覧が帯にある間だけドロップの的になり、外した配置では残らない")
    func listButtonFollowsPlan() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .split
        environment.preferences.defaultBandVisibility = .always
        let folder = environment.directory.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appendingPathComponent("1.png")
        let second = folder.appendingPathComponent("2.png")
        try TestFixtures.png(red: 0.1).write(to: first)
        try TestFixtures.png(red: 0.2).write(to: second)
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .image, preferences: environment.preferences,
            library: environment.library, imageBundle: ImageBundleModel(urls: [first, second]))
        model.isolateBandTestOutput()
        defer { model.stop() }
        let controller = MemoryDocumentWindowController(model: model, onClose: {})
        defer { controller.close() }
        let window = try #require(controller.window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        model.render()
        try await waitUntil { model.result != nil && !model.isRendering }
        try await waitUntil {
            model.bandAnchors.plan?.band(of: .thumbnails) == .bottom && model.drop.listButtonFrame != nil
        }

        var layouts = BandArrangementVariants()
        layouts.split = try layouts.split.moving(.thumbnails, to: .unused, for: .split)
        try environment.preferences.saveBandArrangement(BandArrangementSet(name: "No List", layouts: layouts))
        try await waitUntil { model.bandAnchors.plan != nil && model.bandAnchors.plan?.band(of: .thumbnails) == nil }
        #expect(model.drop.listButtonFrame == nil)

        // Back on a band, now the top one: the place is the new button's.
        layouts.split = try layouts.split.moving(.thumbnails, to: .zone(.topLeft), for: .split)
        try environment.preferences.saveBandArrangement(BandArrangementSet(name: "Top List", layouts: layouts))
        try await waitUntil {
            model.bandAnchors.plan?.band(of: .thumbnails) == .top
                && (model.drop.listButtonFrame.map { $0.height > 0 } ?? false)
        }
    }

    @Test("使わない部品と幅で外れた部品を区別し、印刷は帯に残す")
    func moreMenuContents() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.preferences.menuArrangement = .split
        let model = environment.chapters()
        defer { model.stop() }
        try await open(model)
        let layouts = BandArrangementVariants(
            split: BandArrangement(
                topRight: [.print], bottomLeft: [.outline, .layout], bottomRight: [.pageIndicator, .pageTurn],
                unused: [.formatBadge, .presentation, .style, .transition, .zoom, .thumbnails, .floatOnTop]))
        try environment.preferences.saveBandArrangement(BandArrangementSet(name: "Sparse", layouts: layouts))

        let wide = BandPlans(model: model, menu: menu(width: 2000))
        // Presentation, Zoom and List do not apply to this document.
        #expect(
            wide.resolved.unusedAvailable == [.formatBadge, .style, .transition, .floatOnTop, .showOnAllSpaces]
                + Self.availableAdded + [.chapter])
        // Narrow, the bottom band gives way; unused and overflow remain separate.
        let narrow = BandPlans(model: model, menu: menu(width: 140))
        #expect(narrow.bottom?.forms == [.outline: .compact, .pageIndicator: .full])
        #expect(narrow.resolved.overflow == [.layout, .pageTurn])
        #expect(
            narrow.resolved.unusedAvailable == [.formatBadge, .style, .transition, .floatOnTop, .showOnAllSpaces]
                + Self.availableAdded
                + [.chapter])
        #expect(!narrow.resolved.overflow.contains(.print))
        #expect(narrow.top.forms[.print] != nil)

        // A conditional unused part is available only while the document allows it: Zoom while zoomed in.
        model.zoom = 2
        #expect(BandPlans(model: model, menu: menu(width: 2000)).resolved.unusedAvailable.contains(.zoom))
    }

    @Test("配置を保存していなければ「ツールバーに目次を表示」の切り替えがそのまま帯に効き、保存したあとは配置が優先する")
    func outlineCheckboxUntilSaved() throws {
        let suite = BandTestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.activeBandArrangement == .standard(for: .split))
        preferences.showsOutlineOnBand = false
        #expect(
            preferences.activeBandArrangement.unused == [.showOnAllSpaces] + BandTestCatalog.addedItems + [
                .readingSettings, .outline, .chapter,
            ])
        #expect(!preferences.activeBandArrangement.bottomLeft.contains(.outline))
        #expect(suite.defaults.data(forKey: "bandArrangementStore") == nil)
        preferences.showsOutlineOnBand = true
        #expect(preferences.activeBandArrangement.topRight == [.part(.floatOnTop), .part(.print)])
        #expect(preferences.activeBandArrangement.bottomLeft.contains(.outline))
        #expect(AppPreferences(defaults: suite.defaults).activeBandArrangement == preferences.activeBandArrangement)

        try preferences.selectBandArrangement(.standard)
        preferences.showsOutlineOnBand = false
        #expect(preferences.activeBandArrangement == .standard(for: .split))
    }

    @Test("読めない保存の配置があるときも帯は標準で描き、何も上書きしない")
    func unreadableStoreShowsStandard() async throws {
        let environment = Environment()
        defer { environment.cleanUp() }
        environment.suite.defaults.set(Data("{\"schemaVersion\": 99}".utf8), forKey: "bandArrangementStore")
        let preferences = AppPreferences(defaults: environment.suite.defaults)
        #expect(preferences.retainedBandArrangementData != nil)
        #expect(preferences.activeBandArrangement == .standard(for: preferences.menuArrangement))
        preferences.showsOutlineOnBand = false
        #expect(preferences.activeBandArrangement == .standard(for: preferences.menuArrangement))
        #expect(
            environment.suite.defaults.data(forKey: "bandArrangementStore") == Data("{\"schemaVersion\": 99}".utf8))
    }
}
