import AppKit
import Foundation
import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SlideDeckWebTests {
    init() {
        _ = NSApplication.shared
    }

    /// A deck whose own script shows one slide at a time, as decks with arrow keys do.
    private let deck = """
        <!doctype html><meta charset="utf-8"><style>
        body { margin: 0; background: #222; }
        .deck { position: relative; width: 1280px; height: 720px; }
        .deck > section { position: absolute; inset: 0; width: 1280px; height: 720px; display: flex;
          align-items: center; justify-content: center; background: white; font: 64px sans-serif; }
        .deck > section:not(.active) { display: none; }
        nav { position: fixed; bottom: 0; }
        </style><body><div class="deck">
        <section>One</section><section>Two</section><section>Three</section>
        <section>Four</section><section>Five</section><section>Six</section>
        </div><nav><button>Prev</button><button>Next</button></nav>
        <script>
        const slides = document.querySelectorAll('.deck > section');
        let current = 2;
        slides[current].classList.add('active');
        </script></body>
        """

    private let article = """
        <!doctype html><meta charset="utf-8"><style>
        main { max-width: 100%; } section { padding: 1em; }
        </style><body><main>
        <section><h2>One</h2><p>Text</p></section><section><h2>Two</h2><p>Text</p><p>More</p></section>
        <section><h2>Three</h2><p>Text</p></section><section><h2>Four</h2><p>Text</p></section>
        </main></body>
        """

    private let landscapeA4 = CGSize(width: 841.89, height: 595.28)

    private func facts(of html: String) async throws -> SlideDeck? {
        let result = try await WebPaginator().paginateWithResult(
            .html(html, baseURL: nil), pageSize: landscapeA4, margins: .uniform(millimeters: 15),
            allowsJavaScript: true, preparationScript: SlideDeckScript.javaScript)
        return SlideDeck.detect(fromJSON: try #require(result.preparationResult))
    }

    @Test("1 枚ずつ見せる JS のスライドを HTML から判定し、記事の区画はスライドにしない")
    func detectsFromHTML() async throws {
        let detected = try await facts(of: deck)
        #expect(detected == SlideDeck(size: CGSize(width: 1280, height: 720), count: 6, currentIndex: 2))
        #expect(try await facts(of: article) == nil)
    }

    private func pages(_ request: SlidePrintRequest) async throws -> PDFDocument {
        let margin = 15 * 72 / 25.4
        let printable = CGSize(width: landscapeA4.width - 2 * margin, height: landscapeA4.height - 2 * margin)
        return try await WebPaginator().paginate(
            .html(deck, baseURL: nil), pageSize: landscapeA4, margins: .uniform(millimeters: 15),
            allowsJavaScript: true,
            preparationScript: SlideDeckScript.printJavaScript(request, printableSize: printable))
    }

    @Test("1 枚しか見せない JS のスライドを全部刷ると、1 枚ずつ 6 ページになる")
    func printsEverySlide() async throws {
        let document = try await pages(SlidePrintRequest(slideSize: CGSize(width: 1280, height: 720), count: 6))
        #expect(document.pageCount == 6)
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            #expect(text.contains(["One", "Two", "Three", "Four", "Five", "Six"][index]))
            #expect(!text.contains("Next"))
        }
        // A slide fills the printable width, so its centred title sits in the middle of the page.
        let page = try #require(document.page(at: 0))
        let title = try #require(page.selection(for: NSRange(location: 0, length: 3))?.bounds(for: page))
        #expect(abs(title.midX - landscapeA4.width / 2) < 20)
    }

    @Test("今の 1 枚だけを刷ると、その 1 ページになる")
    func printsTheCurrentSlide() async throws {
        let document = try await pages(
            SlidePrintRequest(slideSize: CGSize(width: 1280, height: 720), count: 6, onlyIndex: 4))
        #expect(document.pageCount == 1)
        #expect(document.page(at: 0)?.string?.contains("Five") == true)
    }
}
