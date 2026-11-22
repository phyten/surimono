import AppKit
import QuartzCore
import SurimonoCore
import Testing

@testable import Surimono

/// Measure the reading window itself: a rasterizer timer misses the SwiftUI layout and PDFView resize.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SURIMONO_BENCH_PAGES"] == "1"), .serialized)
struct PageDrawerWindowBenchmarks {
    private final class FrameClock: NSObject {
        private var previous: Double?
        var longest = 0.0
        var count = 0

        @objc func tick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            if let previous { longest = max(longest, now - previous) }
            previous = now
            count += 1
        }
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(condition())
    }

    @Test("引き出しを開く時間、復元した窓の時間、高速スクロールの最長フレームを測る", .timeLimit(.minutes(30)))
    func windows() async throws {
        try #require(NSScreen.main != nil)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let temp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let suite = TestDefaultsSuite()
        defer {
            suite.remove()
            try? FileManager.default.removeItem(at: temp)
        }
        let preferences = AppPreferences(defaults: suite.defaults)
        preferences.outlinePresentation = .drawer
        let library = UserLibrary(root: temp.appending(path: "Library"))
        let pdf = TestFixtures.textPDF((1...300).map { "Index of workshop drawings. Sheet " + String($0) })
        let urls = try (0..<20).map { index in
            let url = temp.appending(path: "plate-\(index).tiff")
            let context = try #require(
                CGContext(
                    data: nil, width: 1024, height: 768, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(red: CGFloat(index) / 20, green: 0.3, blue: 0.7, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 768))
            let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            try #require(bitmap.tiffRepresentation).write(to: url)
            return url
        }
        let booklet = root.appending(path: "Samples/booklet-demo.md")
        let deck = root.appending(path: "Snapshots/corpus/latex/083-class-beamer/main.tex")
        for (name, format, url, data) in [
            ("booklet", DocumentFormat.markdown, Optional(booklet), try Data(contentsOf: booklet)),
            ("deck", .latex, Optional(deck), try Data(contentsOf: deck)),
            ("pdf-300", .pdf, nil, pdf), ("images-20", .image, nil, Data()),
        ] {
            var first: [Double] = []
            var openByState = [false: [Double](), true: [Double]()]
            var longestFrame = 0.0
            var styleChanges: [Double] = []
            for run in 0..<20 {
                for restored in (run.isMultiple(of: 2) ? [false, true] : [true, false]) {
                    let start = CACurrentMediaTime()
                    let model = DocumentViewModel(
                        data: data, fileURL: url, format: format, preferences: preferences, library: library,
                        imageBundle: name == "images-20" ? ImageBundleModel(urls: urls) : nil)
                    var panel = DocumentSettings.ContentsPanel()
                    panel.tab = .pages
                    panel.isOpen = restored
                    model.restoreClosedDocument(DocumentSettings(contentsPanel: panel))
                    var shown: (generation: Int, time: Double)?
                    model.thumbnailDidAppear = { shown = ($0, CACurrentMediaTime()) }
                    let controller = MemoryDocumentWindowController(model: model) {}
                    let window = try #require(controller.window)
                    defer { controller.close() }
                    window.orderFront(nil)
                    try await wait { model.isUpToDate && window.isVisible }
                    window.displayIfNeeded()
                    openByState[restored, default: []].append((CACurrentMediaTime() - start) * 1000)
                    if !restored {
                        let opening = CACurrentMediaTime()
                        model.setContentsOpen(true)
                        try await wait { shown != nil }
                        first.append(((shown?.time ?? opening) - opening) * 1000)
                    }
                    if restored && run == 0 {
                        try await wait { shown != nil }
                        let clock = FrameClock()
                        let link = window.displayLink(target: clock, selector: #selector(FrameClock.tick(_:)))
                        link.add(to: .main, forMode: .common)
                        defer { link.invalidate() }
                        try await wait { clock.count >= 2 }
                        let scroll = try #require(
                            scrollViews(window.contentView).first { view in
                                view.convert(view.bounds, to: nil).midX < model.contentsWidth
                                    && view.documentView != nil
                            })
                        let distance = max(
                            0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                        for step in 0...100 {
                            let y = distance * CGFloat(step <= 50 ? step : 100 - step) / 50
                            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            try await Task.sleep(for: .milliseconds(12))
                        }
                        let atEnd = clock.count
                        try await wait { clock.count > atEnd }
                        longestFrame = clock.longest * 1000
                        link.invalidate()
                        if model.usesPrintTheme {
                            let previous = try #require(model.result?.id)
                            let theme = try #require(
                                library.themes.first { $0.id != model.themeID && model.theme($0.id) != nil })
                            let change = CACurrentMediaTime()
                            model.selectTheme(theme.id)
                            try await wait {
                                shown?.generation != previous && shown?.generation == model.result?.id
                                    && model.isUpToDate
                            }
                            styleChanges.append((CACurrentMediaTime() - change) * 1000)
                        }
                    }
                }
            }
            func p(_ values: [Double], _ fraction: Double) -> Double {
                values.sorted()[Int(ceil(Double(values.count) * fraction)) - 1]
            }
            print(
                "PAGES window \(name) first50=\(p(first, 0.5)) first95=\(p(first, 0.95)) closed50=\(p(openByState[false] ?? [], 0.5)) restored50=\(p(openByState[true] ?? [], 0.5)) longestFrame=\(longestFrame) styleMS=\(styleChanges)"
            )
        }
    }

    private func scrollViews(_ view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
}
