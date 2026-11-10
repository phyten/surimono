import AppKit
import PDFKit
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct FindStateTests {
    @Test("新しい語の検索は、読んでいるページ以降の最初の一致から始まる")
    func startsAtTheReadingPage() {
        var state = FindState()
        let isNew1 = state.found([0, 2, 2, 5], for: "apple", readingPage: 1)
        #expect(isNew1)
        #expect(state.current == 1)
        #expect(state.currentPage == 2)
        #expect(state.countText == "2 / 4")
    }

    @Test("読んでいるページより後ろに一致がなければ、最初の一致へ回る")
    func wrapsToTheFirstHit() {
        var state = FindState()
        state.found([0, 1], for: "apple", readingPage: 4)
        #expect(state.current == 0)
        #expect(state.countText == "1 / 2")
    }

    @Test("一致がなければ 0 / 0 と出て、移る先もない")
    func nothingFound() {
        var state = FindState()
        let isNew2 = state.found([], for: "apple", readingPage: 0)
        #expect(!isNew2)
        #expect(state.current == nil)
        #expect(state.currentPage == nil)
        #expect(state.countText == "0 / 0")
        state.step(forward: true)
        #expect(state.current == nil)
        #expect(FindState().countText == "0 / 0")
    }

    @Test("次へは最後から最初へ、前へは最初から最後へ回る")
    func stepsAround() {
        var state = FindState()
        state.found([0, 1, 3], for: "apple", readingPage: 0)
        state.step(forward: true)
        #expect(state.current == 1)
        state.step(forward: true)
        #expect(state.current == 2)
        state.step(forward: true)
        #expect(state.current == 0)
        state.step(forward: false)
        #expect(state.current == 2)
        #expect(state.countText == "3 / 3")
    }

    @Test("同じ語を組み直したページで探し直すと、何番目の一致かを保ち、紙は動かさない")
    func keepsTheIndexAcrossASearchOfNewPages() {
        var state = FindState()
        state.found([0, 1, 3, 4], for: "apple", readingPage: 3)
        #expect(state.current == 2)
        let isNew3 = state.found([0, 2, 5, 6, 7], for: "apple", readingPage: 0)
        #expect(!isNew3)
        #expect(state.current == 2)
        #expect(state.countText == "3 / 5")
    }

    @Test("探し直して一致が減ったら最後の一致に寄せ、なくなったら 0 / 0 にする")
    func clampsTheIndex() {
        var state = FindState()
        state.found([0, 1, 3, 4], for: "apple", readingPage: 4)
        #expect(state.current == 3)
        state.found([0, 1], for: "apple", readingPage: 0)
        #expect(state.current == 1)
        state.found([], for: "apple", readingPage: 0)
        #expect(state.countText == "0 / 0")
        // Hits that come back start from the page being read again.
        let isNew4 = state.found([0, 6], for: "apple", readingPage: 3)
        #expect(!isNew4)
        #expect(state.current == 1)
    }

    @Test("ページへ移動は番号を 1 から最後のページまでに収め、数字でなければ動かない")
    func goToPageClamps() {
        #expect(GoToPage.index(for: "3", pageCount: 12) == 2)
        #expect(GoToPage.index(for: " 12 ", pageCount: 12) == 11)
        #expect(GoToPage.index(for: "0", pageCount: 12) == 0)
        #expect(GoToPage.index(for: "99", pageCount: 12) == 11)
        #expect(GoToPage.index(for: "99999999999999999999999", pageCount: 12) == 11)
        #expect(GoToPage.index(for: "７", pageCount: 12) == 6)
        #expect(GoToPage.index(for: "", pageCount: 12) == nil)
        #expect(GoToPage.index(for: "-3", pageCount: 12) == nil)
        #expect(GoToPage.index(for: "three", pageCount: 12) == nil)
        #expect(GoToPage.index(for: "3", pageCount: 0) == nil)
    }
}

