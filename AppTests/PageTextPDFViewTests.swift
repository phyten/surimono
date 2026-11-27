import AppKit
import CoreText
import PDFKit
import Testing

@testable import Surimono

@MainActor
struct PageTextPDFViewTests {
    @Test("画面を読むアプリに渡す子は、Surimono のページの要素だけになる")
    func childrenAreOurOwnElements() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let children = try #require(view.accessibilityChildren())
        #expect(!children.isEmpty)
        #expect(children.allSatisfy { $0 is PageTextElement })
        withExtendedLifetime(window) {}
    }

    @Test("テストの中では PDFKit のページ解析を止める（CI でスレッドを使い切って本体が固まるため）")
    func analysisStopsInTests() throws {
        let view = PageTextPDFView()
        guard view.responds(to: NSSelectorFromString("setDocumentAnalysisEnabled:")) else {
            #expect(view.document == nil)
            return
        }
        try #require(
            view.responds(to: NSSelectorFromString("isDocumentAnalysisEnabled"))
                || view.responds(to: NSSelectorFromString("documentAnalysisEnabled")))
        #expect(view.value(forKey: "documentAnalysisEnabled") as? Bool == false)
        let document: PDFDocument = try #require(PDFDocument(data: textPDF(["analysis setting"])))
        view.document = document
        #expect(view.value(forKey: "documentAnalysisEnabled") as? Bool == false)
    }

    @Test("PDFKit がメインスレッド以外から document を読むと、紙に入れた文書が返る")
    func documentIsReadableFromTheAnalysisQueue() async throws {
        let view = PageTextPDFView()
        let document = try #require(PDFDocument(data: textPDF(["first page"])))
        view.document = document
        let getter = #selector(getter: PDFView.document)
        // An isolated override would trap the entire test host on the background message below.
        let inherited = try #require(class_getInstanceMethod(PDFView.self, getter))
        try #require(class_getInstanceMethod(PageTextPDFView.self, getter) == inherited)
        // The worker sends only the inherited getter; the test retains the view and leaves its document in place.
        nonisolated(unsafe) let receiver: NSObject = view
        let identity: ObjectIdentifier? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { @Sendable in
                #expect(!Thread.isMainThread)
                let result = receiver.perform(getter)?.takeUnretainedValue()
                continuation.resume(returning: result.map(ObjectIdentifier.init))
            }
        }
        #expect(identity == ObjectIdentifier(document))
    }

    @Test("ページの要素は、そのページの文字を読める")
    func elementReadsItsPage() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let element = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        #expect(element.accessibilityRole() == .staticText)
        #expect((element.accessibilityValue() as? String)?.contains("first page") == true)
        #expect(element.accessibilityLabel() == String(localized: "Page \(1)"))
        withExtendedLifetime(window) {}
    }

    #if DEBUG
        @Test("検査開始時だけページの識別子を公開し、同じページの読み上げと要素を保つ")
        func probePageIdentifier() throws {
            let (view, window) = try makePaper(pages: ["first page"])
            let ordinary = try #require(view.accessibilityChildren()?.first as? PageTextElement)
            #expect(ordinary.accessibilityIdentifier() == nil)
            view.identifyProbePaper("fixture")
            let tagged = try #require(view.accessibilityChildren()?.first as? PageTextElement)
            #expect(tagged.accessibilityIdentifier() == "fixture.page.0")
            #expect(tagged.accessibilityLabel() == String(localized: "Page \(1)"))
            #expect(tagged.accessibilityValue() as? String == "first page")
            view.identifyProbePaper("fixture")
            #expect(view.accessibilityChildren()?.first as? PageTextElement === tagged)
            withExtendedLifetime(window) {}
        }
    #endif

    @Test("座標から要素を探しても、PDFKit のノードを渡さない")
    func hitTestStaysOnOurElements() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let center = window.convertPoint(toScreen: view.convert(NSPoint(x: 210, y: 297), to: nil))
        #expect(view.accessibilityHitTest(center) is PageTextElement)
        withExtendedLifetime(window) {}
    }

    @Test("紙をクリックして内側のビューにフォーカスが移っても、PDFKit のノードを渡さない")
    func focusStaysOnOurElements() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let inner = try #require(view.documentView)
        #expect(window.makeFirstResponder(inner))
        let scrollView = try #require(inner.enclosingScrollView)
        #expect((NSAccessibility.unignoredAncestor(of: inner) as? NSView) === view)
        #expect(scrollView.accessibilityChildren()?.isEmpty == true)
        #expect((view.accessibilityFocusedUIElement as? NSView) === view)
        withExtendedLifetime(window) {}
    }

    @Test("見えているページが変わると、子もそのページになる")
    func childrenFollowTheVisiblePage() throws {
        let (view, window) = try makePaper(pages: ["first page", "second page"])
        let second = try #require(view.document?.page(at: 1))
        view.go(to: second)
        view.layoutSubtreeIfNeeded()
        let element = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        #expect((element.accessibilityValue() as? String)?.contains("second page") == true)
        #expect(element.accessibilityLabel() == String(localized: "Page \(2)"))
        withExtendedLifetime(window) {}
    }

    @Test("同じページには同じ要素を返す（読み手が読んでいる場所を失わないため）")
    func elementsStayTheSameForAPage() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let first = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        let again = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        #expect(first === again)
        withExtendedLifetime(window) {}
    }

    @Test("紙と文書を捨てたあとに読まれても、持っていた要素は文字を返す")
    func elementOutlivesThePaper() throws {
        let element = try autoreleasepool { () throws -> PageTextElement in
            let (view, window) = try makePaper(pages: ["first page"])
            let element = try #require(view.accessibilityChildren()?.first as? PageTextElement)
            view.document = nil
            window.contentView = nil
            return element
        }
        #expect((element.accessibilityValue() as? String)?.contains("first page") == true)
        #expect(element.accessibilityFrame() == .zero)
    }

    @Test("ページと元のPDFを解放した後も、公開済みの要素だけで本文・範囲・行と位置に答える")
    func snapshotOutlivesPDF() throws {
        weak var source: PDFDocument?
        weak var originalPage: PDFPage?
        weak var parent: PageTextPDFView?
        let leaf = try autoreleasepool {
            let document = try #require(PDFDocument(data: textPDF(["first page"])))
            let page = try #require(document.page(at: 0))
            // Keep PDFKit's window and analysis caches outside this ownership assertion.
            let paper = PageTextPDFView()
            source = document
            originalPage = page
            parent = paper
            return PageTextElement(page: page, index: 0, parent: paper)
        }
        try #require(source == nil && originalPage == nil && parent == nil)
        let text = try #require(leaf.accessibilityValue() as? String)
        let range = (text as NSString).range(of: "first")
        try #require(range.location != NSNotFound)
        #expect(leaf.accessibilityRole() == .staticText)
        #expect(leaf.accessibilityLabel() == String(localized: "Page \(1)"))
        #expect(leaf.accessibilityNumberOfCharacters() == text.utf16.count)
        #expect(leaf.accessibilityString(for: range) == "first")
        #expect(leaf.accessibilityAttributedString(for: range)?.string == "first")
        #expect(leaf.accessibilityLine(for: range.location) == 0)
        #expect(leaf.accessibilityRange(forLine: 0) == (text as NSString).lineRange(for: range))
        #expect(leaf.accessibilityRange(for: range.location) == NSRange(location: range.location, length: 1))
        #expect(leaf.accessibilityFrame() == .zero)
        #expect(leaf.accessibilityFrame(for: range) == .zero)
        #expect(leaf.accessibilityRange(for: NSPoint.zero).location == NSNotFound)
        #expect(leaf.accessibilityParent() == nil)
        #expect(leaf.accessibilityChildren()?.isEmpty != false)
        #expect(leaf.accessibilityString(for: NSRange(location: NSNotFound, length: 1)) == nil)
    }

    @Test("公開した文字の矩形は紙の上を指し、同じビューが別の文書に替わると消える")
    func snapshotRangeGeometry() throws {
        let (view, window) = try makePaper(pages: ["first page"])
        let leaf = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        let page = try #require(view.document?.page(at: 0))
        let range = NSRange(location: 0, length: 1)
        let selection = try #require(page.selection(for: range))
        let box = window.convertToScreen(view.convert(view.convert(selection.bounds(for: page), from: page), to: nil))
        let frame = leaf.accessibilityFrame(for: range)
        #expect(!frame.isEmpty && abs(box.midX - frame.midX) < 0.1 && abs(box.midY - frame.midY) < 0.1)
        #expect(leaf.accessibilityRange(for: CGPoint(x: frame.midX, y: frame.midY)) == range)
        let replacement: PDFDocument = try #require(PDFDocument(data: textPDF(["second page"])))
        view.document = replacement
        #expect(leaf.accessibilityParent() == nil)
        #expect(leaf.accessibilityFrame() == .zero)
        #expect(leaf.accessibilityFrame(for: range) == .zero)
        #expect(leaf.accessibilityString(for: range) == "f")
    }

    private final class UnsettledPaper: PageTextPDFView {
        var selectionIsReady = false
        var reads = 0
        var clock = ContinuousClock.now
        var copyIsAvailable = true
        var copyAttempts = 0
        weak var copyDocument: PDFDocument?

        override var selectionRetryTime: ContinuousClock.Instant { clock }

        override func withSelectionCopy(of page: PDFPage, matching text: NSString, read: (PDFPage) -> Bool) {
            copyAttempts += 1
            guard copyIsAvailable else { return }
            super.withSelectionCopy(of: page, matching: text) { copy in
                copyDocument = copy.document
                return read(copy)
            }
        }

        override func characterSelectionBounds(for range: NSRange, on page: PDFPage) -> CGRect? {
            reads += 1
            guard selectionIsReady else { return .null }
            return super.characterSelectionBounds(for: range, on: page)
        }
    }

    @Test("差し替え直後に文字の枠が未確定でも、同じ要素が次の問い合わせで本文の位置を返す", arguments: [true, false])
    func recoversUnsettledSelection(liveSelectionRecovers: Bool) async throws {
        let view = UnsettledPaper(frame: CGRect(x: 0, y: 0, width: 420, height: 594))
        let (_, window) = try makePaper(document: #require(PDFDocument(data: textPDF(["old page"]))), view: view)
        let replacement = try #require(PDFDocument(data: textPDF(["世代"])))
        let page = try #require(replacement.page(at: 0))
        view.reads = 0
        view.document = replacement
        view.go(to: page)
        view.layoutSubtreeIfNeeded()
        let leaf = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        #expect(leaf.accessibilityValue() as? String == "世代")
        #expect(view.reads > 0)
        await Task.yield()
        view.selectionIsReady = liveSelectionRecovers
        let range = NSRange(location: 0, length: 1)
        let inside = window.convertPoint(
            toScreen: view.convert(view.convert(CGPoint(x: 48, y: 506), from: page), to: nil))
        if !liveSelectionRecovers { #expect(leaf.accessibilityRange(for: inside) == range) }
        let box = leaf.accessibilityFrame(for: range)
        let reads = view.reads
        #expect(leaf.accessibilityFrame(for: range) == box)
        #expect(view.reads == reads)
        #expect(box.contains(inside), "\(selectionDetail(page, range: range))")
        #expect(abs(box.width - 16 * view.scaleFactor) < 1)
        #expect(leaf.accessibilityRange(for: inside) == range)
        #expect(view.accessibilityChildren()?.first as? PageTextElement === leaf)
        view.document = nil
        #expect(leaf.accessibilityFrame(for: range) == .zero)
        #expect(leaf.accessibilityString(for: range) == "世")
        withExtendedLifetime(window) {}
    }

    @Test("文字の位置が未確定の間は、連続して聞かれても元の紙とコピーを一定の間隔でだけ調べる")
    func throttlesUnresolvedPositions() throws {
        let view = UnsettledPaper(frame: CGRect(x: 0, y: 0, width: 420, height: 594))
        view.copyIsAvailable = false
        let line = String(repeating: "iI", count: 20)
        let text = Array(repeating: line, count: 25).joined(separator: "\n")
        let document = try #require(PDFDocument(data: textPDF([text], lineSpacing: 18)))
        let (_, window) = try makePaper(document: document, view: view)
        let leaf = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        let first = NSRange(location: 0, length: 1)
        let paper = leaf.accessibilityFrame()
        let margin = CGPoint(x: paper.minX + 1, y: paper.minY + 1)
        let initialReads = view.reads
        for _ in 0..<100 {
            #expect(leaf.accessibilityRange(for: margin).location == NSNotFound)
            #expect(leaf.accessibilityFrame(for: first) == .zero)
        }
        try #require(leaf.accessibilityValue() as? String == text)
        let count = 1000
        #expect(view.reads - initialReads == count)
        #expect(view.copyAttempts == 1)

        view.clock += .milliseconds(249)
        #expect(leaf.accessibilityFrame(for: first) == .zero)
        #expect(view.reads - initialReads == count && view.copyAttempts == 1)
        view.clock += .milliseconds(1)
        #expect(leaf.accessibilityFrame(for: first) == .zero)
        #expect(view.reads - initialReads == count + 1 && view.copyAttempts == 2)

        view.selectionIsReady = true
        view.clock += .milliseconds(250)
        #expect(!leaf.accessibilityFrame(for: first).isEmpty)
        #expect(!leaf.accessibilityFrame(for: first).isEmpty)
        #expect(view.reads - initialReads == count + 2 && view.copyAttempts == 2)
        withExtendedLifetime(window) {}
    }

    @Test("未確定の文字の再試行を待つ間も、確定した文字の枠は拡大・スクロール・窓の移動に追従する")
    func resolvedFrameDuringBackoff() throws {
        let view = UnsettledPaper(frame: CGRect(x: 0, y: 0, width: 420, height: 594))
        view.copyIsAvailable = false
        let document = try #require(PDFDocument(data: textPDF(["世代"])))
        let page = try #require(document.page(at: 0))
        let (_, window) = try makePaper(document: document, view: view)
        view.scaleFactor = 1
        view.layoutSubtreeIfNeeded()
        let leaf = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        let first = NSRange(location: 0, length: 1)
        let second = NSRange(location: 1, length: 1)
        func expectFrame(_ range: NSRange) throws {
            let selection = try #require(page.selection(for: range))
            let local = view.convert(selection.bounds(for: page), from: page)
            let expected = window.convertToScreen(view.convert(local, to: nil))
            let actual = leaf.accessibilityFrame(for: range)
            #expect(!expected.isEmpty)
            #expect(abs(actual.minX - expected.minX) < 0.1 && abs(actual.maxX - expected.maxX) < 0.1)
            #expect(abs(actual.minY - expected.minY) < 0.1 && abs(actual.maxY - expected.maxY) < 0.1)
        }

        view.selectionIsReady = true
        let originalFrame = leaf.accessibilityFrame(for: first)
        try #require(!originalFrame.isEmpty)
        view.selectionIsReady = false
        let reads = view.reads
        #expect(leaf.accessibilityFrame(for: second) == .zero)
        #expect(view.reads == reads + 1 && view.copyAttempts == 1)

        view.selectionIsReady = true
        view.clock += .milliseconds(249)
        view.scaleFactor = 2
        view.layoutSubtreeIfNeeded()
        let scroll = try #require(view.documentView?.enclosingScrollView)
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        let dy: CGFloat = clip.bounds.midY < clip.documentRect.midY ? 24 : -24
        clip.scroll(to: CGPoint(x: origin.x, y: origin.y + dy))
        scroll.reflectScrolledClipView(clip)
        try #require(clip.bounds.origin != origin)
        window.setFrameOrigin(CGPoint(x: window.frame.minX + 32, y: window.frame.minY + 20))
        try expectFrame(first)
        #expect(leaf.accessibilityFrame(for: first) != originalFrame)
        #expect(leaf.accessibilityFrame(for: second) == .zero)
        #expect(view.reads == reads + 1 && view.copyAttempts == 1)

        view.clock += .milliseconds(2)
        try expectFrame(second)
        #expect(view.reads == reads + 2 && view.copyAttempts == 1)
    }

    @Test("メインスレッド以外からの同期問い合わせにも紙と同じ文字範囲と位置を返す")
    func geometryFromAnotherQueue() async throws {
        let (view, window) = try makePaper(pages: ["first page"])
        // The worker calls only synchronous nonisolated AX entry points while the test keeps the window alive.
        nonisolated(unsafe) let leaf = try #require(view.accessibilityChildren()?.first as? PageTextElement)
        let range = NSRange(location: 0, length: 1)
        let expected = leaf.accessibilityFrame(for: range)
        let center = CGPoint(x: expected.midX, y: expected.midY)
        nonisolated(unsafe) let receiver = view
        let valid = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { @Sendable in
                let matches =
                    leaf.accessibilityFrame(for: range) == expected && leaf.accessibilityRange(for: center) == range
                    && (receiver.accessibilityHitTest(center) as? PageTextElement) === leaf
                continuation.resume(returning: matches)
            }
        }
        #expect(!expected.isEmpty && valid)
        withExtendedLifetime(window) {}
    }

    @Test("回転と切り抜きのある紙でも、日本語・補助平面の文字・改行の範囲と位置が一致する", arguments: [true, false])
    func rotatedUnicodePage(liveSelectionIsReady: Bool) async throws {
        weak var source: PDFDocument?
        weak var temporary: PDFDocument?
        let leaf = try autoreleasepool {
            let document = try #require(PDFDocument(data: textPDF(["日本𠮷野\n次の行あ\u{3099}"])))
            let page = try #require(document.page(at: 0))
            page.setBounds(CGRect(x: 15, y: 30, width: 380, height: 520), for: .cropBox)
            page.rotation = 90
            source = document
            let view = UnsettledPaper(frame: CGRect(x: 0, y: 0, width: 420, height: 594))
            view.selectionIsReady = liveSelectionIsReady
            let (_, window) = try makePaper(document: document, view: view)
            let leaf = try #require(view.accessibilityChildren()?.first as? PageTextElement)
            #expect(leaf.accessibilityValue() as? String == "日本𠮷野\n次の行あ\u{3099}")
            #expect(leaf.accessibilityNumberOfCharacters() == 11)
            #expect(leaf.accessibilityString(for: NSRange(location: 2, length: 2)) == "𠮷")
            #expect(leaf.accessibilityRange(for: 3) == NSRange(location: 2, length: 2))
            #expect(leaf.accessibilityRange(forLine: 0) == NSRange(location: 0, length: 6))
            #expect(leaf.accessibilityRange(forLine: 1) == NSRange(location: 6, length: 5))
            #expect(leaf.accessibilityLine(for: 6) == 1)
            #expect(leaf.accessibilityRange(for: 10) == NSRange(location: 9, length: 2))
            for scale in [1.0, 1.5] {
                view.scaleFactor = scale
                view.go(to: CGRect(x: 70, y: 480, width: 20, height: 20), on: page)
                window.setFrameOrigin(CGPoint(x: 120 * scale, y: 80 * scale))
                view.layoutSubtreeIfNeeded()
                // The fixture draws 16-point Japanese glyphs starting at (40, 500) and (40, 460).
                for (range, x, y) in [
                    (NSRange(location: 2, length: 2), 80.0, 506.0),
                    (NSRange(location: 4, length: 1), 96.0, 506.0),
                    (NSRange(location: 6, length: 1), 48.0, 466.0),
                ] {
                    let local = view.convert(CGPoint(x: x, y: y), from: page)
                    let center = window.convertPoint(toScreen: view.convert(local, to: nil))
                    let box = leaf.accessibilityFrame(for: range)
                    #expect(box.contains(center), "\(selectionDetail(page, range: range))")
                    // After rotation the advance is vertical. Font ascent and descent can change on a
                    // serialized page, but the selection must stay in this 40-point line and 16-point column.
                    #expect(abs(box.height - 16 * scale) < 1)
                    #expect(box.width >= 15 * scale)
                    #expect(box.minX > center.x - 20 * scale && box.maxX < center.x + 20 * scale)
                    #expect(leaf.accessibilityRange(for: center) == range)
                }
            }
            if !liveSelectionIsReady { #expect(view.copyAttempts == 1) }
            temporary = view.copyDocument
            view.document = nil
            window.contentView = nil
            return leaf
        }
        // PDFKit may finish a pending layout after the view has detached its document.
        let deadline = ContinuousClock.now + .seconds(5)
        while (source != nil || temporary != nil) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(source == nil && temporary == nil)
        let glyph = NSRange(location: 2, length: 2)
        #expect(leaf.accessibilityString(for: glyph) == "𠮷")
        #expect(leaf.accessibilityFrame(for: glyph) == .zero)
    }

    private func selectionDetail(_ page: PDFPage, range: NSRange) -> String {
        func detail(_ page: PDFPage) -> String {
            guard NSMaxRange(range) <= page.numberOfCharacters else {
                return "text=\(page.string.debugDescription) characters=\(page.numberOfCharacters)"
            }
            let hit = page.selection(for: range)
            let bounds = hit.map { $0.bounds(for: page) } ?? .null
            return "text=\(page.string.debugDescription) selectionPages=\(hit?.pages.count ?? 0) bounds=\(bounds) "
                + "glyph=\(page.characterBounds(at: range.location)) media=\(page.bounds(for: .mediaBox)) crop=\(page.bounds(for: .cropBox)) rotation=\(page.rotation)"
        }
        let inserted = PDFDocument()
        var native = "unavailable"
        if let clone = page.copy() as? PDFPage, clone !== page {
            inserted.insert(clone, at: 0)
            native = withExtendedLifetime(inserted) { detail(clone) }
        }
        let comparison = "range=\(range) live=[\(detail(page))] inserted=[\(native)]"
        guard let data = page.dataRepresentation, let copy = PDFDocument(data: data), let first = copy.page(at: 0)
        else { return comparison + " reopened=nil" }
        return withExtendedLifetime(copy) { comparison + " reopened=[\(detail(first))]" }
    }

    private func makePaper(pages: [String]) throws -> (PageTextPDFView, NSWindow) {
        let document = try #require(PDFDocument(data: textPDF(pages)))
        return try makePaper(document: document)
    }

    private func makePaper(
        document: PDFDocument,
        view: PageTextPDFView = PageTextPDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 594))
    ) throws -> (PageTextPDFView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 594), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = view
        view.displayMode = .singlePage
        view.displayBox = .cropBox
        view.document = document
        // A window that is not on screen has no visible pages until the view goes to one.
        view.go(to: try #require(document.page(at: 0)))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    private func textPDF(_ pages: [String], lineSpacing: Int = 40) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 420, height: 594)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in pages {
            context.beginPDFPage(nil)
            let font = try #require(NSFont(name: "HiraginoSans-W3", size: 16))
            for (line, body) in text.components(separatedBy: "\n").enumerated() {
                context.textPosition = CGPoint(x: 40, y: 500 - line * lineSpacing)
                let string = NSAttributedString(string: body, attributes: [.font: font])
                CTLineDraw(CTLineCreateWithAttributedString(string), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
