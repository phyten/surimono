import AppKit
import Foundation
import Testing

@testable import SurimonoRendering

@MainActor
struct OfflineRulesTests {
    @Test("図の準備で通信を止めたあとも、文書が見せた画像の写しは読み、新しい画像は読まない", .timeLimit(.minutes(1)))
    func copiesOfShownImagesStillLoad() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appending(path: "surimono-offline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20"/></svg>"#
        // Brackets and parentheses in a name must stay literal in the rule's filter.
        for name in ["shown (1).svg", "later.svg"] {
            try Data(svg.utf8).write(to: folder.appending(path: name))
        }
        let page = folder.appending(path: "page.html")
        try Data(#"<!doctype html><img src="shown%20(1).svg">"#.utf8).write(to: page)
        let source = WebPaginator.Source.file(page, readAccessURL: folder)
        let session = PaginationSession(
            source: source, pageSize: CGSize(width: 200, height: 200), margins: .uniform(millimeters: 0),
            allowsJavaScript: false, printsBackgrounds: true, printTimeout: .seconds(15), onPrintStart: { _ in },
            onPrintFinish: {}, onClose: {})
        defer { session.requestClose() }
        try session.load(source)
        try await WebPaginator.waitUntil(timeout: .seconds(15)) { session.navigationState != .loading }
        try await MermaidScript.preventResourceLoads(in: session.webView)
        let loaded = try await session.webView.evaluateForPrinting(
            """
            const load = src => new Promise(done => {
              const image = new Image();
              image.onload = () => done(true);
              image.onerror = () => done(false);
              image.src = src;
            });
            const copy = document.images[0].cloneNode();
            document.body.append(copy);
            const copied = copy.complete ? copy.naturalWidth > 0 : await new Promise(done => {
              copy.onload = () => done(true);
              copy.onerror = () => done(false);
            });
            return [copied, await load('later.svg')];
            """, until: .now + .seconds(15))
        #expect(loaded as? [Bool] == [true, false])
    }

    @Test("フィルターの正規表現の記号は文字どおりにする")
    func escaping() {
        #expect(MermaidScript.escapedFilter("file:///a/b (1)+[x].png?q=$") == #"file:///a/b \(1\)\+\[x\]\.png\?q=\$"#)
    }
}
