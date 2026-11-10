import AppKit

extension DocumentViewModel {
    /// Only the paper of the view mode is searched: the print screen keeps its own keys, and the live page of an HTML
    /// document is not made of pages.
    private var hasPaperToSearch: Bool { mode == .view && !showsWeb }

    /// Edit › Find…. The item stays enabled everywhere (see `DocumentCommands`), so where there is no paper to search
    /// nothing happens.
    func performFind() {
        guard hasPaperToSearch else { return }
        find.open()
    }

    /// Edit › Find Next and Find Previous, and the bar's own keys and buttons. With the bar closed they open it on the
    /// words of the last search.
    func findStep(forward: Bool) {
        guard hasPaperToSearch else { return }
        guard find.isPresented else {
            find.open()
            return
        }
        find.step(forward: forward)
        paper.markFindHit(find.state.current, reveals: true)
    }

    /// Closes the bar, which takes the marks off the paper, and gives the keys back to the paper.
    func closeFind() {
        guard find.isPresented else { return }
        find.close()
        paper.focus()
    }

    /// The paper found these hits for `query`: the logical page of each, in the document's order.
    func paperFound(_ pages: [Int], for query: String) {
        let isNew = find.found(pages, for: query, readingPage: currentPageIndex)
        // Words searched again on new pages keep their hit, and the reader stays where they are reading.
        paper.markFindHit(find.state.current, reveals: isNew)
    }

    /// View › Go to Page….
    func presentGoToPage() {
        guard hasPaperToSearch, pageCount > 0 else { return }
        isGoToPagePresented = true
    }

    /// Turns to the page typed into Go to Page, by the numbers the page indicator shows.
    func goToPage(entered text: String) {
        isGoToPagePresented = false
        guard let index = GoToPage.index(for: text, pageCount: pageCount) else { return }
        paper.goToPage(index: index)
    }
}
