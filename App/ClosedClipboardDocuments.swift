import Foundation
import SurimonoCore

struct ClosedClipboardDocuments {
    static let didChange = Notification.Name("SurimonoClosedClipboardDocumentsDidChange")

    struct MenuItem: Identifiable, Equatable {
        let id: ContentHash
        let title: String

        init(id: ContentHash, title: String) {
            self.id = id
            let line = title.prefix { !$0.isNewline }
            self.title =
                line.count > 40 || line.endIndex != title.endIndex
                ? String(line.prefix(39)) + "…" : String(line)
        }
    }

    struct Entry {
        let menuItem: MenuItem
        let data: Data
        let format: DocumentFormat
        let title: String
        let origin: TextFormatOrigin?
        let baseURL: URL?
        let settings: DocumentSettings
        let page: Int
        let wasPrinting: Bool
        let alwaysOnTop: Bool
        let allSpaces: Bool
        let copies: Int
        let settingSet: UUID?

        init(model: DocumentViewModel, hash: ContentHash, data: Data, date: Date) {
            title = model.displayName
            let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            let formatName = ClipboardTextKind(model.format).map(ClipboardFormatText.name) ?? model.formatBadge
            var parts = [formatName, time, String(title.prefix(80))]
            if model.textFormatOrigin != nil, model.htmlBaseURL == nil {
                let words = String(decoding: data.prefix(256), as: UTF8.self).split(whereSeparator: \.isWhitespace)
                let excerpt = words.joined(separator: " ").prefix(60)
                if !excerpt.isEmpty { parts.append(String(excerpt)) }
            }
            menuItem = MenuItem(id: hash, title: parts.joined(separator: " · "))
            self.data = data
            format = model.format
            origin = model.textFormatOrigin
            baseURL = model.htmlBaseURL
            var settings = model.rememberedSettings
            settings.windowSize = model.currentPaperSize ?? model.viewPaperSizeBeforePrinting
            settings.bandVisibility = model.bandVisibility
            self.settings = settings
            page = model.currentPageIndex
            wasPrinting = model.mode == .print
            alwaysOnTop = model.isAlwaysOnTop
            allSpaces = model.showsOnAllSpaces
            copies = model.copies
            settingSet = model.selectedSettingSetID
        }

        func restore(in model: DocumentViewModel) {
            model.restoreClosedDocument(settings)
            model.currentPageIndex = page
            model.isAlwaysOnTop = alwaysOnTop
            model.showsOnAllSpaces = allSpaces
            model.copies = copies
            model.selectedSettingSetID = settingSet
        }
    }

    private(set) var entries: [Entry] = []
    private let byteLimit: Int

    init(byteLimit: Int = 50_000_000) {
        self.byteLimit = byteLimit
    }

    mutating func remember(_ entry: Entry) {
        guard entry.data.count <= byteLimit else { return }
        remove(entry.menuItem.id)
        entries.insert(entry, at: 0)
        while entries.count > 10 || entries.reduce(0, { $0 + $1.data.count }) > byteLimit {
            entries.removeLast()
        }
    }

    mutating func remove(_ id: ContentHash) {
        entries.removeAll { $0.menuItem.id == id }
    }
}