/// The find bar's marks on the paper of a window.
@MainActor
struct PaperFindTests {
    private func makePaper(
        _ pages: [String], layout: ViewOptions.Layout = .single
    ) throws -> (view: PaperPDFView, source: PDFDocument, window: NSWindow) {
        let source = try #require(PDFDocument(data: TestFixtures.textPDF(pages)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        let view = PaperPDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 594))
        window.contentView = view
        view.show(source, at: 0)
        view.apply(ViewOptions(layout: layout, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false))
        view.layoutSubtreeIfNeeded()
        return (view, source, window)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    private func makeModel() -> (model: DocumentViewModel, cleanUp: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = TestDefaultsSuite()
        let model = DocumentViewModel(
            data: Data(), fileURL: nil, format: .markdown,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        return (
            model,
            {
                suite.remove()
                try? FileManager.default.removeItem(at: directory)
            }
        )
    }

    private let pages = ["An apple a day", "banana", "Apple pie and APPLE jam", "cherry"]

    @Test("探すと、大文字と小文字を区別せずにすべての一致へ印が付き、ページには何も書き足さない", .timeLimit(.minutes(1)))
    func marksEveryHit() async throws {
        let (view, source, window) = try makePaper(pages)
        var found: [Int]?
        view.onFindHits = { pages, _ in found = pages }
        view.find("apple")
        // The search runs between the main run loop's other work; nothing is marked before it reports.
        #expect(found == nil)
        try await waitUntil { found != nil }
        #expect(found == [0, 2, 2])
        #expect(view.highlightedSelections?.count == 3)
        #expect(view.highlightedSelections?.map { $0.string?.lowercased() } == ["apple", "apple", "apple"])
        // The marks are the view's own highlights: neither the print nor the export can carry them.
        #expect(view.document === source)
        for index in 0..<source.pageCount {
            #expect(source.page(at: index)?.annotations.isEmpty == true)
        }
        withExtendedLifetime(window) {}
    }

    @Test("一致へ移ると、そのページへめくられ、今の一致だけが別の色になり、紙の中に見えている", .timeLimit(.minutes(1)))
    func revealsTheCurrentHit() async throws {
        let (view, _, window) = try makePaper(pages)
        var found: [Int]?
        var shown: [Int] = []
        view.onFindHits = { pages, _ in found = pages }
        view.onPageChange = { shown.append($0) }
        view.find("apple")
        try await waitUntil { found != nil }
        view.markFindHit(1, reveals: true)
        #expect(view.currentPageIndex == 2)
        #expect(shown.last == 2)
        let hits = try #require(view.highlightedSelections)
        #expect(hits[1].color != hits[0].color)
        #expect(hits[2].color == hits[0].color)
        let page = try #require(hits[1].pages.first)
        let rect = view.convert(hits[1].bounds(for: page), from: page)
        #expect(view.bounds.insetBy(dx: -3, dy: -3).contains(rect))
        // The line starts 72 pt from the left of a 595 pt page shown 420 pt wide.
        #expect(abs(rect.minX - 72 * 420 / 595) < 3)
        view.markFindHit(0, reveals: true)
        #expect(view.currentPageIndex == 0)
        withExtendedLifetime(window) {}
    }

    @Test("拡大した紙では、窓の外にある一致まで紙を送る", .timeLimit(.minutes(1)))
    func scrollsAZoomedPaperToTheHit() async throws {
        let (view, _, window) = try makePaper(["first", "a line of filler and then, far to the right, the needle"])
        var found: [Int]?
        view.onFindHits = { pages, _ in found = pages }
        view.setZoom(4, anchor: NSPoint(x: 0, y: 0))
        view.find("needle")
        try await waitUntil { found != nil }
        #expect(found == [1])
        view.markFindHit(0, reveals: true)
        #expect(view.currentPageIndex == 1)
        let hit = try #require(view.highlightedSelections?.first)
        let page = try #require(hit.pages.first)
        let rect = view.convert(hit.bounds(for: page), from: page)
        #expect(view.bounds.insetBy(dx: -3, dy: -3).contains(NSPoint(x: rect.minX, y: rect.midY)))
        withExtendedLifetime(window) {}
    }

    @Test("見開きでも、一致のあるページを読む順のページ番号で返し、その見開きへめくる", .timeLimit(.minutes(1)))
    func findsInASpread() async throws {
        let (view, _, window) = try makePaper(pages, layout: .spread)
        var found: [Int]?
        view.onFindHits = { pages, _ in found = pages }
        view.find("APPLE")
        try await waitUntil { found != nil }
        #expect(found == [0, 2, 2])
        view.markFindHit(2, reveals: true)
        #expect(view.currentPageIndex == 2)
        withExtendedLifetime(window) {}
    }

    @Test("語を空にすると印が消え、文字のないページでは何も見つからない", .timeLimit(.minutes(1)))
    func clearsTheMarks() async throws {
        let (view, _, window) = try makePaper(pages)
        var found: [Int]?
        view.onFindHits = { pages, _ in found = pages }
        view.find("apple")
        try await waitUntil { found != nil }
        view.find("")
        #expect(view.highlightedSelections == nil)
        #expect(view.findHits.isEmpty)
        let blank = try #require(PDFDocument(data: TestFixtures.pdf("find", pages: 2)))
        view.show(blank, at: 0)
        found = nil
        view.find("apple")
        try await waitUntil { found != nil }
        #expect(found == [])
        #expect(view.highlightedSelections == nil)
        withExtendedLifetime(window) {}
    }

    @Test("ページが組み直されたら、新しいページで同じ語を探し直す", .timeLimit(.minutes(1)))
    func searchesNewPagesAgain() async throws {
        let (view, _, window) = try makePaper(pages)
        var answers: [[Int]] = []
        view.onFindHits = { pages, _ in answers.append(pages) }
        view.find("apple")
        try await waitUntil { answers.count == 1 }
        let next = try #require(PDFDocument(data: TestFixtures.textPDF(["cherry", "apple", "apple", "apple"])))
        view.show(next, at: 0)
        // The marks of the pages that went away go with them.
        #expect(view.highlightedSelections == nil)
        try await waitUntil { answers.count == 2 }
        #expect(answers == [[0, 2, 2], [1, 2, 3]])
        #expect(view.highlightedSelections?.count == 3)
        #expect(view.highlightedSelections?.first?.pages.first === next.page(at: 1))
        withExtendedLifetime(window) {}
    }

    @Test("打ち直した語は、前の語の検索を取り消して探す", .timeLimit(.minutes(1)))
    func cancelsTheSearchBefore() async throws {
        let (view, _, window) = try makePaper(pages)
        var answers: [String] = []
        view.onFindHits = { _, query in answers.append(query) }
        view.find("apple")
        view.find("banana")
        try await waitUntil { !answers.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(answers == ["banana"])
        #expect(view.highlightedSelections?.count == 1)
        withExtendedLifetime(window) {}
    }

    @Test("検索バーは打つのが止まってから探し、次へ・前へで回り、閉じると語と印を紙から外す", .timeLimit(.minutes(1)))
    func barFlow() async throws {
        let (model, cleanUp) = makeModel()
        defer { cleanUp() }
        model.performFind()
        #expect(model.find.isPresented)
        #expect(model.find.state.countText == "0 / 0")
        model.find.text = "app"
        model.find.text = "apple"
        #expect(model.find.query == "")
        try await waitUntil { model.find.query == "apple" }
        // An answer for words typed over since is dropped.
        model.paperFound([0], for: "app")
        #expect(model.find.state.countText == "0 / 0")
        model.currentPageIndex = 1
        model.paperFound([0, 2, 2], for: "apple")
        #expect(model.find.state.countText == "2 / 3")
        model.findStep(forward: true)
        #expect(model.find.state.countText == "3 / 3")
        model.findStep(forward: true)
        #expect(model.find.state.countText == "1 / 3")
        model.findStep(forward: false)
        #expect(model.find.state.countText == "3 / 3")
        // The pages were laid out again: the same words keep their hit.
        model.paperFound([0, 1, 2, 3], for: "apple")
        #expect(model.find.state.countText == "3 / 4")
        model.closeFind()
        #expect(!model.find.isPresented)
        #expect(model.find.query == "")
        #expect(model.find.state.countText == "0 / 0")
        // The bar opens again on the words of the last search, without waiting.
        model.findStep(forward: true)
        #expect(model.find.isPresented)
        #expect(model.find.query == "apple")
    }

    @Test("語を消すと、待たずに印を外す")
    func emptyTextClearsAtOnce() async throws {
        let (model, cleanUp) = makeModel()
        defer { cleanUp() }
        model.performFind()
        model.find.text = "apple"
        try await waitUntil { model.find.query == "apple" }
        model.paperFound([0, 2], for: "apple")
        model.find.text = ""
        #expect(model.find.query == "")
        #expect(model.find.state.countText == "0 / 0")
    }

    @Test("刷り台では ⌘F・⌘G・ページへ移動は何もしない")
    func ignoredOnThePrintScreen() {
        let (model, cleanUp) = makeModel()
        defer { cleanUp() }
        model.mode = .print
        model.performFind()
        model.findStep(forward: true)
        model.presentGoToPage()
        #expect(!model.find.isPresented)
        #expect(!model.isGoToPagePresented)
    }

    @Test("検索・次を検索・前を検索・ページへ移動・再読み込みは、メニューに 1 つずつあり、キーが重ならない")
    func menuItems() throws {
        let menu = try #require(NSApp.mainMenu)
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) }
        }
        func localized(_ key: String) -> String {
            Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        let all = items(menu)
        let edit = try #require(menu.items[2].submenu)
        let view = try #require(menu.items[3].submenu)
        let document = try #require(menu.items[4].submenu)
        for (title, key, flags, owner) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, edit),
            ("Find Next", "g", .command, edit),
            ("Find Previous", "g", [.shift, .command], edit),
            ("Go to Page…", "g", [.option, .command], view),
            ("Reload", "r", .command, document),
        ] {
            let named = all.filter { $0.title == localized(title) }
            #expect(named.count == 1, "\(title)")
            #expect(named.first?.menu === owner, "\(title)")
            #expect(named.first?.isEnabled == true, "\(title)")
            // A shifted letter may be stored as the capital with or without the Shift flag.
            let keyed = all.filter { item in
                let mask = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                let isShifted = mask.contains(.shift) || item.keyEquivalent == key.uppercased()
                return item.keyEquivalent.lowercased() == key && mask.subtracting(.shift) == flags.subtracting(.shift)
                    && isShifted == flags.contains(.shift)
            }
            #expect(keyed.map(\.title) == [localized(title)], "\(title)")
        }
    }
}
