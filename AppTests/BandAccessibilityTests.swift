import Foundation
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct BandAccessibilityTests {
    @Test("帯の操作名はコンパクト表示でも翻訳できる短い名前になる")
    func compactNames() {
        let names: [BandLayout.Item: String] = [
            .formatBadge: "LaTeX Layout", .readingSettings: "Reading Settings", .outline: "Contents",
            .presentation: "Web or Paper", .style: "Style", .layout: "View Type", .transition: "Page Turn",
            .zoom: "Fit to Window", .thumbnails: "Pages Tab", .floatOnTop: "Float on Top",
            .showOnAllSpaces: "Show on All Spaces", .print: "Print", .readingDirection: "Reading Direction",
            .scrollDirection: "Scroll Direction", .paperOrientation: "Paper Orientation", .paperSeries: "Paper Series",
            .cover: "Show First Page Alone", .selectText: "Select Text", .alwaysShowToolbar: "Always Show Toolbar",
            .margins: "Margins", .printSettings: "Print Settings", .ignoreSlides: "Show as Slides",
            .beforePrinting: "Before Printing", .viewOptions: "View Options", .saveAsFile: "Save as File",
            .keysAndGestures: "Keys and Gestures", .chapter: "Current Chapter", .pageIndicator: "Go to Page",
        ]
        #expect(Set(names.keys) == Set(BandLayout.Item.allCases).subtracting([.pageTurn]))
        for (item, key) in names {
            #expect(item.bandAccessibilityName == LocalizedStringKey(key), "\(item)")
        }
        #expect(PageTurnButtons.title(forward: false) == "Previous Page")
        #expect(PageTurnButtons.title(forward: true) == "Next Page")
        #expect(BandAccessibility.more == "More")
        #expect(BandLayout.Item.formatBadge.editorNameResource.key == "Format")
        let documents = BandAccessibility.documents(3)
        #expect(documents.key == "Documents %lld")
        #expect(String(localized: documents) == String(format: String(localized: "Documents %lld"), 3))
        #expect(HTMLPresentation.web.title == "Web")
        #expect(HTMLPresentation.paper.title == "Paper")
        #expect(ViewOptions.Layout.single.title == "Single Page")
        #expect(ViewOptions.Layout.spread.title == "Spread")
    }

    @Test("帯の読み上げ値は現在の選択、開閉、件数を反映する")
    func values() {
        for (item, value) in [
            (BandLayout.Item.readingDirection, "Right to Left"), (.scrollDirection, "Horizontal"),
            (.paperOrientation, "Landscape"), (.paperSeries, "B"), (.margins, "15 mm"),
        ] {
            let selected = Bundle.main.localizedString(forKey: value, value: nil, table: nil)
            #expect(item.bandAccessibilityValue(choice: selected) == selected)
        }
        for item in [BandLayout.Item.cover, .selectText, .alwaysShowToolbar, .ignoreSlides] {
            #expect(item.bandAccessibilityValue(checked: true) == String(localized: "On"))
            #expect(item.bandAccessibilityValue(checked: false) == String(localized: "Off"))
        }
        for item in [BandLayout.Item.printSettings, .viewOptions] {
            #expect(item.bandAccessibilityValue(isOpen: true) == String(localized: "Open"))
            #expect(item.bandAccessibilityValue(isOpen: false) == String(localized: "Closed"))
        }
        for item in [BandLayout.Item.keysAndGestures, .saveAsFile] {
            #expect(item.bandAccessibilityValue().isEmpty)
        }
        #expect(BandLayout.Item.beforePrinting.bandAccessibilityValue(issueCount: 3) == 3.formatted())
        #expect(ClipboardFormatText.value(kind: .markdown, origin: .chosen) == "Markdown")
        #expect(
            ClipboardFormatText.value(kind: .markdown, origin: .automatic)
                == String(format: String(localized: "%@ (Automatic)"), "Markdown"))
        let changes = BandAccessibility.readingChanges(2)
        #expect(changes.key == "Changed in This Document: %lld")
        #expect(String(localized: changes) == String(format: String(localized: "Changed in This Document: %lld"), 2))
        #expect(BandAccessibility.pageIndicator("3 / 5", bookmarked: false) == "3 / 5")
        #expect(
            BandAccessibility.pageIndicator("3 / 5", bookmarked: true) == "3 / 5, " + String(localized: "Bookmarked"))
        for (transition, key) in [
            (ViewOptions.Transition.scroll, "Scroll"), (.instant, "Switch"), (.slide, "Slide"), (.fade, "Fade"),
            (.cover, "Cover Slide"), (.reveal, "Reveal"), (.wipe, "Wipe"), (.zoom, "Zoom"), (.pageCurl, "Page Curl"),
        ] {
            #expect(transition.title == LocalizedStringKey(key))
        }
    }

    @Test("準備中はページ位置としおりに準備状態を添え、完成時には外す")
    func preparingPages() {
        let preparing = String(localized: "Preparing pages…")
        let bookmark = String(localized: "Bookmarked")
        #expect(
            BandAccessibility.pageIndicator("1 / 53+", bookmarked: true, preparing: true)
                == "\(preparing), 1 / 53+, \(bookmark)")
        #expect(
            BandAccessibility.pageIndicator("1 / 16194", bookmarked: true, preparing: false) == "1 / 16194, \(bookmark)"
        )
    }

    @Test("印刷を予約したボタンの読み上げ名は画面のラベルと一致し、取り消せることを案内する")
    func pendingPrintAction() {
        let pending = BandAccessibility.printAction(pending: true)
        #expect(pending.title.key == "Print When Ready")
        #expect(pending.help.key == "Cancel")
        let ready = BandAccessibility.printAction(pending: false)
        #expect(ready.title.key == "Print")
        #expect(ready.help.key == "Open the print screen")
    }

    @Test("帯のズーム率は画面では空白なし、読み上げでは地域に合う整数のパーセントになる")
    func zoomPercentages() {
        let zoom = 1.246
        #expect(BandAccessibility.zoomPercentage(zoom) == "125%")
        #expect(BandAccessibility.zoomValue(zoom, locale: Locale(identifier: "en_US")) == "125%")
        let french = BandAccessibility.zoomValue(zoom, locale: Locale(identifier: "fr_FR"))
        #expect(["125\u{00A0}%", "125\u{202F}%"].contains(french))
    }

    @Test("スタイルと HTML プリセットでは現在の選択を読み上げ、見つからなければその旨を伝える")
    func styles() {
        let theme = BandStyleAccessibility.theme("Book · 125%")
        #expect(theme.name.key == "Style")
        #expect(theme.value == "Book · 125%")
        let preset = BandStyleAccessibility.preset("Article", smartRemoval: false)
        #expect(preset.name.key == "HTML Preset")
        #expect(preset.value == "Article")
        let smart = BandStyleAccessibility.preset("Article", smartRemoval: true)
        #expect(
            smart.value == String(format: String(localized: "%@: %@"), "Article", String(localized: "Smart Removal")))
        #expect(BandStyleAccessibility.theme(nil).value == String(localized: "Not Found"))
        #expect(BandStyleAccessibility.preset(nil, smartRemoval: false).value == String(localized: "Not Found"))
    }

    @Test("帯の寸法測定用の複製はアクセシビリティから隠す設定を使う")
    func measuringCopiesAreHidden() {
        #expect(BandMeasurements.isHiddenFromAccessibility)
    }
}
