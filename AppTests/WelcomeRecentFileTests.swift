import AppKit
import Foundation
import SurimonoCore
import SwiftUI
import Testing

@testable import Surimono

@MainActor
struct WelcomeRecentFileTests {
    @Test("開く操作だけが主ボタンで、どの言語のボタン名にもキーを載せない", arguments: UILanguage.supported)
    func openActions(language: String) {
        #expect(WelcomeAction.allCases == [.open, .clipboard])
        #expect(WelcomeAction.allCases.filter(\.isPrimary) == [.open])
        for action in WelcomeAction.allCases {
            var title = action.title
            title.locale = Locale(identifier: language)
            #expect(title.key == (action == .open ? "Open…" : "Open from Clipboard"))
            #expect(!String(localized: title).contains { "⌘⇧⌥⌃↩".contains($0) })
        }
    }

    @Test("ドロップ欄の対応形式は八言語すべてで最小幅の窓に一行で収まる")
    func formatsFit() throws {
        let labels = [
            "en": "Markdown, PDF, Word, LaTeX, Org, images, and more",
            "ja": "Markdown・PDF・Word・LaTeX・Org・画像ほか",
            "de": "Markdown, PDF, Word, LaTeX, Org, Bilder u. a.",
            "es": "Markdown, PDF, Word, LaTeX, Org, imágenes y más",
            "fr": "Markdown, PDF, Word, LaTeX, Org, images, etc.",
            "ko": "Markdown, PDF, Word, LaTeX, Org, 이미지 등",
            "zh-Hans": "Markdown、PDF、Word、LaTeX、Org、图像等",
            "zh-Hant": "Markdown、PDF、Word、LaTeX、Org、影像等",
        ]
        #expect(Set(labels.keys) == Set(UILanguage.supported))
        var measurements: [String] = []
        for language in UILanguage.supported {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let strings = try #require(Bundle(path: path))
            let value = strings.localizedString(
                forKey: "Markdown, PDF, Word, LaTeX, Org, images, and more", value: "", table: nil)
            #expect(value == labels[language])
            let locale = Locale(identifier: language)
            let view = WelcomeFormatsLine().environment(\.locale, locale)
            let size = NSHostingView(rootView: view.fixedSize()).fittingSize
            measurements.append("\(language): \(size.width) × \(size.height) pt")
            // The 500 pt window and the drop zone each have 24 pt of padding on either side.
            #expect(size.width > 0 && size.width <= 404)
        }
        Attachment.record(measurements.joined(separator: "\n"), named: "welcome-formats-widths.txt")
    }

    @Test("最近使ったファイルを読み直すのは開始画面自身がキーウインドウになったときだけ")
    func refreshOnWelcomeFocus() {
        let welcome = NSWindow()
        let document = NSWindow()
        var reads = 0
        func notify(_ key: NSWindow, welcome: NSWindow?) {
            let note = Notification(name: NSWindow.didBecomeKeyNotification, object: key)
            WelcomeController.refreshRecents(whenKey: note, window: welcome) { reads += 1 }
        }
        notify(document, welcome: nil)
        notify(document, welcome: welcome)
        #expect(reads == 0)
        notify(welcome, welcome: welcome)
        #expect(reads == 1)
    }

    @Test("最近使ったファイルの場所は、ホームの中なら ~ から書き、外ならそのまま書く")
    func folderNames() {
        let home = "/Users/reader"
        #expect(
            RecentFileRow.folder(of: URL(fileURLWithPath: "/Users/reader/Documents/notes.md"), home: home)
                == "~/Documents")
        #expect(RecentFileRow.folder(of: URL(fileURLWithPath: "/Users/reader/notes.md"), home: home) == "~")
        #expect(RecentFileRow.folder(of: URL(fileURLWithPath: "/Volumes/Share/a.pdf"), home: home) == "/Volumes/Share")
        // A folder that only begins with the same letters is not inside the home.
        #expect(
            RecentFileRow.folder(of: URL(fileURLWithPath: "/Users/readers/a.md"), home: home) == "/Users/readers")
    }
}
