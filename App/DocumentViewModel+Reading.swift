import Foundation
import SurimonoCore

extension DocumentViewModel {
    var canNavigateReading: Bool { mode == .view && !showsWeb && pageCount > 0 }
    var hasContents: Bool { !showsWeb && (pageCount > 1 || hasOutline || !bookmarkPages.isEmpty) }
    var bookmarkPages: [Int] { bookmarks.pages(pageCount: pageCount, entries: outlineEntries) }
    var visibleReadingPages: [Int] {
        let units = displayUnits
        return SpreadLayout.unitIndex(containing: currentPageIndex + 1, in: units)
            .map { units[$0].pages.map { $0 - 1 } } ?? [currentPageIndex]
    }
    var isVisiblePageBookmarked: Bool {
        canNavigateReading && !Set(bookmarkPages).isDisjoint(with: visibleReadingPages)
    }
    private var readingPosition: ReadingPosition {
        ReadingPosition(page: currentPageIndex, pageCount: pageCount, entries: outlineEntries)
    }

    func recordReadingJump(to page: Int) {
        guard canNavigateReading, (0..<pageCount).contains(page), page != currentPageIndex else { return }
        pageHistory.record(readingPosition)
    }

    func jumpToReadingPage(_ page: Int) {
        guard canNavigateReading, (0..<pageCount).contains(page) else { return }
        recordReadingJump(to: page)
        navigateReadingPage(page)
    }

    private func navigateReadingPage(_ page: Int) {
        // The model also owns the position while SwiftUI is replacing the paper after a reflow.
        currentPageIndex = visibleStart(of: page)
        paper.goToPage(index: page)
    }

    private func visibleStart(of page: Int) -> Int {
        let units = displayUnits
        return SpreadLayout.unitIndex(containing: page + 1, in: units)
            .flatMap { units[$0].pages.min() }.map { $0 - 1 } ?? page
    }

    func goBack() {
        guard canNavigateReading, let position = pageHistory.back(from: readingPosition) else { return }
        navigateReadingPage(position.page(pageCount: pageCount, entries: outlineEntries))
    }

    func goForward() {
        guard canNavigateReading, let position = pageHistory.forward(from: readingPosition) else { return }
        navigateReadingPage(position.page(pageCount: pageCount, entries: outlineEntries))
    }

    func toggleBookmark() {
        guard canNavigateReading else { return }
        toggleBookmark(page: currentPageIndex, visiblePages: visibleReadingPages)
    }

    func toggleBookmark(page: Int, visiblePages: [Int]) {
        guard canNavigateReading, (0..<pageCount).contains(page) else { return }
        let previous = bookmarks
        let added = bookmarks.toggle(
            page: page, visiblePages: visiblePages, pageCount: pageCount, entries: outlineEntries)
        let title: String
        if added {
            title = String(localized: "Bookmark Added")
        } else if bookmarks != previous {
            title = String(localized: "Bookmark Removed")
        } else {
            title = String(localized: "No More Bookmarks Can Be Added")
        }
        if bookmarks != previous { rememberedSettingsDidChange() }
        showToast(Toast(systemImage: "bookmark", title: title), dismissAfter: .seconds(2))
    }

    func removeBookmark(page: Int) {
        guard canNavigateReading else { return }
        let previous = bookmarks
        bookmarks.remove(page: page, pageCount: pageCount, entries: outlineEntries)
        guard previous != bookmarks else { return }
        rememberedSettingsDidChange()
        showToast(
            Toast(systemImage: "bookmark", title: String(localized: "Bookmark Removed")), dismissAfter: .seconds(2))
    }

    func goToBookmark(page: Int) {
        guard canNavigateReading else { return }
        isOutlinePresented = false
        jumpToReadingPage(page)
    }

    var nextBookmark: Int? {
        guard canNavigateReading else { return nil }
        return bookmarks.next(
            after: visibleReadingPages.max() ?? currentPageIndex, pageCount: pageCount, entries: outlineEntries)
    }

    var previousBookmark: Int? {
        guard canNavigateReading else { return nil }
        return bookmarks.previous(
            before: visibleReadingPages.min() ?? currentPageIndex, pageCount: pageCount, entries: outlineEntries)
    }

    func goToNextBookmark() {
        if let nextBookmark { goToBookmark(page: nextBookmark) }
    }

    func goToPreviousBookmark() {
        if let previousBookmark { goToBookmark(page: previousBookmark) }
    }

    func bookmarkTitle(page: Int) -> String {
        let index =
            DocumentOutline.currentChapter(in: outlineEntries, page: page)
            ?? DocumentOutline.currentEntry(in: outlineEntries, page: page)
        return index.map { outlineEntries[$0].title }
            ?? String(format: String(localized: "Page %lld"), page + 1)
    }
}
