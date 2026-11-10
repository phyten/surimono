import Foundation
import Observation

/// What a search of the paper came to: the page of every hit in the document's order, and which hit is the current
/// one. It knows nothing of PDFKit, so the stepping and the count are fixed by tests.
struct FindState: Equatable {
    /// The words the hits were found for.
    private(set) var query = ""
    /// The 0-based logical page of each hit, in the order of the document.
    private(set) var pages: [Int] = []
    private(set) var current: Int?

    var count: Int { pages.count }
    /// "3 / 12", and "0 / 0" when nothing was found.
    var countText: String { "\(current.map { $0 + 1 } ?? 0) / \(count)" }
    var currentPage: Int? { current.map { pages[$0] } }

    /// Takes the hits of a search. New words start at the first hit on or after the page being read, as a reader
    /// expects of a search that starts where they are; it reports true then, so the caller turns to that hit. The same
    /// words searched again, as after the pages were laid out anew, keep the hit they were on as nearly as the new
    /// hits allow, and the reader stays on the page they are reading.
    @discardableResult
    mutating func found(_ pages: [Int], for query: String, readingPage: Int) -> Bool {
        let isNew = query != self.query
        self.query = query
        self.pages = pages
        if pages.isEmpty {
            current = nil
        } else if !isNew, let current {
            self.current = min(current, pages.count - 1)
        } else {
            current = pages.firstIndex { $0 >= readingPage } ?? 0
        }
        return isNew && current != nil
    }

    /// The next or the previous hit, going round at either end.
    mutating func step(forward: Bool) {
        guard !pages.isEmpty else { return }
        guard let current else {
            self.current = forward ? 0 : pages.count - 1
            return
        }
        self.current = (current + (forward ? 1 : pages.count - 1)) % pages.count
    }
}

/// The find bar of one window. It is never saved: a document opens without a search.
@Observable
final class PaperFind {
    /// How long the reader must stop typing before the paper is searched.
    static let typingPause = Duration.milliseconds(180)

    private(set) var isPresented = false
    /// What the field holds, as it is typed.
    var text = "" {
        didSet { if text != oldValue { textChanged() } }
    }
    /// What the paper is asked to search for: the field's text once the typing has paused, and nothing while the bar
    /// is closed, which takes the marks off the paper.
    private(set) var query = ""
    private(set) var state = FindState()
    /// Counts the times the bar was asked for, so that ⌘F on an open bar brings the field its focus back.
    private(set) var focusRequests = 0
    @ObservationIgnored private var pause: Task<Void, Never>?

    func open() {
        isPresented = true
        focusRequests += 1
        // The words of the last search are still in the field.
        pause?.cancel()
        setQuery(text)
    }

    func close() {
        pause?.cancel()
        isPresented = false
        setQuery("")
    }

    func step(forward: Bool) {
        state.step(forward: forward)
    }

    /// The paper's answer for `query`. An answer for words that were typed over since is dropped.
    @discardableResult
    func found(_ pages: [Int], for query: String, readingPage: Int) -> Bool {
        guard isPresented, query == self.query, !query.isEmpty else { return false }
        return state.found(pages, for: query, readingPage: readingPage)
    }

    private func textChanged() {
        pause?.cancel()
        guard isPresented else { return }
        guard !text.isEmpty else {
            setQuery("")
            return
        }
        pause = Task { [weak self] in
            try? await Task.sleep(for: Self.typingPause)
            guard !Task.isCancelled, let self else { return }
            setQuery(text)
        }
    }

    private func setQuery(_ value: String) {
        if value.isEmpty { state = FindState() }
        if query != value { query = value }
    }
}

/// The page a reader asked for by its number.
enum GoToPage {
    /// The 0-based page for what was typed, held within the document's pages; nil when it is no number.
    static func index(for text: String, pageCount: Int) -> Int? {
        let digits =
            (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
            .trimmingCharacters(in: .whitespaces)
        guard pageCount > 0, !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        // A number too long for Int is past the last page all the same.
        let number = Int(digits) ?? Int.max
        return min(max(number, 1), pageCount) - 1
    }
}
