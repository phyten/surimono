import AppKit
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct BandStatePlateTests {
    @Test("帯のプレートは角・表示形態ごとの寸法を保つ", arguments: CornerPreset.allCases)
    func metrics(corners: CornerPreset) {
        for compact in [false, true] {
            let plate = BandPlateMetrics(corners: corners, compact: compact)
            #expect(plate.height == 22)
            #expect(plate.width == (compact ? 22 : nil))
            #expect(plate.padding == (compact ? 0 : 6))
            #expect(
                plate.radius == (corners == .square ? 0 : (corners == .round ? 11 : 5)))
            #expect(BandDesign.hintRadius(corners) == (corners == .square ? 0 : (corners == .round ? 8 : 5)))
        }
    }

    @Test("切り替えは輪郭と塗り、開閉は同じ実在する記号を使う")
    func symbols() {
        let names: [BandLayout.Item: (String, String)] = [
            .showOnAllSpaces: ("rectangle.on.rectangle", "rectangle.fill.on.rectangle.fill"),
            .selectText: ("character.cursor.ibeam", "character.cursor.ibeam"),
            .cover: ("book.closed", "book.closed.fill"), .ignoreSlides: ("play.rectangle", "play.rectangle.fill"),
            .style: ("paintpalette", "paintpalette"), .outline: ("list.bullet", "list.bullet"),
            .readingSettings: ("sidebar.right", "sidebar.right"), .thumbnails: ("square.grid.2x2", "square.grid.2x2"),
            .viewOptions: ("slider.horizontal.3", "slider.horizontal.3"),
            .printSettings: ("doc.badge.gearshape", "doc.badge.gearshape"),
        ]
        for (item, pair) in names {
            #expect(item.stateSymbol(on: false) == pair.0 && item.stateSymbol(on: true) == pair.1)
        }
        for name in names.values.flatMap({ [$0.0, $0.1] }) + ["wand.and.stars", "wand.and.rays"] {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        }
    }

    @Test("ツールバーの16pt記号は上帯の内側だけをオンで塗る")
    func toolbarStrip() throws {
        for checked in [false, true] {
            let renderer = ImageRenderer(
                content: BandStateGlyph(item: .alwaysShowToolbar, on: checked).foregroundStyle(.black))
            renderer.scale = 2
            let image = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            #expect(image.pixelsWide == 32 && image.pixelsHigh == 32)
            #expect((image.colorAt(x: 16, y: 8)?.alphaComponent ?? 0) == (checked ? 1 : 0))
            #expect(image.colorAt(x: 16, y: 20)?.alphaComponent == 0)
        }
    }

    @Test("帯と二択の地に重ねたオンの前景は通常・ホバー・押下すべてで4.5対1以上")
    func foregroundContrast() {
        func blend(_ foreground: [Double], over background: [Double], opacity: Double) -> [Double] {
            zip(foreground, background).map { $0 * opacity + $1 * (1 - opacity) }
        }
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        func contrast(_ first: [Double], _ second: [Double]) -> Double {
            let a = luminance(first)
            let b = luminance(second)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        for dark in [false, true] {
            for increased in [false, true] {
                func color(_ swatch: PrintPalette.Swatch) -> NSColor {
                    swatch.resolved(dark: dark, increasedContrast: increased, reduceTransparency: false)
                }
                func rgb(_ swatch: PrintPalette.Swatch) -> [Double] {
                    let value = color(swatch)
                    return [value.redComponent, value.greenComponent, value.blueComponent]
                }
                let band = rgb(.raised)
                let group = blend(rgb(.bandSegmentTrack), over: band, opacity: color(.bandSegmentTrack).alphaComponent)
                let off = blend(rgb(.ink), over: band, opacity: 0.85)
                #expect(contrast(off, band) >= 4.5)
                for surface in [band, group] {
                    for (hovered, pressed) in [(false, false), (true, false), (true, true)] {
                        let paint = BandPlatePaint(dark: dark, hovered: hovered, pressed: pressed)
                        let plate = blend(rgb(.bandPlateFill), over: surface, opacity: paint.fill)
                        #expect(contrast(rgb(.bandOnInk), plate) >= 4.5)
                    }
                }
            }
        }
    }

    @Test("オンとオフの通常・ホバー・押下は外観に応じた濃さで塗る")
    func paints() {
        for (dark, hover, down, fill, off) in [
            (false, false, false, 0.22, 0.0), (false, true, false, 0.27, 0.06),
            (false, true, true, 0.32, 0.12), (true, false, false, 0.32, 0.0),
            (true, true, false, 0.38, 0.10), (true, true, true, 0.44, 0.18),
        ] {
            let paint = BandPlatePaint(dark: dark, hovered: hover, pressed: down)
            #expect(paint.fill == fill && paint.offFill == off)
        }
    }

    @Test("通常は輪郭のない一面を描き、アクセシビリティ設定時だけオンに1pt枠と10×2pt下線を描く")
    func borderAndUnderline() throws {
        let marked =
            DisplayAccessibility.shared.options.increasedContrast
            || NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
        for on in [false, true] {
            let renderer = ImageRenderer(content: Color.clear.modifier(BandPlateFace(on: on, compact: true)))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            func alpha(_ x: Int, _ y: Int) -> CGFloat { bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
            let interior = alpha(22, 10)
            if on && marked {
                #expect(alpha(22, 0) == 1 && alpha(22, 1) == 1 && alpha(22, 2) == interior)
                #expect((8..<36).filter { alpha($0, 40) > interior + 0.1 }.count == 20)
                #expect((36..<42).filter { alpha(22, $0) == 1 }.count == 4)
            } else {
                #expect((0..<44).allSatisfy { alpha(22, $0) == interior })
            }
        }
    }

    @Test("初回は450ms、離脱は150ms、前の部品を離れてから1500ms以内だけ隣を60msで開く")
    func deadlines() {
        let start = ContinuousClock.now
        func time(_ ms: Int) -> ContinuousClock.Instant { start + .milliseconds(ms) }
        var state = BandHintTiming()
        state.enter("pin", at: time(0))
        state.advance(to: time(449))
        #expect(state.visible == nil)
        state.advance(to: time(450))
        #expect(state.visible == "pin")
        state.enter(nil, at: time(550))
        state.advance(to: time(699))
        #expect(state.visible == "pin")
        state.advance(to: time(700))
        #expect(state.visible == nil)
        var expired = state
        expired.enter("cover", at: time(2051))
        #expect(expired.deadline == time(2501))
        state.enter("cover", at: time(2050))
        #expect(state.deadline == time(2110))
        state.advance(to: time(2110))
        state.advance(to: time(9999))
        #expect(state.visible == "cover")
        state.dismiss(at: time(10000))
        #expect(state.target == nil && state.visible == nil && state.deadline == nil)
        state.enter("cover", at: time(10002))
        #expect(state.deadline == time(10452))
    }

    @Test("Tab はカードを即座に消し、次にフォーカスした部品は60msで開く")
    func keyboardExploration() {
        let start = ContinuousClock.now
        var state = BandHintTiming()
        state.enter("outline", at: start)
        state.advance(to: start + .milliseconds(450))
        state.dismiss(continuingFocus: true, at: start + .milliseconds(460))
        #expect(state.visible == nil)
        state.enter("layout", at: start + .milliseconds(470))
        #expect(state.deadline == start + .milliseconds(530))
        state.advance(to: start + .milliseconds(530))
        #expect(state.visible == "layout")
        state.dismiss()
        state.enter("style", at: start + .milliseconds(540))
        #expect(state.visible == nil && state.deadline == start + .milliseconds(990))
    }

    @Test("部品とカードの間の6ptとカードの上では帯を保持する")
    func stayingOnCard() async throws {
        let hints = BandHintSession()
        let host = NSHostingView(
            rootView:
                Color.clear.frame(width: 24, height: 22)
                .bandHint("pin", .init(name: "Pin", detail: "A short description."))
                .position(x: 80, y: 11)
                .frame(width: 360, height: 160)
                .modifier(BandHintHost(session: hints)))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        hints.move(to: CGPoint(x: 80, y: 11))
        try await Task.sleep(for: .milliseconds(800))
        host.layoutSubtreeIfNeeded()
        try #require(hints.visible == "pin")
        for point in [CGPoint(x: 80, y: 25), CGPoint(x: 150, y: 45)] {
            hints.move(to: point)
            #expect(hints.holdsBand)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(hints.visible == "pin")
        hints.move(to: CGPoint(x: 350, y: 120))
        #expect(!hints.holdsBand)
        try await Task.sleep(for: .milliseconds(200))
        #expect(hints.visible == nil)
        for type in [NSEvent.EventType.leftMouseDown, .keyDown, .scrollWheel] {
            hints.move(to: CGPoint(x: 80, y: 11))
            try await Task.sleep(for: .milliseconds(700))
            try #require(hints.visible == "pin")
            hints.handle(type, keyCode: type == .keyDown ? 53 : nil)
            #expect(hints.visible == nil)
            hints.move(to: CGPoint(x: 81, y: 11))
            try await Task.sleep(for: .milliseconds(500))
            #expect(hints.visible == nil)
            hints.move(to: nil)
        }
        hints.setFocus("pin")
        hints.handle(.keyDown, keyCode: 48)
        hints.setFocus("pin")
        hints.move(to: CGPoint(x: 350, y: 120))
        #expect(hints.holdsBand)
        hints.setFocus(nil)
        #expect(!hints.holdsBand)
    }

    @Test("上下どちらの帯でも縁から説明カードまで6pt空き、その隙間でカードと帯を保持する", arguments: [false, true])
    func bandEdgeGap(bottom: Bool) async throws {
        let hints = BandHintSession()
        let band = BandZone(edge: bottom ? .bottom : .top, isShown: true, height: bottom ? 38 : 32) {
            Color.clear.frame(width: 22, height: 22)
                .bandHint("pin", .init(name: "Pin", detail: "A short description."), above: bottom)
        }
        let host = NSHostingView(
            rootView: Color.white.frame(width: 360, height: 160)
                .overlay(alignment: bottom ? .bottom : .top) { band }
                .modifier(BandHintHost(session: hints, bandHeights: BandRoom(top: 32, bottom: 38))))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        hints.move(to: CGPoint(x: 180, y: bottom ? 141 : 16))
        let deadline = ContinuousClock.now + .seconds(3)
        while hints.footprint == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let card = try #require(hints.footprint).rect
        #expect(bottom ? card.maxY == 116 : card.minY == 38)
        for offset in 0...6 {
            hints.move(to: CGPoint(x: 180, y: bottom ? 122 - offset : 32 + offset))
            #expect(hints.hover == nil && hints.holdsBand)
            if offset == 3 {
                try await Task.sleep(for: .milliseconds(250))
                #expect(hints.visible == "pin")
            }
        }
        hints.move(to: CGPoint(x: card.midX, y: card.midY))
        #expect(hints.visible == "pin" && hints.holdsBand)
        hints.move(to: CGPoint(x: 0, y: 80))
        #expect(!hints.holdsBand)
    }

    @Test("部品に静止している間は帯を保持し、離れると元の自動非表示が働く")
    func idlePause() async throws {
        let menu = OverlayMenuState()
        menu.showFull()
        menu.hasActivePart = true
        menu.pointerExited()
        try await Task.sleep(for: .milliseconds(1100))
        #expect(menu.stage == .full)
        menu.hasActivePart = false
        // SwiftUI layout in another hosted test can delay the main actor after the one-second timer fires.
        let deadline = ContinuousClock.now + .seconds(3)
        while menu.stage != .hidden, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(menu.stage == .hidden)
    }

    private func withPaperModel(_ body: (DocumentViewModel) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DocumentViewModel(
            data: Data("<p>Paper</p>".utf8), fileURL: directory.appendingPathComponent("paper.html"), format: .html,
            preferences: AppPreferences(defaults: BandTestDefaultsSuite().defaults),
            library: UserLibrary(root: directory), settingsStore: DocumentSettingsStore(directory: directory))
        model.isolateBandTestOutput()
        model.setHTMLPresentation(.paper, capturesWeb: false)
        defer { model.stop() }

        try body(model)
    }

    @Test("名前は実際に表示したときだけ省略でき、値やアイコンだけなら残す")
    func displayedNames() throws {
        try withPaperModel { model in
            for item in [BandLayout.Item.selectText, .cover, .alwaysShowToolbar, .viewOptions, .print, .outline] {
                #expect(BandPart(model: model, item: item, form: .full).displaysName(item.editorName))
                #expect(!BandPart(model: model, item: item, form: .compact).displaysName(item.editorName))
            }
            for item in [
                BandLayout.Item.floatOnTop, .showOnAllSpaces, .style, .layout, .chapter, .zoom, .readingDirection,
            ] {
                #expect(!BandPart(model: model, item: item, form: .full).displaysName(item.editorName))
            }
        }
    }

    @Test("六つのスイッチを全形態と三つの角で描くとオンとオフの寸法が等しい", arguments: CornerPreset.allCases)
    func renderedSwitchSizes(corners: CornerPreset) throws {
        try withPaperModel { model in
            model.preferences.corners = corners
            model.updateViewOptions { $0.layout = .spread }
            model.slideDeckDidChange(SlideDeck(size: CGSize(width: 960, height: 540), count: 2))
            let menu = BandMenuContent(model: model)
            for item in [
                BandLayout.Item.cover, .ignoreSlides, .alwaysShowToolbar, .selectText, .floatOnTop, .showOnAllSpaces,
            ] {
                let id = try #require(BandMenuContent.ID(rawValue: item.rawValue))
                for form in [BandLayout.Form.full, .withoutSuffix, .compact] {
                    @MainActor func size(on: Bool) throws -> CGSize {
                        menu.setChecked(on, for: id)
                        #expect(menu.entry(id).isChecked == on)
                        let renderer = ImageRenderer(
                            content: BandItemView(model: model, item: item, form: form).fixedSize())
                        renderer.scale = 2
                        let image = try #require(renderer.cgImage)
                        return CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
                    }
                    let off = try size(on: false)
                    let on = try size(on: true)
                    #expect(off.height == 22 && off == on)
                    if form != .full { #expect(off.width == 22) }
                }
            }
        }
    }

    @Test("文字選択だけ名前を出す帯でも、全プレートの上下端は同じ44画素にそろう")
    func mixedPlatePixelBounds() throws {
        try withPaperModel { model in
            model.updateViewOptions { $0.layout = .spread }
            model.slideDeckDidChange(SlideDeck(size: CGSize(width: 960, height: 540), count: 2))
            let items: [BandLayout.Item] = [
                .floatOnTop, .showOnAllSpaces, .selectText, .alwaysShowToolbar, .cover, .ignoreSlides,
            ]
            for item in items {
                let id = try #require(BandMenuContent.ID(rawValue: item.rawValue))
                BandMenuContent(model: model).setChecked(true, for: id)
            }
            let row = HStack(alignment: .center, spacing: 8) {
                ForEach(items, id: \.self) { item in
                    BandItemView(model: model, item: item, form: item == .selectText ? .full : .compact)
                }
            }.fixedSize().padding(6)
            let renderer = ImageRenderer(content: row)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            var spans: [ClosedRange<Int>] = []
            var top = bitmap.pixelsHigh
            var bottom = -1
            for x in 0..<bitmap.pixelsWide {
                var painted = false
                for y in 0..<bitmap.pixelsHigh where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.08 {
                    top = min(top, y)
                    bottom = max(bottom, y)
                    painted = true
                }
                if !painted && bottom >= top {
                    spans.append(top...bottom)
                    top = bitmap.pixelsHigh
                    bottom = -1
                }
            }
            #expect(spans == Array(repeating: 12...55, count: items.count))
        }
    }

    @Test("単ページでもオンの表紙の設定を保持し、見開きで効くことを説明する")
    func inactiveCover() throws {
        try withPaperModel { model in
            model.updateViewOptions {
                $0.layout = .single
                $0.showsCoverAlone = true
            }
            #expect(BandLayout.Item.applicable(for: model).contains(.cover))
            let hint = BandHintContent.band(.cover, model: model)
            #expect(hint.active && hint.state == String(localized: "On"))
            #expect(
                hint.detail
                    == String(localized: "This setting applies in spread view. You are viewing one page at a time."))
        }
    }

    @Test("スマート削除の板と説明は確認パネルの開閉と独立し、設定値に従う")
    func smartRemovalIndicator() throws {
        try withPaperModel { model in
            for checked in [false, true] {
                model.isSmartRemovalEnabled = checked
                model.reviewSmartRemoval()
                #expect(model.isReviewingSmartRemoval == checked)
                let hint = BandHintContent.band(.style, model: model)
                #expect(hint.active == checked)
                #expect(
                    hint.state
                        == choice(
                            String(localized: "Smart Removal"),
                            checked ? String(localized: "On") : String(localized: "Off")))
                model.endSmartRemovalReview()
                #expect(BandHintContent.band(.style, model: model) == hint)
            }
        }
    }

    @Test("全29部品が名前・現在値・割当キー・説明を共有し、読み上げはスイッチ値を重ねない")
    func hintsAndAccessibility() throws {
        try withPaperModel { model in
            let toggles: Set<BandLayout.Item> = [
                .cover, .selectText, .alwaysShowToolbar, .ignoreSlides, .floatOnTop, .showOnAllSpaces,
            ]
            let drawers: Set<BandLayout.Item> = [
                .outline, .chapter, .readingSettings, .thumbnails, .printSettings, .viewOptions,
            ]
            let menu = BandMenuContent(model: model)
            for item in BandLayout.Item.allCases {
                let card = BandHintContent.band(item, model: model)
                let editor = BandHintContent.editor(item)
                #expect(editor.name == item.editorName && editor.detail == item.editorDescription)
                #expect(editor.reason == nil)
                #expect(editor.state == nil && editor.shortcut.isEmpty)
                #expect(card.name == (item == .style ? String(localized: "HTML Preset") : item.editorName))
                #expect(card.detail == item.editorDescription)
                #expect(card.accessibilityHint == (card.reason ?? item.editorDescription))
                if toggles.contains(item) {
                    let id = try #require(BandMenuContent.ID(rawValue: item.rawValue))
                    #expect(
                        card.state
                            == (menu.entry(id).isChecked == true ? String(localized: "On") : String(localized: "Off")))
                    #expect(card.accessibilityValue == nil)
                } else if drawers.contains(item) {
                    #expect(card.state == String(localized: "Closed"))
                    #expect(card.accessibilityValue?.contains(String(localized: "Closed")) == true)
                } else if [.saveAsFile, .keysAndGestures, .print, .pageTurn].contains(item) {
                    #expect(card.state == nil && card.accessibilityValue == nil)
                }
                let ops: [ShortcutOperationID] =
                    switch item {
                    case .floatOnTop: [.viewFloatOnTop]
                    case .showOnAllSpaces: [.viewShowOnAllSpaces]
                    case .pageIndicator: [.documentGoToPage]
                    case .pageTurn: [.readingPrevious, .readingNext]
                    case .chapter, .outline: [.viewOutline]
                    case .zoom: [.viewZoomFit]
                    case .presentation: [.viewHtmlPresentation]
                    case .layout: [.viewSingle, .viewSpread]
                    case .print: [.documentPrint]
                    case .selectText: [.viewSelectText]
                    case .alwaysShowToolbar: [.viewToolbarAlways]
                    case .viewOptions: [.viewOptions]
                    case .ignoreSlides: [.viewIgnoreSlides]
                    case .printSettings: [.printSettings]
                    case .keysAndGestures: [.appKeyGuide]
                    case .saveAsFile: [.documentSaveAsFile]
                    case .beforePrinting: [.printReviewIssues]
                    case .thumbnails: [.listToggle]
                    default: []
                    }
                #expect(card.shortcut == ShortcutHints.keys(ops))
            }
            model.updateViewOptions { $0.transition = .fade }
            let disabled = BandHintContent.band(.scrollDirection, model: model)
            #expect(disabled.reason == String(localized: "Not used by the current page turn."))
            #expect(disabled.accessibilityHint == disabled.reason)
        }

    }
}
